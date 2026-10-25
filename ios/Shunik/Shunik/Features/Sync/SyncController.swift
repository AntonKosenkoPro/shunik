import Foundation
import Combine
import os

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

    @Published var status: SyncStatus = .inactive

    let store: LocalStore
    private let connectivity: Connectivity
    /// Reads the authenticated session's `userId` at guard time (the session
    /// itself is not retained — no cycle). Production wires `SessionStore`;
    /// tests inject a swappable closure to simulate an account swap mid-cycle.
    let sessionUserIDProvider: () -> String?
    /// The account the sync client is bound to. Recorded at `activate()` from
    /// the session that mounted the signed-in shell; every cycle start (and
    /// every cycle stage boundary) verifies the still-current session user
    /// against it, so a token swap mid-flight can never push A's outbox under
    /// B's token (sync-client same-account guard).
    var boundUserID: String?

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
    var cycleGeneration = 0

    /// Whether a cycle body is actually executing. Tail-owned: set at cycle
    /// start (by a generation-current cycle only), cleared ONLY by the
    /// finishing cycle's owning-generation tail — never by
    /// deactivate/trigger/syncNow, which only cancel/nil the single-flight
    /// handle. Published so the pre-close shutdown (`waitForCycleEnd`)
    /// observes settled state via the cycle tail instead of busy-polling:
    /// every tail transition wakes settled waiters.
    /// Guard/generation semantics are otherwise untouched: `cycleTask`
    /// remains the single-flight handle for trigger/syncNow.
    @Published var cycleRunning = false

    /// Whether a cycle body is actually executing (the tail-owned running
    /// flag, not the single-flight handle — which `deactivate()` nils while
    /// the cancelled cycle is still exiting). Test observability for the
    /// generation fix (deactivate → re-activate race) and the pre-close
    /// shutdown wait.
    var isCycleLive: Bool { cycleRunning }

    /// Accounts with an unresolved or cleaning deletion lifecycle
    /// (account-deletion spec). While fenced, triggers and manual syncs for
    /// the account are refused and in-flight cycles abort at the next stage
    /// guard — local storage must never be touched by sync while a deletion
    /// outcome is unresolved or cleanup is removing it. A timeout never
    /// lifts the fence: only a scoped verdict or explicit cancel does.
    private var deletionFencedUserIDs: Set<String> = []

    /// Fences (`true`) or releases (`false`) sync for one account. Fencing is
    /// owned by the account-deletion lifecycle: set before DELETE is sent
    /// and held through ambiguous-outcome resolution and confirmed cleanup.
    /// Releasing after an `active` verdict resumes normal sync without
    /// forking another owner.
    func setDeletionFence(userID: String, fenced: Bool) {
        if fenced {
            deletionFencedUserIDs.insert(userID)
        } else {
            deletionFencedUserIDs.remove(userID)
        }
    }

    /// Test observability for the deletion fence.
    var deletionFencedAccounts: Set<String> { deletionFencedUserIDs }

    /// Whether sync is currently fenced for this account.
    func isDeletionFenced(userID: String) -> Bool {
        deletionFencedUserIDs.contains(userID)
    }

    /// Refuses a cycle at entry while the account is deletion-fenced. Parks
    /// as `.inactive` with the same generation discipline as an aborted
    /// cycle so the release path can re-`activate` cleanly.
    func refuseWhenFenced(userID: String, generation: Int) -> Bool {
        guard isDeletionFenced(userID: userID) else { return false }
        Self.logger.error("sync cycle skipped: deletion fence")
        if cycleGeneration == generation, boundUserID == userID {
            status = .inactive
        }
        return true
    }

    /// Cycle diagnostics (Console): secret-free strings only — the same codes
    /// and messages surfaced in UI. Never tokens, bodies, or emails.
    static let logger = Logger(subsystem: "com.antonkosenko.shunik", category: "sync")

    // swiftlint:disable:next todo
    // SHUNIK-TODO: scaffold — the pet-care relay client will be wired here.
    init(
        store: LocalStore,
        connectivity: Connectivity,
        sessionUserIDProvider: @escaping () -> String? = { nil }
    ) {
        self.store = store
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

    // swiftlint:disable:next todo
    // SHUNIK-TODO: scaffold no-op success — the pet-care drain/pull will run
    // here. The guards and join-in-flight below are preserved.
    /// Manual "Sync now" from the Profile status row: joins the in-flight
    /// cycle when one runs, otherwise records a successful no-op.
    func syncNow(userID: String) async {
        guard isBound(to: userID), status != .inactive, !isDeletionFenced(userID: userID) else { return }
        if let inFlight = cycleTask {
            await inFlight.value
            return
        }
        status = .idle(Date())
    }

    /// Foreground / connectivity-restored trigger.
    func trigger(userID: String) {
        guard isBound(to: userID), status != .inactive, !isDeletionFenced(userID: userID) else { return }
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

    /// The household relay client. Nil until the gate wires the real
    /// implementation — with no relay the cycle is a successful no-op
    /// (keeps pre-sync tests and the unsigned shell working).
    var relay: (any SyncRelay)?
    // MARK: - Cycle (implementation lives in SyncController+Cycle.swift)

    func finishCycleTail(generation: Int) {
        if cycleGeneration == generation {
            cycleTask = nil
            activeCycleUserID = nil
            cycleRunning = false
        } else if cycleTask == nil {
            cycleRunning = false
        }
        resumeCycleWaiters()
    }

}
