import Foundation
import Combine
import os
// swiftlint:disable file_length

/// The session-gated background sync layer (sync-client spec): while the user
/// holds a signed-in session, drains the transactional outbox to the backend
/// relay and pulls deltas via `?modified_since=`, keeping the active account's
/// local database and the relay eventually consistent. Activated on sign-in,
/// deactivated on sign-out; a signed-out state sends no sync traffic at all.
///
/// Distinct from request-response services (`AuthService`, `TimerService`) —
/// it is a background reconciler, not a per-action call. Session-gated because
/// a valid session is mandatory for every sync operation; connectivity-gated
/// because drain should wait for `.satisfied`.
///
/// Same-account guard (account-bound-local-data): every cycle records the
/// `userId` the active per-user database file is bound to and verifies it
/// against the authenticated session's `userId` at cycle entry and between
/// cycle stages — one account's outbox is never drained or pushed under
/// another account's token, and a mid-cycle account change aborts the cycle.
///
/// Entries-only payloads (remove-activities-layer D7): entries carry
/// `activity_text`, ordered `category_ids`, and `notes`; unknown category
/// ids on merge are pruned with the remainder kept; there is no activity
/// pull/merge/remap/parent-heal and no activity tombstones. Tombstones and
/// delete-wins are scoped to entries and categories only. In-progress drafts
/// never enter the outbox, so nothing about the running timer is synced.
@MainActor
final class SyncController: ObservableObject {
    /// Sync status surfaced in Settings (sync-client spec).
    enum SyncStatus: Equatable {
        /// Not signed in — sync is off.
        case inactive
        /// A drain+pull cycle is in progress.
        case syncing
        /// The last cycle completed at `date`.
        case idle(Date)
        /// The last cycle failed with `message`; "Sync now" remains enabled.
        case error(String)
    }

    @Published private(set) var status: SyncStatus = .inactive

    private let store: LocalStore
    private let remote: CatalogSending
    private let connectivity: Connectivity
    /// Reads the authenticated session's `userId` at guard time (the session
    /// itself is not retained — no cycle). Production wires `SessionStore`;
    /// tests inject a swappable closure to simulate an account swap mid-cycle.
    private let sessionUserIDProvider: () -> String?
    /// The account the sync client is bound to. Recorded at `activate()` from
    /// the session that mounted the signed-in shell; every cycle start (and
    /// every cycle stage boundary) verifies the still-current session user
    /// against it, so a token swap mid-flight can never push A's outbox under
    /// B's token (sync-client same-account guard).
    private var boundUserID: String?

    /// The account id the in-flight cycle was started for (nil when no cycle
    /// runs). Recorded at cycle entry and cleared by the owning generation's
    /// defer; the per-row drain guard compares against the cycle's own
    /// captured `userID` (see `drainOutbox`), so this stays bookkeeping.
    private var activeCycleUserID: String?

    /// Single-flight guard: concurrent triggers (foreground + connectivity +
    /// manual) share one cycle instead of racing.
    private var cycleTask: Task<Void, Never>?

    /// Monotonic ownership token for cycles. Every cycle start stamps the
    /// current generation; `deactivate()` (and only it) invalidates by
    /// incrementing. A finishing cycle may clear `cycleTask` /
    /// `activeCycleUserID` only if its generation still owns them — a
    /// cancelled predecessor finishing after `deactivate()` →
    /// `activate(newUser)` must never wipe the NEW cycle's handle (defeats
    /// single-flight) or its same-account guard.
    private var cycleGeneration = 0

    /// Whether a cycle body is actually executing. Tail-owned: set at cycle
    /// start (by a generation-current cycle only), cleared ONLY by the
    /// finishing cycle's owning-generation tail — never by
    /// deactivate/trigger/syncNow, which only cancel/nil the single-flight
    /// handle. Published so the pre-close shutdown (`waitForCycleEnd`)
    /// observes settled state via the cycle tail instead of busy-polling:
    /// every tail transition wakes settled waiters.
    /// Guard/generation semantics are otherwise untouched: `cycleTask`
    /// remains the single-flight handle for trigger/syncNow.
    @Published private(set) var cycleRunning = false

    /// Whether a cycle body is actually executing (the tail-owned running
    /// flag, not the single-flight handle — which `deactivate()` nils while
    /// the cancelled cycle is still exiting). Test observability for the
    /// generation fix (deactivate → re-activate race) and the pre-close
    /// shutdown wait.
    var isCycleLive: Bool { cycleRunning }

    /// Cycle diagnostics (Console): secret-free strings only — the same codes
    /// and messages surfaced in UI. Never tokens, bodies, or emails.
    private static let logger = Logger(subsystem: "com.antonkosenko.timeoflifeapp", category: "sync")

    init(
        store: LocalStore,
        remote: CatalogSending,
        connectivity: Connectivity,
        sessionUserIDProvider: @escaping () -> String? = { nil }
    ) {
        self.store = store
        self.remote = remote
        self.connectivity = connectivity
        self.sessionUserIDProvider = sessionUserIDProvider
    }

    // MARK: - Lifecycle (driven by SessionStore.state)

    /// Activates sync on sign-in: records the bound account, performs a
    /// first-sync (pull-then-push) and begins responding to triggers.
    /// Called on every signed-in shell mount — a re-activation of the same
    /// account is a no-op while a cycle for it is in flight or already ran;
    /// an account change first cancels any in-flight cycle.
    func activate(userID: String) {
        if let boundUserID, boundUserID != userID {
            Self.logger.error("sync account changed; deactivating before rebind")
            deactivate()
        }
        guard status == .inactive else { return }
        boundUserID = userID
        status = .syncing
        cycleGeneration += 1
        let generation = cycleGeneration
        cycleTask = Task { [weak self] in
            await self?.runCycle(firstSync: true, generation: generation)
        }
        // Stamped synchronously with the handle: a started-but-unhopped
        // cycle must already read live (waiters poll isCycleLive).
        cycleRunning = true
    }

    /// Deactivates sync on sign-out. Local data and the outbox are preserved
    /// (local-first-store spec); the outbox accumulates until the next
    /// sign-in. Invalidates the generation so a cancelled in-flight cycle,
    /// finishing after this call, can no longer clear the new cycle's
    /// handle or guard state.
    func deactivate() {
        cycleGeneration += 1
        cycleTask?.cancel()
        cycleTask = nil
        boundUserID = nil
        status = .inactive
    }

    /// Waiters for the pre-close shutdown (`waitForCycleEnd`), keyed by
    /// registration id. MainActor-confined: only `suspendUntilCycleEnd`,
    /// `cancelCycleWaiter`, the `waitForCycleEnd` defer, and the cycle tail
    /// touch it — no lock needed, and a timed-out or cancelled waiter is
    /// removed so its continuation resumes at most once.
    private var cycleEndWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Waits until the in-flight cycle actually ends (`deactivate()` only
    /// requests cancellation) so the pre-close path never pulls the file out
    /// from under a running cycle. Publisher-style: the waiter suspends on
    /// the tail-owned `cycleRunning` state (every tail transition resumes
    /// settled waiters) with a bounded timeout — the cycle is already
    /// cancelled, so it resolves on its next suspension point. Returns
    /// immediately when no cycle is live. Cancellation (rapid re-login)
    /// unregisters the waiter instead of leaking it.
    func waitForCycleEnd(timeout: TimeInterval = 2) async {
        guard isCycleLive else { return }
        let id = UUID()
        defer { cycleEndWaiters.removeValue(forKey: id) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                // Strongify once: nested closures below must capture this
                // local (a let), never the outer weak capture itself —
                // re-capturing weak self inside onCancel is a captured-var
                // reference and fails in Swift 6 language mode.
                guard let controller = self else { return }
                await withTaskCancellationHandler {
                    await controller.suspendUntilCycleEnd(id: id)
                } onCancel: {
                    Task { [controller, id] in
                        await controller.cancelCycleWaiter(id: id)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// Suspends until the cycle tail settles (or the waiter is cancelled or
    /// the entry already settled between the `isCycleLive` check and now).
    private func suspendUntilCycleEnd(id: UUID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !isCycleLive {
                continuation.resume()
            } else {
                cycleEndWaiters[id] = continuation
            }
        }
    }

    /// Unregisters a cancelled waiter and wakes it so the cancelled task
    /// exits instead of suspending forever.
    private func cancelCycleWaiter(id: UUID) {
        if let waiter = cycleEndWaiters.removeValue(forKey: id) {
            waiter.resume()
        }
    }

    /// Wakes settled waiters. Called by every cycle tail, but resumes only
    /// when nothing is live: a stale predecessor tail landing while a
    /// successor runs must not release a waiter early.
    private func resumeCycleWaiters() {
        guard !cycleRunning else { return }
        let waiters = cycleEndWaiters
        cycleEndWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    /// Manual "Sync now" from Settings, and History pull-to-refresh
    /// (sync-client spec): runs the same drain+pull path as the automatic
    /// triggers. A call arriving while a cycle is already in flight joins it
    /// (awaits the in-flight cycle's result) instead of starting a second
    /// concurrent cycle; the fresh cycle registers itself so later callers
    /// can join it too. The boundary race (cycle ending between the check
    /// and the attach) degrades to a cheap fresh cycle — cursors just
    /// advanced, so it is a no-op round-trip.
    func syncNow(userID: String) async {
        guard isBound(to: userID), status != .inactive else { return }
        if let inFlight = cycleTask {
            await inFlight.value
            return
        }
        cycleGeneration += 1
        let generation = cycleGeneration
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.runCycle(firstSync: false, generation: generation)
        }
        cycleTask = task
        cycleRunning = true
        await task.value
    }

    /// Foreground / connectivity-restored trigger.
    func trigger(userID: String) {
        guard isBound(to: userID), status != .inactive else { return }
        guard cycleTask == nil else { return }
        cycleGeneration += 1
        let generation = cycleGeneration
        cycleTask = Task { [weak self] in
            await self?.runCycle(firstSync: false, generation: generation)
        }
        cycleRunning = true
    }

    /// The same-account guard at trigger/cycle entry: the controller must be
    /// active and still bound to the session's account. A mismatch (or an
    /// inactive controller) refuses the cycle with a secret-free log entry —
    /// the outbox is left untouched (sync-client same-account guard).
    private func isBound(to userID: String) -> Bool {
        guard status != .inactive else { return false }
        guard let boundUserID else {
            Self.logger.error("sync trigger refused: no bound account")
            return false
        }
        guard boundUserID == userID else {
            Self.logger.error("sync trigger refused: account mismatch")
            return false
        }
        return true
    }

    // MARK: - Cycle

    /// One sync cycle. First sync is pull-first (D4): the relay's ids
    /// arrive before local pushes. Tombstones apply before the drain
    /// (steady) or right after the pull (first sync): a tombstone drops
    /// stale pending create/update rows pre-drain, so a 404 is never pushed
    /// for a record the relay already deleted. Buffered (undoable) deletions
    /// push right after tombstones and before the drain (push-then-commit):
    /// the delete lands first, so the drain's stale-update drop then clears
    /// any superseded queued update for the same id without pushing.
    ///
    /// The same-account guard is re-checked between every stage: a session
    /// change mid-cycle (sign-out or account swap) aborts the in-flight
    /// cycle before any further drain or pull applies to the swapped-out
    /// account's file (sync-client same-account guard).
    private func runCycle(firstSync: Bool, generation: Int) async {
        // A task cancelled before its first hop (deactivate ran between its
        // creation and its start) never started: it must neither mark the
        // flag nor run its body against the successor's binding.
        guard cycleGeneration == generation else { return }
        cycleRunning = true
        defer { finishCycleTail(generation: generation) }
        guard let userID = boundUserID else {
            Self.logger.error("sync cycle skipped: no bound account")
            status = .inactive
            return
        }
        activeCycleUserID = userID
        guard connectivity.isConnected else {
            Self.logger.error("sync cycle skipped: offline")
            status = .error("offline")
            return
        }
        status = .syncing
        Self.logger.info("sync cycle start firstSync=\(firstSync)")
        do {
            // One-time entry-cursor re-baseline
            // (fix-sync-cursor-rebaseline): cursors recorded before
            // pagination-aware pulls hide older rows from every delta.
            // Clearing it here — after the binding, before any pull reads
            // it — makes the next pull a full paged one through the
            // idempotent merge. Exactly-once per account file; a no-op
            // afterward. A swap aborts via the same guard as every stage.
            try await guardedStage(userID: userID) {
                _ = try await self.store.rebaselineEntryCursorIfNeeded()
            }
            if firstSync {
                try await guardedStage(userID: userID) {
                    try await self.pull(modifiedSince: nil, userID: userID)
                }
            }
            try await guardedStage(userID: userID) {
                try await self.applyTombstones(userID: userID)
            }
            try await guardedStage(userID: userID) {
                try await self.pushBufferedDeletions(userID: userID)
            }
            try await guardedStage(userID: userID) {
                try await self.drainOutbox(userID: userID)
            }
            if !firstSync {
                try await guardedStage(userID: userID) {
                    try await self.pull(modifiedSince: nil, userID: userID)
                }
            }
            status = .idle(Date())
            Self.logger.info("sync cycle finished")
        } catch is CancellationError {
            finishAbortedCycle(userID: userID, generation: generation)
        } catch {
            finishFailedCycle(error, userID: userID, generation: generation)
        }
    }

    /// Tail of a finished cycle: releases the single-flight handle, the
    /// cycle guard, and the running flag. Only the still-owning generation
    /// may clear the handle/guard: a cancelled predecessor finishing after
    /// deactivate() → activate(newUser) must leave the NEW cycle's state
    /// alone. The running flag follows the same ownership, except a stale
    /// tail with no live successor handle (plain deactivate) still clears it
    /// so the shutdown wait ends promptly once the cancelled cycle exits.
    private func finishCycleTail(generation: Int) {
        if cycleGeneration == generation {
            cycleTask = nil
            activeCycleUserID = nil
            cycleRunning = false
        } else if cycleTask == nil {
            cycleRunning = false
        }
        resumeCycleWaiters()
    }

    /// Tail of a cycle aborted by the same-account guard (`.inactive`, not
    /// `.error`, so the shell's next `activate(sessionID)` rebinds — see the
    /// catch in `runCycle`). Only the still-owning generation may write the
    /// status: a cancelled predecessor finishing after deactivate() →
    /// activate(newUser) must not strand the NEW cycle's `.syncing`.
    private func finishAbortedCycle(userID: String, generation: Int) {
        Self.logger.info("sync cycle aborted: account changed mid-cycle")
        if cycleGeneration == generation, boundUserID == userID {
            status = .inactive
        }
    }

    /// Tail of a cycle that failed for a real reason. Same generation
    /// discipline, plus binding ownership: a deactivated (cancelled) cycle's
    /// late failure must stay `.inactive`, never overwrite it with `.error`
    /// (otherwise `activate` early-returns and sync strands dead until
    /// relaunch). Only the still-bound owning generation surfaces `.error`.
    private func finishFailedCycle(_ error: Error, userID: String, generation: Int) {
        Self.logger.error("sync cycle failed: \(error.localizedDescription, privacy: .public)")
        // Sync-distress breadcrumb (observability Stage 0): fixed string
        // only — error details can echo user content, so they stay out.
        SentryReporter.addSyncDistressBreadcrumb("sync cycle failed")
        if cycleGeneration == generation, boundUserID == userID {
            status = .error(error.localizedDescription)
        }
    }

    /// Per-item same-account guard for in-stage loops (pull merge,
    /// tombstones, buffered deletes): the session must still match the
    /// cycle's own captured `userID` before the next record/push is applied.
    /// A mid-stage swap costs at most the one in-flight call — the abort
    /// surfaces as `CancellationError`, so `runCycle` routes it to
    /// `finishAbortedCycle` with the same generation discipline (a stale
    /// predecessor's abort never touches the successor's state).
    private func requireSameAccount(_ userID: String) throws {
        guard sessionUserIDProvider() == userID else {
            throw CancellationError()
        }
    }

    /// Runs one cycle stage, aborting (with `CancellationError`) when the
    /// account changed mid-cycle: the still-bound id must match the session's
    /// user id, otherwise nothing further is drained or applied.
    private func guardedStage(
        userID: String,
        _ stage: () async throws -> Void
    ) async throws {
        guard sessionUserIDProvider() == userID else {
            throw CancellationError()
        }
        try await stage()
    }

    // MARK: - Pull (LWW merge, D4/D5)

    /// Pulls the relay's state and merges it locally, server-wins on
    /// `updated_at` (LWW). Follows entry pagination to exhaustion (the relay
    /// pages newest-first by `started_at`): a pull is complete only when the
    /// relay returns no `next_cursor`. Advances the per-resource cursor to the
    /// max `updated_at` over ALL pages received.
    ///
    /// Ordering: the full Category snapshot is fetched and merged FIRST so
    /// every referenced category exists locally before Entries are merged
    /// (join foreign keys stay enforced).
    private func pull(modifiedSince: Date?, userID: String) async throws {
        let categories = try await remote.fetchCategories()
        // Mid-stage swap: the fetch above ran under the old session — abort
        // before reconciling or merging any of it into the (now foreign) file.
        try requireSameAccount(userID)
        try await reconcileCategories(categories)
        for category in categories {
            try requireSameAccount(userID)
            try await applyServer(category)
        }

        let categoryCursor: Date?
        if let modifiedSince {
            categoryCursor = modifiedSince
        } else {
            categoryCursor = try await store.lastSyncedAt(resource: "category")
        }
        try requireSameAccount(userID)
        if let max = categories.map(\.updatedAt).max(), categoryCursor == nil || max > (categoryCursor ?? .distantPast) {
            try await store.setLastSyncedAt(resource: "category", date: max)
        }

        let entryCursor: Date?
        if let modifiedSince {
            entryCursor = modifiedSince
        } else {
            entryCursor = try await store.lastSyncedAt(resource: "entry")
        }
        let serverCategoriesByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        // Page loop: one relay request is never the whole history. The delta
        // filter stays fixed across pages while the page cursor resumes
        // within it. The same-account guard runs after each page fetch and
        // before merging that page, so a mid-pull swap fetches nothing
        // further and merges nothing foreign.
        var pageCursor: String?
        var seenPageCursors: Set<String> = []
        var maxUpdatedAt: Date?
        while true {
            let page = try await remote.fetchEntryPage(modifiedSince: entryCursor, cursor: pageCursor)
            try requireSameAccount(userID)
            for entry in page.entries {
                try requireSameAccount(userID)
                try await applyServer(entry, serverCategories: serverCategoriesByID)
            }
            if let receivedMax = page.entries.map(\.updatedAt).max(),
               receivedMax > (maxUpdatedAt ?? .distantPast) {
                maxUpdatedAt = receivedMax
            }
            guard let next = page.nextCursor, !next.isEmpty, !seenPageCursors.contains(next) else {
                break
            }
            seenPageCursors.insert(next)
            pageCursor = next
        }
        try requireSameAccount(userID)
        if let max = maxUpdatedAt {
            try await store.setLastSyncedAt(resource: "entry", date: max)
        }
    }

    /// Applies a server category only if `server.updated_at > local.updated_at`.
    /// Same-name/different-id rivals resolve by newer-owns-the-name
    /// (category records keep their `category_exists` remap — the only
    /// name-identity remap left).
    private func applyServer(_ category: Category) async throws {
        // Delete-wins: the user deleted this record locally (buffered undoable
        // deletion or committed outbox delete) and the relay has not converged
        // yet. Merging the server copy back would resurrect it — the queued
        // DELETE removes it from the relay on drain instead.
        if try await store.isLocallyDeleted(resource: "category", recordID: category.id) {
            Self.logger.info("sync pull skips locally deleted category \(category.id, privacy: .public)")
            return
        }
        if let local = try await store.category(id: category.id) {
            guard category.updatedAt > local.updatedAt else { return }
        }
        if let rival = try await store.category(named: category.name), rival.id != category.id {
            if category.updatedAt > rival.updatedAt {
                try await store.remapCategoryReferences(from: rival.id, to: category.id, winner: category)
            } else {
                Self.logger.info("sync pull keeps local category \(rival.id, privacy: .public); skipping server \(category.id, privacy: .public)")
            }
            return
        }
        try await store.mergeCategory(category)
    }

    /// Applies a server entry only if `server.updated_at > local.updated_at`.
    /// Relay-known-but-locally-missing category ids are adopted or remapped
    /// (see `resolveEntryCategoryIDs`) instead of stripped; snapshot-unknown
    /// ids are pruned with the remainder kept (logged, secret-free) — the
    /// merge never fails the cycle on a dangling join. When the server
    /// version is not newer but the local category set strictly supersets it
    /// via clean local rows, a healing update is enqueued instead (see
    /// `healCategoryForkIfNeeded`) and the local copy is kept.
    private func applyServer(_ entry: TimeEntry, serverCategories: [String: Category]) async throws {
        // Delete-wins (see applyServer(_:)): never resurrect a locally
        // deleted entry.
        if try await store.isLocallyDeleted(resource: "entry", recordID: entry.id) {
            Self.logger.info("sync pull skips locally deleted entry \(entry.id, privacy: .public)")
            return
        }
        if let local = try await store.entry(id: entry.id) {
            guard entry.updatedAt > local.updatedAt else {
                try await healCategoryForkIfNeeded(
                    server: entry, local: local, isTie: entry.updatedAt == local.updatedAt,
                    serverCategories: serverCategories
                )
                return
            }
        }
        var merged = entry
        merged.categoryIDs = try await resolveEntryCategoryIDs(entry, serverCategories: serverCategories)
        try await store.mergeEntry(merged)
    }

    /// Resolves an entry's category ids against the relay snapshot,
    /// order-preserved and deduped. Snapshot-unknown ids are dropped (logged);
    /// locally-present ids are kept; locally-deleted ids are dropped
    /// (delete-wins); an id missing locally but present in the snapshot is
    /// remapped to a same-name local rival when one exists (local-only
    /// rewrite — the caller merges with no outbox row, so it is never
    /// enqueued) or merged from the snapshot row otherwise. Shared by the
    /// pull merge and the conflict-adoption path so both converge identically.
    private func resolveEntryCategoryIDs(
        _ entry: TimeEntry,
        serverCategories: [String: Category]
    ) async throws -> [String] {
        var resolved: [String] = []
        for id in entry.categoryIDs {
            guard let snapshotRow = serverCategories[id] else {
                Self.logger.info("sync pull prunes unknown category \(id, privacy: .public) from entry \(entry.id, privacy: .public)")
                continue
            }
            if try await store.category(id: id) != nil {
                if !resolved.contains(id) {
                    resolved.append(id)
                }
                continue
            }
            if try await store.isLocallyDeleted(resource: "category", recordID: id) {
                Self.logger.info("sync pull skips locally deleted category \(id, privacy: .public) for entry \(entry.id, privacy: .public)")
                continue
            }
            if let rival = try await store.category(named: snapshotRow.name), rival.id != id {
                Self.logger.info("sync pull remaps category \(id, privacy: .public) to local rival \(rival.id, privacy: .public) for entry \(entry.id, privacy: .public)")
                if !resolved.contains(rival.id) {
                    resolved.append(rival.id)
                }
                continue
            }
            try await store.mergeCategory(snapshotRow)
            if !resolved.contains(id) {
                resolved.append(id)
            }
        }
        return resolved
    }

    /// Heals a silently forked category set: the server version is not newer
    /// (tie or older, so LWW keeps local) but the local category set strictly
    /// supersets the server set. Only extras backed by existing clean local
    /// rows (none pending deletion) count; when the server holds any id the
    /// local copy lacks, the sets are incomparable and healing is skipped
    /// entirely. The healed copy carries the full local set with a bumped
    /// `updatedAt` (strictly newer even under second-precision truncation, so
    /// the relay PATCH LWW guard passes) and `updateEntry` enqueues the
    /// update for the next drain. When the update loses its LWW race, there
    /// is nothing to heal. Secret-free logs only.
    ///
    /// The mirror case heals too: on a TIE the server set strictly supersets
    /// the local set. Sub-millisecond wire precision (relay stamps
    /// microseconds, the wire codec keeps milliseconds) makes a server
    /// `.385574` tie with a local `.385` forever, so a join lost by an
    /// older buggy pull would otherwise never reconverge. The server ids
    /// are adopted locally (remap-aware, no outbox row — the relay already
    /// holds this version), mirroring the rival-remap rewrite. A
    /// server-older superset is a legitimate relay prune (delete-wins on
    /// another device) and keeps local.
    private func healCategoryForkIfNeeded(
        server: TimeEntry,
        local: TimeEntry,
        isTie: Bool,
        serverCategories: [String: Category]
    ) async throws {
        let serverSet = Set(server.categoryIDs)
        let localSet = Set(local.categoryIDs)
        if isTie, localSet != serverSet, serverSet.isSuperset(of: localSet) {
            var healed = local
            healed.categoryIDs = try await resolveEntryCategoryIDs(server, serverCategories: serverCategories)
            guard healed.categoryIDs != local.categoryIDs else { return }
            try await store.mergeEntry(healed)
            Self.logger.info("sync pull heals category fork on entry \(local.id, privacy: .public)")
            return
        }
        let extras = localSet.subtracting(serverSet)
        guard !extras.isEmpty, serverSet.isSubset(of: localSet) else { return }
        var cleanExtras = false
        for id in local.categoryIDs where extras.contains(id) {
            guard try await store.category(id: id) != nil else { continue }
            if try await store.isLocallyDeleted(resource: "category", recordID: id) { continue }
            cleanExtras = true
            break
        }
        guard cleanExtras else { return }
        var healed = local
        healed.updatedAt = max(
            Date(),
            max(server.updatedAt.addingTimeInterval(1), local.updatedAt.addingTimeInterval(1))
        )
        guard try await store.updateEntry(healed) else { return }
        Self.logger.info("sync pull heals category fork on entry \(local.id, privacy: .public)")
    }

    // MARK: - Category snapshot reconciliation (category-management D6)

    /// Reconciles the authoritative full Category snapshot: LWW-merges the
    /// relay's categories, then removes clean local Categories absent from
    /// the snapshot. Categories with pending create/update outbox work are
    /// preserved (their create has not reached the relay yet). No outbox row
    /// is ever created for the removals — the relay already lacks them.
    private func reconcileCategories(_ categories: [Category]) async throws {
        let relayIDs = Set(categories.map(\.id))
        try await store.removeCategoriesAbsentFromRelay(relayIDs)
    }

    // MARK: - Deletion tombstones (cross-device-delete-propagation)

    /// Fetches and applies the relay's deletion tombstones since the
    /// `deletions` cursor, in server (oldest-first) order. Advances the
    /// cursor to the max `deleted_at` received, and keeps it unchanged when
    /// the list is empty (the no-change-keeps-cursor convention). A
    /// tombstone for an unknown id is a no-op that still advances the
    /// cursor. Only entry and category tombstones exist (activity
    /// tombstones are gone); unknown resources are ignored defensively.
    private func applyTombstones(userID: String) async throws {
        let cursor = try await store.lastSyncedAt(resource: "deletions")
        let deletions: [Deletion]
        do {
            deletions = try await remote.fetchDeletions(since: cursor)
        } catch let error as APIError where error.code == "not_found" {
            // Pre-tombstone relay (no /deletions route): skip statelessly and
            // run drain+pull anyway — a later relay upgrade just starts
            // working, and push-404 convergence below still heals per-record
            // wedges against such relays. Any other fetch error still fails
            // the cycle.
            Self.logger.info("sync tombstones unsupported by relay; skipping")
            return
        }
        let known = deletions.filter { deletion in
            guard deletion.resource == "entry" || deletion.resource == "category" else {
                Self.logger.info("sync ignores unknown tombstone resource \(deletion.resource, privacy: .public)")
                return false
            }
            return true
        }
        // Mid-stage swap: the fetch above ran under the old session — abort
        // before applying any tombstone into the (now foreign) file.
        try requireSameAccount(userID)
        for deletion in known {
            try requireSameAccount(userID)
            try await store.applyDeletionTombstone(deletion)
        }
        try requireSameAccount(userID)
        if let max = deletions.map(\.deletedAt).max() {
            try await store.setLastSyncedAt(resource: "deletions", date: max)
        }
        if !known.isEmpty {
            Self.logger.info("sync applied \(known.count) deletion tombstones")
        }
    }

    // MARK: - Outbox drain (idempotent replay, D2)

    /// Pushes buffered (undoable) deletions to the relay before the drain
    /// (push-then-commit, propagate-buffered-deletes D1/D2): one `DELETE`
    /// per snapshotted record; a buffer row is dropped only after ALL its
    /// records pushed successfully, so a partial failure keeps the whole row
    /// buffered and undoable for the next cycle — never half-committed. A
    /// 404 is success (already gone); any other error fails the cycle loudly
    /// with the row still buffered. While the loop runs, undo of buffered
    /// rows is refused (D3 guard); the flag is always cleared, even on
    /// error, so undo can never wedge shut.
    private func pushBufferedDeletions(userID: String) async throws {
        let pending = try await store.bufferedDeletions()
        guard !pending.isEmpty else { return }
        await store.setUndoPushInFlight(true)
        do {
            for bufferID in Set(pending.map(\.bufferID)) {
                // Mid-stage swap aborts before the next buffer commits: no
                // further DELETE goes out under the new session's token.
                try requireSameAccount(userID)
                for deletion in pending where deletion.bufferID == bufferID {
                    // Per-item abort: a swap during the previous push costs at
                    // most that one in-flight DELETE.
                    try requireSameAccount(userID)
                    do {
                        switch deletion.resource {
                        case "entry":
                            try await remote.deleteEntry(id: deletion.recordID)
                        case "category":
                            try await remote.deleteCategory(id: deletion.recordID)
                        default:
                            Self.logger.error("sync ignores unknown buffered resource \(deletion.resource, privacy: .public)")
                            throw SyncError.unknownOutboxOp(deletion.resource, "delete")
                        }
                    } catch let error as APIError where error.code == "not_found" {
                        // Already gone on the relay — converged, nothing to do.
                        Self.logger.info("sync buffered delete 404-as-success \(deletion.resource, privacy: .public) \(deletion.recordID, privacy: .public)")
                    }
                }
                // Abort before committing the buffer row: a swap during the
                // pushes leaves the row buffered for the owning account.
                try requireSameAccount(userID)
                try await store.undoBufferRemove(id: bufferID)
            }
            Self.logger.info("sync pushed \(pending.count) buffered deletions")
        } catch {
            await store.setUndoPushInFlight(false)
            throw error
        }
        await store.setUndoPushInFlight(false)
    }

    /// Drains the outbox in dependency order, one HTTP request per row.
    /// `category` rows push before `entry` rows (`POST /entries` rejects
    /// unknown `category_ids` with 422, so referenced categories must exist
    /// on the relay first); insertion order (`created_at, rowid`) is preserved
    /// within each resource. POST is idempotent on `id` and PATCH carries `updated_at`
    /// (LWW), so a replay after a crash or relapse produces the same result
    /// as the first attempt.
    ///
    /// The per-row guard compares the session against the CYCLE's own
    /// captured `userID`, not the shared `activeCycleUserID`: a cancelled
    /// predecessor finishing after deactivate() → activate(newUser) reads
    /// the successor's guard value, and comparing against it could let a
    /// row drain under the NEW account's session.
    private func drainOutbox(userID: String) async throws {
        let rows = try await store.outboxRows()
        // One relay category snapshot per drain, fetched lazily: only when
        // the drain actually holds an entry create/update row.
        var relayCategoryIDs: Set<String>?
        for queuedRow in Self.orderedForDrain(rows) {
            // Same-account guard per row: a session swap mid-drain stops the
            // remaining pushes (sync-client same-account guard). Compared
            // against this cycle's own captured user id — see the doc above.
            guard sessionUserIDProvider() == userID else {
                throw CancellationError()
            }
            // Conflict recovery can remove or rewrite a later row while this
            // drain is still iterating the initial snapshot. Always push the
            // current persisted payload rather than a stale in-memory copy.
            guard var row = try await store.outboxRow(id: queuedRow.id) else {
                continue
            }
            // Stale updates for locally-missing records (updates superseded
            // by a queued delete) can never succeed: drop without pushing
            // instead of discovering it via a doomed 404.
            if row.op == "update", try await isLocallyMissing(row) {
                Self.logger.info("sync drain drops stale update for missing \(row.resource, privacy: .public) \(row.recordID, privacy: .public)")
                try await store.removeOutboxRow(id: row.id)
                continue
            }
            if row.resource == "entry" && (row.op == "create" || row.op == "update") {
                if relayCategoryIDs == nil {
                    let snapshot = try await remote.fetchCategories()
                    relayCategoryIDs = Set(snapshot.map(\.id))
                }
                var knownIDs = relayCategoryIDs ?? []
                row = try await ensureEntryCategories(for: row, knownIDs: &knownIDs)
                relayCategoryIDs = knownIDs
            }
            do {
                try await push(row)
                try await store.removeOutboxRow(id: row.id)
            } catch let error as APIError {
                if try await resolvePushError(row, error: error) {
                    continue
                }
                throw error
            } catch is CancellationError {
                throw CancellationError()
            }
        }
    }

    /// Dependency order for the drain snapshot: `category` rows before
    /// `entry` rows, insertion order (`created_at, rowid` from `outboxRows`)
    /// within each resource. The snapshot index is the tiebreak — never the
    /// random outbox id — so same-tick rows drain deterministically.
    private static func orderedForDrain(_ rows: [OutboxRow]) -> [OutboxRow] {
        rows.enumerated().sorted { lhs, rhs in
            let leftRank = drainRank(lhs.element.resource)
            let rightRank = drainRank(rhs.element.resource)
            if leftRank != rightRank { return leftRank < rightRank }
            if lhs.element.createdAt != rhs.element.createdAt {
                return lhs.element.createdAt < rhs.element.createdAt
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Resolves one failed push. Returns true when the row is resolved and
    /// the drain may continue; false rethrows the original error loudly.
    private func resolvePushError(_ row: OutboxRow, error: APIError) async throws -> Bool {
        switch error.code {
        case "conflict", "category_exists", "duplicate_import":
            try await resolveConflict(row, code: error.code ?? "", details: error.details)
            return true
        case "not_found":
            // 404 on DELETE → treat as success (already gone). A push
            // for a tombstone-less relay-missing record resurrects
            // from local data and retries once (see
            // resurrectAndRetry) instead of wedging the cycle on a
            // doomed retry; anything else still throws.
            if row.op == "delete" {
                try await store.removeOutboxRow(id: row.id)
                return true
            }
            return try await resurrectAndRetry(row)
        case "validation_error":
            // 422 unknown `category_ids` on entry create/update →
            // prune to the relay-known remainder and retry once (see
            // healUnknownCategoryIDs). Anything else still throws.
            guard error.details["category_ids"] != nil else { return false }
            return try await healUnknownCategoryIDs(row)
        default:
            return false
        }
    }

    /// Drain ordering rank: categories push before entries so `POST /entries`
    /// never references a category the relay has not seen yet. Unknown
    /// resources drain last so the push path still rejects them loudly.
    private static func drainRank(_ resource: String) -> Int {
        switch resource {
        case "category":
            return 0
        case "entry":
            return 1
        default:
            return 2
        }
    }

    /// Ensures every category id referenced by an entry create/update exists
    /// on the relay before the entry push, so the push carries the full set
    /// (no 422, no prune, no local loss). Ids missing from the per-drain
    /// cached relay snapshot but present locally and not pending deletion are
    /// created on the relay first (idempotent; a `category_exists` 409 remaps
    /// local references to the winning id and the entry push re-reads its
    /// payload). Dangling ids (no local row) and delete-wins ids are left
    /// for the last-resort prune-and-retry heal. Any other creation error
    /// throws, aborting the cycle with the row still queued — nothing is ever
    /// silently pruned here. Returns the row to push (possibly re-read after
    /// a remap rewrote its payload).
    private func ensureEntryCategories(for row: OutboxRow, knownIDs: inout Set<String>) async throws -> OutboxRow {
        var currentRow = row
        // At most two passes: the initial scan plus one re-check after a
        // remap (the entry then carries the winner id).
        for _ in 0..<2 {
            let entry = try decodePayload(currentRow, as: TimeEntry.self)
            var didRemap = false
            for id in entry.categoryIDs where !knownIDs.contains(id) {
                guard let local = try await store.category(id: id) else { continue }
                if try await store.isLocallyDeleted(resource: "category", recordID: id) { continue }
                do {
                    try await remote.createCategory(local)
                    knownIDs.insert(id)
                } catch let error as APIError where error.code == "category_exists" {
                    guard let winningID = error.details["id"] else { throw error }
                    try await remapCategoryReferences(from: id, to: winningID)
                    knownIDs.insert(winningID)
                    if let fresh = try await store.outboxRow(id: row.id) {
                        currentRow = fresh
                    }
                    didRemap = true
                    break
                }
            }
            if !didRemap { break }
        }
        return currentRow
    }

    /// Recovers an entry create/update rejected with 422 `category_ids`:
    /// fetches the relay categories, drops unknown ids from the queued
    /// payload keeping the remainder (secret-free log), rewrites the outbox
    /// payload, retries the push exactly once, and clears the row on success.
    /// Returns whether the row was resolved (anything else rethrows loudly).
    /// The following pull converges the local copy via LWW (the pruned server
    /// version is newer), so local joins are left untouched here.
    private func healUnknownCategoryIDs(_ row: OutboxRow) async throws -> Bool {
        guard row.resource == "entry", row.op == "create" || row.op == "update" else {
            return false
        }
        guard let current = try await store.outboxRow(id: row.id) else {
            return true
        }
        let entry: TimeEntry
        do {
            entry = try decodePayload(current, as: TimeEntry.self)
        } catch {
            return false
        }
        guard !entry.categoryIDs.isEmpty else { return false }
        let snapshot = try await remote.fetchCategories()
        let knownIDs = Set(snapshot.map(\.id))
        let prunedIDs = entry.categoryIDs.filter { knownIDs.contains($0) }
        guard prunedIDs.count != entry.categoryIDs.count else {
            return false
        }
        var pruned = entry
        pruned.categoryIDs = prunedIDs
        for id in entry.categoryIDs where !knownIDs.contains(id) {
            Self.logger.info("sync drain prunes unknown category \(id, privacy: .public) from entry \(entry.id, privacy: .public)")
        }
        try await store.rewriteOutboxPayload(resource: row.resource, recordID: row.recordID, payload: pruned)
        if row.op == "create" {
            try await remote.createEntry(pruned)
        } else {
            try await remote.updateEntry(pruned)
        }
        try await store.removeOutboxRow(id: row.id)
        return true
    }

    /// Pushes one outbox row to the relay.
    private func push(_ row: OutboxRow) async throws {
        switch (row.resource, row.op) {
        case ("category", "create"):
            let category = try decodePayload(row, as: Category.self)
            try await remote.createCategory(category)
        case ("category", "update"):
            let category = try decodePayload(row, as: Category.self)
            try await remote.updateCategory(category)
        case ("category", "delete"):
            try await remote.deleteCategory(id: row.recordID)
        case ("entry", "create"):
            let entry = try decodePayload(row, as: TimeEntry.self)
            try await remote.createEntry(entry)
        case ("entry", "update"):
            let entry = try decodePayload(row, as: TimeEntry.self)
            try await remote.updateEntry(entry)
        case ("entry", "delete"):
            try await remote.deleteEntry(id: row.recordID)
        default:
            throw SyncError.unknownOutboxOp(row.resource, row.op)
        }
    }

    /// Whether an update row references a record with no local row: an
    /// update superseded by a queued delete. Unknown resources return false
    /// so the push path still rejects them loudly.
    private func isLocallyMissing(_ row: OutboxRow) async throws -> Bool {
        switch row.resource {
        case "category":
            return try await store.category(id: row.recordID) == nil
        case "entry":
            return try await store.entry(id: row.recordID) == nil
        default:
            return false
        }
    }

    /// Resurrects a push for a record the relay lacks with no tombstone on
    /// file (pre-deployment ghost, wipe/restore, or a seconds-wide
    /// delete-vs-push race) and retries exactly once. Tombstoned records
    /// never reach here (tombstones-first drops their rows pre-drain), so a
    /// 404 here always meets the fuller local record — resurrecting heals
    /// relay and device together, while deleting would silently discard user
    /// data (and strand future sessions against the surviving ghost).
    /// Returns whether the row was resolved (anything else rethrows the
    /// original error loudly — nothing is ever silently dropped).
    ///
    /// - entry/category update + `not_found`: re-post the full local row as
    ///   a create (idempotent; queued updates PATCH normally afterward).
    /// - entry/category create + 404: impossible per routes: returns false.
    private func resurrectAndRetry(_ row: OutboxRow) async throws -> Bool {
        switch (row.resource, row.op) {
        case ("entry", "update"), ("category", "update"):
            return try await repushRecordAsCreate(row)
        default:
            return false
        }
    }

    /// Re-posts a full local entry/category row as a create (idempotent;
    /// queued updates PATCH normally afterward). A 409 reuses the existing
    /// conflict resolver; a locally-missing row just clears its rows.
    private func repushRecordAsCreate(_ row: OutboxRow) async throws -> Bool {
        switch row.resource {
        case "entry":
            guard let entry = try await store.entry(id: row.recordID) else {
                try await store.removeOutboxRow(resource: row.resource, recordID: row.recordID)
                return true
            }
            do {
                try await remote.createEntry(entry)
            } catch let error as APIError {
                guard error.code == "duplicate_import" else { return false }
                try await resolveConflict(row, code: "duplicate_import", details: error.details)
            }
        case "category":
            guard let category = try await store.category(id: row.recordID) else {
                try await store.removeOutboxRow(resource: row.resource, recordID: row.recordID)
                return true
            }
            do {
                try await remote.createCategory(category)
            } catch let error as APIError {
                guard error.code == "category_exists" else { return false }
                try await resolveConflict(row, code: "category_exists", details: error.details)
            }
        default:
            return false
        }
        try await store.removeOutboxRow(id: row.id)
        return true
    }

    /// Resolves a push conflict per the sync-client spec:
    /// - 409 `conflict` → adopt the server's version (keep-latest) + clear the row.
    /// - 409 `category_exists` → remap local entry joins to the winning id
    ///   + clear the row.
    /// - 409 `duplicate_import` → the relay already has the record; clear the row.
    private func resolveConflict(_ row: OutboxRow, code: String, details: [String: String]) async throws {
        switch code {
        case "conflict":
            try await adoptServerVersion(row)
        case "category_exists":
            if let winningID = details["id"] {
                try await remapCategoryReferences(from: row.recordID, to: winningID)
            }
        case "duplicate_import":
            break // relay already has the record; nothing to do
        default:
            break
        }
        try await store.removeOutboxRow(id: row.id)
    }

    /// Adopts the server's current version of a record (keep-latest). Uses
    /// the no-outbox merge path — the relay already holds this version.
    /// Skipped when the record was deleted locally after the conflicting row
    /// was queued: adopting would resurrect it, and the queued DELETE row
    /// converges the relay on its own.
    private func adoptServerVersion(_ row: OutboxRow) async throws {
        let deleted = try await store.isLocallyDeleted(resource: row.resource, recordID: row.recordID)
        if deleted {
            Self.logger.info("sync conflict keeps local deletion of \(row.resource, privacy: .public) \(row.recordID, privacy: .public)")
            return
        }
        switch row.resource {
        case "category":
            let server = try await remote.fetchCategory(id: row.recordID)
            try await store.mergeCategory(server)
        case "entry":
            let server = try await remote.fetchEntry(id: row.recordID)
            try await store.mergeEntry(await prunedEntry(server))
        default:
            break
        }
    }

    /// Re-maps local entry joins from a losing category id to the winning id
    /// after a `category_exists` 409 (category-management D6). The winning
    /// record is fetched and merged first (the relay is authoritative; the
    /// FK on joins requires it to exist). Never synthesizes record content:
    /// a winner-fetch failure rethrows, so the outbox row stays queued and
    /// the next cycle retries with local names intact.
    private func remapCategoryReferences(from oldID: String, to newID: String) async throws {
        let winner = try await remote.fetchCategory(id: newID)
        try await store.remapCategoryReferences(from: oldID, to: newID, winner: winner)
    }

    /// Resolves a server entry's category ids before a conflict-adoption
    /// merge, identically to the pull path (see `resolveEntryCategoryIDs`):
    /// relay-known-but-locally-missing ids are adopted or remapped to a
    /// same-name local rival, snapshot-unknown ids are dropped with the
    /// remainder kept (secret-free log), and the merge never fails the cycle.
    private func prunedEntry(_ entry: TimeEntry) async throws -> TimeEntry {
        guard !entry.categoryIDs.isEmpty else { return entry }
        let snapshot = try await remote.fetchCategories()
        let serverCategories = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        var resolved = entry
        resolved.categoryIDs = try await resolveEntryCategoryIDs(entry, serverCategories: serverCategories)
        return resolved
    }

    /// Decodes an outbox row's payload into a model.
    private func decodePayload<T: Decodable>(_ row: OutboxRow, as type: T.Type) throws -> T {
        guard let payload = row.payload, let data = payload.data(using: .utf8) else {
            throw SyncError.missingPayload(row.resource, row.op)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Errors surfaced by the sync layer.
enum SyncError: Error, Equatable, Sendable {
    case unknownOutboxOp(String, String)
    case missingPayload(String, String)
}
