// swiftlint:disable file_length
// (hosts both the guarded reload contract and the reconcile paths;
// splitting the VM is future work, not this change.)
import Combine
import Foundation
import SwiftUI

/// View model for the Track capture screen: owns the `TrackState` machine and ticker; persistence via `TimerService`.
@MainActor
final class TrackViewModel: ObservableObject {
    /// Settable (not `private(set)`) so tests can seed exact `.ready`/`.error`
    /// states directly instead of driving them through async store paths.
    @Published var state: TrackState = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var errorMessage: String?
    /// The name-field draft (trimmed at Start; a draft, never committed).
    @Published var nameDraft = ""
    /// The 12 exact-text recents (newest first, first-category icon data).
    /// Settable for the same test-seeding reason as `state`.
    @Published var recents: [ExactName] = []
    /// Every committed exact-text name, newest first, uncapped — the source
    /// for the shared name picker (dedicated-name-picker). The chips stay
    /// capped at `recentsLimit` (`recents`); the picker
    /// suggests everything ever used.
    @Published var allNames: [ExactName] = []
    /// Recents cap (timer-capture-experience): single source of truth,
    /// consumed by `storeRecents`, the `RecentActivitiesChips` default,
    /// and the test helpers — the compiler carries the invariant, not
    /// comments. Lives on the view model (not the view) so the
    /// persistence query never resolves domain policy through UI types.
    /// `nonisolated` so the `nonisolated` slice helper can default to it.
    nonisolated static let recentsLimit = 12
    /// The id→Category map used to resolve recents chip icons (design D5).
    @Published private(set) var categories: [String: Category] = [:]

    let service: TimerService
    private let connectivity: Connectivity
    private let nowProvider: () -> Date
    private var ticker: AnyCancellable?
    private var savedResetTask: Task<Void, Never>?
    /// Serializes reloads (fix-track-empty-after-reinstall): the tab-return
    /// reload and the sync-exit reload race on every first-sync landing.
    /// `needsReload` starts true so the first appear loads; `invalidate()`
    /// marks the snapshot stale and the next `loadIfNeeded()` reloads it.
    /// A call arriving mid-load awaits `inFlightLoad` (see `loadIfNeeded`).
    private var inFlightLoad: Task<Void, Never>?
    private var needsReload = true
    /// The last applied snapshot: reloads resolving an identical snapshot
    /// publish nothing, so no-op sync cycles render literally nothing
    /// (steady-track-launch).
    private var lastSnapshot: TrackSnapshot?
    /// Whether a first snapshot has been applied (preloaded adoption or a
    /// completed load, success or failure alike). Gates the name row until
    /// the screen has something true to show.
    @Published private(set) var firstLoadSettled = false
    /// Test hook (nil in production): awaited while `.saving`, before the
    /// save — lets tests hold the save window open and interleave a `load()`
    /// or a chip tap deterministically. Debug-only so no Release caller can
    /// ever suspend a stop mid-save; never set outside tests.
#if DEBUG
    var stopGate: (@Sendable () async -> Void)?
#endif

    init(
        service: TimerService,
        connectivity: Connectivity,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.connectivity = connectivity
        self.nowProvider = now
    }

    // MARK: - Recents model

    // MARK: - Lifecycle

    /// Loads the recents and categories and restores a persisted running
    /// draft (R2: the running draft survives app crashes). Reconciles an
    /// externally stopped timer: a `.running` state with no persisted draft
    /// (stopped from the compact timer on another destination) returns to
    /// `.ready`/`.idle` instead of counting elapsed time forever. Call on
    /// appear.
    ///
    /// A failed load keeps the last good snapshot (mirror-only convergence):
    /// only the recoverable error surfaces, never blanked recents.
    ///
    /// Resolution and publication are separated (steady-track-launch): the
    /// snapshot resolves across awaits, then applies in one synchronous
    /// commit — the first paint after a load never shows a half-filled
    /// screen. An identical snapshot publishes nothing, so no-op reloads
    /// (including sync cycles that merge nothing new) render nothing.
    func load() async {
        do {
            // Seeding completes before the shell mounts (seed-before-reveal
            // in `RootView`), so this load never races it; the first-sync
            // pull still lands in the background, and the sync-exit reload
            // below converges on it. Seeding stays gate-owned — a second
            // racing call site here would only double file traffic on
            // every cold start.
            let snapshot = try await service.loadSnapshot(recentsLimit: Self.recentsLimit)
            defer { markSettled() }
            guard snapshot != lastSnapshot else { return }
            applySnapshot(snapshot)
            if case .running = state, let draft = snapshot.draft, !(draft.activityText.isEmpty) {
                // Revived runs never pass through beginRunning, so no
                // Live Activity would exist for them (cold start, upgrade
                // install, relaunch) — re-mirror here. Singleton-guarded:
                // an already-live activity is a no-op. Gated on the revived
                // `.running` state (not just the draft's presence) so a
                // load landing mid-save never re-mirrors over `.saving`.
                await service.refreshLiveActivity(
                    text: draft.activityText,
                    categoryIDs: draft.categoryIDs,
                    startedAt: draft.startedAt ?? Date()
                )
            } else if case let .running(draft, _) = state {
                await reconcileExternalStop(draft: draft)
            }
        } catch {
            markSettled()
            errorMessage = L10n.text(in: .default, code: "error.unknown")
        }
    }

    /// Adopts a gate-preloaded snapshot without re-querying
    /// (steady-track-launch): synchronous single-commit assignments
    /// identical to `load()`'s, so a shell mounted with a snapshot paints
    /// complete on its first commit. Live-Activity re-mirroring rides a
    /// Task (it never throws); reconciliation cannot trigger (a freshly
    /// constructed view model starts idle, never stale-running).
    func adopt(_ snapshot: TrackSnapshot) {
        applySnapshot(snapshot)
        markSettled()
        // Adopted snapshots are fresh by construction: the appear-time
        // `loadIfNeeded` below would only re-resolve the identical snapshot
        // (a no-op publish), so skip the queries outright.
        needsReload = false
        if let draft = snapshot.draft, !draft.activityText.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                await self.service.refreshLiveActivity(
                    text: draft.activityText,
                    categoryIDs: draft.categoryIDs,
                    startedAt: draft.startedAt ?? Date()
                )
            }
        }
    }

    /// Marks the first snapshot settled, once: repeated assignments would
    /// emit redundant `objectWillChange` signals and defeat the no-op
    /// reload suppression (steady-track-launch).
    private func markSettled() {
        if !firstLoadSettled {
            firstLoadSettled = true
        }
    }

    /// Applies a resolved snapshot in one synchronous commit: recents, names,
    /// categories, and the running state (if a draft persists) land together.
    /// A plain (draft-less) resolution never touches an in-flight typed
    /// `nameDraft` — typing is reconciled by `syncReadyFromDraft`, not here.
    private func applySnapshot(_ snapshot: TrackSnapshot) {
        recents = snapshot.recents
        allNames = snapshot.allNames
        categories = snapshot.categories
        lastSnapshot = snapshot
        if let draft = snapshot.draft, !draft.activityText.isEmpty {
            // An in-flight save owns `.saving`: reviving over it would
            // clobber the state back to `.running` and start a ticker no
            // later transition stops (ticking digits on an idle screen).
            // Lists above still apply; only the state transition is held.
            if !state.isSaving {
                let startedAt = draft.startedAt ?? Date()
                state = .running(
                    TrackState.Draft(
                        text: draft.activityText,
                        categoryIDs: draft.categoryIDs,
                        notes: draft.notes
                    ),
                    startedAt: startedAt
                )
                nameDraft = draft.activityText
                startTicker(from: startedAt)
            }
        }
    }

    /// Reloads only when the snapshot is stale or was never loaded.
    /// Re-entrancy safe: never runs two loads concurrently. A call arriving
    /// mid-load awaits the in-flight load's task value instead of returning
    /// with an unloaded snapshot — callers awaiting this expect loaded state
    /// afterwards (fix-terminated-stop-saved-face Spike D: the cold-open
    /// island-stop bump lands while the first appear load still runs; an
    /// early return lets the sequenced `stop()` no-op on `.idle` while the
    /// late load repaints Running). Awaiting `Task<Void, Never>.value` is
    /// precise (no polling), never throws, and does not inherit caller
    /// cancellation — the load-then-stop sequencing holds even if the
    /// waiter was cancelled (e.g. sign-out teardown mid cold-open load).
    func loadIfNeeded() async {
        if let inFlightLoad {
            await inFlightLoad.value
        }
        guard needsReload else { return }
        needsReload = false
        let load = Task { await self.load() }
        inFlightLoad = load
        await load.value
        // Deliberately NOT cleared: resumption order after `load.value` is
        // unspecified, and nulling here can discard a NEWER in-flight load
        // installed by another waiter's mid-load resumption (an `invalidate()`
        // landing between its claim and this resumption) — breaking the
        // single-load invariant. Awaiting a completed task's `.value`
        // returns immediately, so a stale handle is harmless and is
        // overwritten at the next claim.
    }

    /// Marks the snapshot stale so the next `loadIfNeeded` reloads it.
    /// Call on tab return, Profile exit, and sync-cycle exit.
    func invalidate() {
        needsReload = true
    }

    private func storeRecents() async throws -> [ExactName] {
        try await service.store.recents(limit: Self.recentsLimit)
            .map(ExactName.init(storeRecent:))
    }

    private func storeAllNames() async throws -> [ExactName] {
        try await service.store.allActivityNames().map(ExactName.init(storeRecent:))
    }

    /// Leaves a `.running` state whose persisted draft is gone (stopped from
    /// the compact timer): stops the elapsed ticker, re-enables the idle
    /// timer, resets elapsed to zero, and returns to `.ready` for the same
    /// text — or `.idle` when nothing was entered.
    /// `.saving`/`.error` are deliberately untouched: mid-flight own-stop
    /// states that self-resolve through their async paths.
    private func reconcileExternalStop(draft: TrackState.Draft) async {
        stopTicker()
        UIApplication.shared.isIdleTimerDisabled = false
        elapsed = 0
        // Same grammar as scheduleSavedReset: a restart must not inherit
        // the previous run's notes (e.g. mid-run notes preserved in memory
        // while the persisted draft was stopped elsewhere).
        state = draft.text.isEmpty
            ? .idle
            : .ready(TrackState.Draft(text: draft.text, categoryIDs: draft.categoryIDs))
        // The draft is gone so no run is active, but an Island may still be
        // live (terminated app missed the Darwin signal): reap — the
        // entry-recency heuristic resolves Saved-vs-silent from the saved
        // entry itself (live-activities D8).
        await service.endOrphanedActivities()
    }

    // MARK: - Capture (plain text)

    /// True when the trimmed name draft is non-empty (the Start gate).
    var canStart: Bool {
        !trimmedName.isEmpty
    }

    private var trimmedName: String {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps the committed `.ready`/`.idle` state in step with the typed
    /// name draft while not running: a trimmed non-empty name prepares it
    /// (inheriting the exact recents match's categories), clearing the field
    /// returns to idle. Any edit re-derives the draft — including edits after
    /// a chip selection, which is just a fill. Typing never starts anything
    /// and never commits a partial draft. Called by the name field's
    /// edit/commit callbacks.
    func syncReadyFromDraft() {
        guard !state.isRunning, !state.isSaving else { return }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if state != .idle {
                state = .idle
            }
            elapsed = 0
            return
        }
        let inherited = recents.first { $0.text == trimmed }?.categoryIDs ?? []
        let draft = TrackState.Draft(text: trimmed, categoryIDs: inherited)
        if state != .ready(draft) {
            state = .ready(draft)
            elapsed = 0
        }
    }

    /// Selects a recents chip: fills the exact text plus that recent's full
    /// ordered categories without starting timing and without creating
    /// anything. Ignored while saving (like `syncReadyFromDraft`): a
    /// mid-save tap must not flip to `.ready`, or the completing `stop()`
    /// no-ops and the run is never saved.
    func select(_ recent: ExactName) {
        guard !state.isRunning, !state.isSaving else { return }
        nameDraft = recent.text
        state = .ready(TrackState.Draft(text: recent.text, categoryIDs: recent.categoryIDs))
        elapsed = 0
        Haptics.selection()
    }

    /// Starts the prepared name (timer-capture-experience spec); typing or
    /// chip selection alone never starts timing. Start is gated on the
    /// trimmed text being non-empty. A committed `.ready` draft starts
    /// exactly as prepared — typing already inherited the exact-recents
    /// match (or empty) in `syncReadyFromDraft`, and chip selection filled
    /// it in `select` — so Start never re-derives categories behind the
    /// user's back. Only from `.idle` (a Start tap that raced the field's
    /// commit) is the field synced first; an invalid `.ready` draft
    /// (empty text) is left untouched and Start does nothing.
    ///
    /// Start is immediate: naming happens on the picker page (its keyboard
    /// dismisses on pop), so Start never competes with a keyboard slide.
    func start() {
        // Tap-time sync (see `syncReadyFromDraft`): a carried-over `.ready`
        // (e.g. after a stop) may hold a stale draft for the field's current
        // text. Matching text needs no sync — this preserves programmatically
        // prepared categories and the empty-text state. `.saved` is excluded:
        // the disabled Start button is the only caller and cannot fire there.
        switch state {
        case .idle:
            syncReadyFromDraft()
        case .ready(let draft) where draft.text != nameDraft:
            syncReadyFromDraft()
        default:
            break
        }
        guard case let .ready(draft) = state, canStart else { return }
        Haptics.selection()
        beginRunning(draft: draft, startedAt: Date())
    }

    private func beginRunning(draft: TrackState.Draft, startedAt: Date) {        state = .running(draft, startedAt: startedAt)
        errorMessage = nil
        startTicker(from: startedAt)
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            do {
                try await service.startTimerDraft(
                    text: draft.text,
                    categoryIDs: draft.categoryIDs,
                    notes: draft.notes,
                    startedAt: startedAt
                )
            } catch {
                // Local persistence failure: keep the timer running in memory
                // so the user can still stop and retry (recoverable error).
                errorMessage = L10n.text(in: .default, code: "error.unknown")
            }
        }
    }

    /// Toggles a category on the running draft (D4): rewrites only the
    /// running draft snapshot — never an entry, history row, or recents.
    func toggleDraftCategory(_ categoryID: String) {
        guard case let .running(draft, startedAt) = state else { return }
        var updated = draft
        if let index = updated.categoryIDs.firstIndex(of: categoryID) {
            updated.categoryIDs.remove(at: index)
        } else {
            updated.categoryIDs.append(categoryID)
        }
        state = .running(updated, startedAt: startedAt)
        Task {
            try? await service.startTimerDraft(
                text: updated.text,
                categoryIDs: updated.categoryIDs,
                notes: updated.notes,
                startedAt: startedAt
            )
        }
    }

    /// Attaches an inline-created category (inline-category-creation):
    /// merges it into the pool and, while a draft is held (running or the
    /// recoverable error state), appends its id to the draft in tap order
    /// with the draft snapshot persisted (toggle + `updateDraftNotes`
    /// parity: both rewrite whichever draft the state holds). Draft-only —
    /// never an entry, history row, or recents. Outside a held draft
    /// (unreachable through the UI: the tag row is hidden and ignores hits)
    /// it only freshens the pool.
    func attachCreatedCategory(_ category: Category) {
        categories[category.id] = category
        switch state {
        case let .running(draft, startedAt):
            attachToDraft(category.id, draft: draft, startedAt: startedAt) { .running($0, startedAt: $1) }
        case let .error(draft, startedAt):
            attachToDraft(category.id, draft: draft, startedAt: startedAt) { .error($0, startedAt: $1) }
        case .idle, .ready, .saving, .saved:
            break
        }
    }

    /// Appends an id to a held draft and persists the snapshot, rewrapped
    /// into the state it came from.
    private func attachToDraft(
        _ categoryID: String,
        draft: TrackState.Draft,
        startedAt: Date,
        rewrap: (TrackState.Draft, Date) -> TrackState
    ) {
        guard !draft.categoryIDs.contains(categoryID) else { return }
        var updated = draft
        updated.categoryIDs.append(categoryID)
        state = rewrap(updated, startedAt)
        Task {
            try? await service.startTimerDraft(
                text: updated.text,
                categoryIDs: updated.categoryIDs,
                notes: updated.notes,
                startedAt: startedAt
            )
        }
    }

    /// Saves notes on the running draft (separate-notes-editor): rewrites
    /// only the running draft notes snapshot — never an entry, history
    /// row, or recents. History learns the notes at Stop. Available in
    /// both recording states (running + error), preserving whichever holds.
    /// A persistence failure surfaces the recoverable error (the
    /// beginRunning grammar) with the in-memory notes intact — never a
    /// silent success, or a kill/compact-stop could lose the edit.
    func updateDraftNotes(_ notes: String) async {
        switch state {
        case let .running(draft, startedAt):
            var updated = draft
            updated.notes = notes
            state = .running(updated, startedAt: startedAt)
        case let .error(draft, startedAt):
            var updated = draft
            updated.notes = notes
            state = .error(updated, startedAt: startedAt)
        case .idle, .ready, .saving, .saved:
            return
        }
        do {
            try await service.updateTimerDraftNotes(notes)
        } catch {
            // Local persistence failure: keep the notes in memory so the
            // user can retry (recoverable error), like beginRunning.
            errorMessage = L10n.text(in: .default, code: "error.unknown")
        }
    }

    /// Stops the running timer and saves the completed entry locally with
    /// the final ordered categories, the final draft notes, and a single
    /// outbox row.
    func stop() async {
        guard case let .running(draft, startedAt) = state else { return }
        state = .saving(draft, startedAt: startedAt)
        stopTicker()
#if DEBUG
        if let stopGate { await stopGate() }
#endif
        do {
            try await service.stopTimerDraft(
                text: draft.text,
                categoryIDs: draft.categoryIDs,
                startedAt: startedAt,
                endedAt: Date(),
                notes: draft.notes
            )
            // A concurrent revive may have restarted the ticker mid-save
            // (pre-revive-guard histories); it owns nothing now — kill it so
            // the saved confirmation (and the ready state after it) freezes.
            stopTicker()
            let duration = max(0, Date().timeIntervalSince(startedAt))
            state = .saved(draft, duration: duration)
            elapsed = duration
            UIApplication.shared.isIdleTimerDisabled = false
            Haptics.success()
            scheduleSavedReset()
            recents = (try? await storeRecents()) ?? recents
            allNames = (try? await storeAllNames()) ?? allNames
        } catch {
            // Recoverable: preserve running state so elapsed time is not lost.
            state = .error(draft, startedAt: startedAt)
            errorMessage = L10n.text(in: .default, code: "error.unknown")
            Haptics.error()
            startTicker(from: startedAt)
        }
    }

    /// Retries Stop after a recoverable save failure.
    func retryStop() async {
        guard case let .error(draft, startedAt) = state else { return }
        state = .running(draft, startedAt: startedAt)
        await stop()
    }

    // MARK: - Ticker

    private func startTicker(from startedAt: Date) {
        ticker?.cancel()
        // Seed synchronously: the readout must be correct on the very first
        // paint — a restored minutes-old run shows its true elapsed, never
        // 00:00 until the first tick fires (steady-track-launch elapsed
        // seeding; the tick closure below only keeps it fresh).
        elapsed = max(0, Date().timeIntervalSince(startedAt))
        ticker = Ticker.everySecond { [weak self] in
            self?.elapsed = max(0, Date().timeIntervalSince(startedAt))
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    /// Returns the state to ready for the same text after the brief saved
    /// confirmation (timer-capture-experience spec). The draft notes reset
    /// to empty: each run starts noteless, and a restart must not inherit
    /// the previous run's notes.
    private func scheduleSavedReset() {
        savedResetTask?.cancel()
        savedResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            guard let self, case let .saved(draft, _) = self.state else { return }
            self.state = .ready(TrackState.Draft(text: draft.text, categoryIDs: draft.categoryIDs))
            self.elapsed = 0
        }
    }
}

#if DEBUG
extension TrackViewModel {
    static func preview(
        state: TrackState = .idle,
        recents: [ExactName] = [],
        categories: [String: Category] = [:],
        nameDraft: String = ""
    ) -> TrackViewModel {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("preview.sqlite")
        // A preview must never crash: a store failure falls back to an
        // unbound store with the failure surfaced in the error banner slot.
        let bound = try? LocalStore(url: url, userID: "preview-user")
        let vm = TrackViewModel(
            service: TimerService(store: bound ?? LocalStore()),
            connectivity: MockConnectivity(connected: true)
        )
        if bound == nil {
            vm.errorMessage = L10n.text(in: .default, code: "error.unknown")
        }
        vm.state = state
        vm.recents = recents
        vm.categories = categories
        vm.nameDraft = nameDraft
        return vm
    }
}
#endif
