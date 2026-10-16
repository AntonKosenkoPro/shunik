import Testing
import Foundation
@testable import TimeOfLife

/// Track sync-exit reload (fix-track-empty-after-reinstall 3.2): Track must
/// converge on relay-pulled data without a tab switch, mirroring the
/// History/Insights `sync.status` observers. `loadIfNeeded`/`invalidate`
/// serialize concurrent reloads (tab-return vs sync-exit racing); `load()`
/// stays the unguarded worker.
@MainActor
@Suite("TrackSyncReload")
struct TrackSyncReloadTests {

    @Test("load after a seeded pull fills recents, names, and categories")
    func loadAfterSeededPullFillsTrack() async throws {
        let store = try LocalStore(url: temporaryStoreURL())
        _ = try await store.seedStarterCategoriesIfNeeded(names: String.starterCategoryNames)
        let seeded = try await store.categories()
        #expect(seeded.count == 7)
        try await store.createEntry(makeEntry(
            id: "e1", text: "Gym", categoryIDs: [seeded[0].id]
        ))
        let vm = TrackViewModel(service: TimerService(store: store), connectivity: MockConnectivity(connected: true))

        await vm.loadIfNeeded()

        #expect(vm.recents.map(\.text) == ["Gym"])
        #expect(vm.allNames.map(\.text) == ["Gym"])
        #expect(vm.categories.count == 7)
        #expect(vm.errorMessage == nil)
    }

    @Test("concurrent loadIfNeeded calls serialize")
    func concurrentLoadIfNeededSerializes() async throws {
        let store = try LocalStore(url: temporaryStoreURL())
        _ = try await store.seedStarterCategoriesIfNeeded(names: String.starterCategoryNames)
        let vm = TrackViewModel(service: TimerService(store: store), connectivity: MockConnectivity(connected: true))

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { await vm.loadIfNeeded() }
            }
            await group.waitForAll()
        }

        #expect(vm.categories.count == 7)
    }

    @Test("invalidate forces the next loadIfNeeded to reload")
    func invalidateForcesReload() async throws {
        let store = try LocalStore(url: temporaryStoreURL())
        _ = try await store.seedStarterCategoriesIfNeeded(names: String.starterCategoryNames)
        let vm = TrackViewModel(service: TimerService(store: store), connectivity: MockConnectivity(connected: true))
        await vm.loadIfNeeded()
        #expect(vm.categories.count == 7)

        vm.invalidate()
        try await store.createEntry(makeEntry(id: "e1", text: "Gym"))
        await vm.loadIfNeeded()

        #expect(vm.recents.map(\.text) == ["Gym"])
    }

    @Test("a sync-exit reload preserves the typing draft")
    func reloadPreservesTypingDraft() async throws {
        let store = try LocalStore(url: temporaryStoreURL())
        _ = try await store.seedStarterCategoriesIfNeeded(names: String.starterCategoryNames)
        let vm = TrackViewModel(service: TimerService(store: store), connectivity: MockConnectivity(connected: true))
        vm.nameDraft = "Gym"

        await vm.loadIfNeeded()

        #expect(vm.nameDraft == "Gym", "reload must not clobber typing")
        #expect(vm.state == .idle)
    }

    /// Island open-and-stop ordering (fix-terminated-stop-saved-face Spike D):
    /// the single waiter runs the exact production sequence, so a
    /// `loadIfNeeded` that early-returns mid-load fails here: its `stop()`
    /// no-ops on `.idle` and nothing is ever saved. (Asserting bare loaded
    /// state would pass either way — the original load repaints `.running`
    /// regardless.) One stopper only: production runs a single island-stop
    /// waiter, and amplifying it would let a reload revive `.running`
    /// mid-save for a flaky double entry.
    @Test("interleaved reload-stop waiter saves exactly one entry")
    func interleavedReloadStopWaiterSavesOnce() async throws {
        let store = try LocalStore(url: temporaryStoreURL())
        _ = try await store.seedStarterCategoriesIfNeeded(names: String.starterCategoryNames)
        let service = TimerService(store: store)
        try await service.startTimerDraft(text: "Gym", categoryIDs: [], startedAt: Date())
        let vm = TrackViewModel(service: service, connectivity: MockConnectivity(connected: true))

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await vm.loadIfNeeded() }
            group.addTask {
                await MainActor.run { vm.invalidate() }
                await vm.loadIfNeeded()
                await vm.stop()
            }
            await group.waitForAll()
        }

        guard case let .saved(draft, _) = vm.state else {
            Issue.record("expected .saved after interleaved reload-stop, got \(vm.state)")
            return
        }
        #expect(draft.text == "Gym")
        let entries = try await store.entries()
        #expect(entries.map(\.activityText) == ["Gym"])
    }

    /// The exact island-stop sequence (`invalidate` → `loadIfNeeded` →
    /// `stop`) saves the persisted running draft through the in-app path.
    @Test("reload-then-stop sequence saves the persisted running draft")
    func reloadThenStopSavesPersistedDraft() async throws {
        let store = try LocalStore(url: temporaryStoreURL())
        _ = try await store.seedStarterCategoriesIfNeeded(names: String.starterCategoryNames)
        let service = TimerService(store: store)
        try await service.startTimerDraft(text: "Gym", categoryIDs: [], startedAt: Date())
        let vm = TrackViewModel(service: service, connectivity: MockConnectivity(connected: true))

        vm.invalidate()
        await vm.loadIfNeeded()
        await vm.stop()

        guard case let .saved(draft, _) = vm.state else {
            Issue.record("expected .saved after reload-then-stop, got \(vm.state)")
            return
        }
        #expect(draft.text == "Gym")
        let entries = try await store.entries()
        #expect(entries.map(\.activityText) == ["Gym"])
    }

    @Test("a failed reload never blanks the last good snapshot")
    func reloadKeepsSnapshotOnFailure() async {
        // Unbound store: every read throws `notBound`.
        let vm = TrackViewModel(
            service: TimerService(store: LocalStore()),
            connectivity: MockConnectivity(connected: true)
        )
        vm.recents = [ExactName(text: "Gym", categoryIDs: [], firstCategoryID: nil)]

        await vm.load()

        #expect(vm.recents.map(\.text) == ["Gym"], "failed reload keeps the last good snapshot")
        #expect(vm.errorMessage != nil)
    }

    /// Ticking-while-idle race (device finding): a `load()` landing inside
    /// `stop()`'s save-await saw the still-persisted draft and revived
    /// `.running` over `.saving`, restarting a ticker nothing ever stopped —
    /// the digits kept climbing through `.saved` into `.ready`. The save is
    /// held open with the VM's `stopGate` so the interleave is deterministic.
    @Test("a load landing mid-save neither revives running nor leaks the ticker")
    func midSaveLoadNeitherRevivesNorLeaksTicker() async throws {
        let store = try LocalStore(url: temporaryStoreURL())
        _ = try await store.seedStarterCategoriesIfNeeded(names: String.starterCategoryNames)
        let service = TimerService(store: store)
        try await service.startTimerDraft(text: "Gym", categoryIDs: [], startedAt: Date())
        let vm = TrackViewModel(service: service, connectivity: MockConnectivity(connected: true))
        await vm.loadIfNeeded()
        #expect(vm.state.isRunning)

        let gate = Gate()
        vm.stopGate = { await gate.wait() }
        let stopTask = Task { await vm.stop() }
        guard await waitUntilSaving(vm) else {
            Issue.record("stop() never entered .saving")
            await gate.go()
            return
        }
        // Foreground/tab-return/sync-exit reload landing mid-save, while the
        // draft is still persisted.
        await vm.load()
        #expect(vm.state.isSaving, "a mid-save load must not revive .running")
        await gate.go()
        await stopTask.value

        guard case .saved = vm.state else {
            Issue.record("expected .saved after the held save, got \(vm.state)")
            return
        }
        let frozen = vm.elapsed
        // One ticker interval plus margin: a leaked ticker fires at least
        // once in any 1.2s window (period 1.0s). The sleep may overshoot past
        // the 1.6s saved window on loaded CI — then the ready branch below
        // (elapsed zeroed) is the assertion target instead.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if case .saved = vm.state {
            #expect(vm.elapsed == frozen, "elapsed must freeze after save — the ticker leaked")
        } else {
            guard case .ready = vm.state else {
                Issue.record("expected .saved or .ready after the detector sleep, got \(vm.state)")
                return
            }
            #expect(vm.elapsed == 0, "elapsed must be zeroed after the saved reset — the ticker leaked")
        }
    }

    /// Same family: `select()` never excluded `.saving`, so a recents-chip
    /// tap mid-save flipped to `.ready` and the completing `stop()` no-op'd —
    /// the run was never saved.
    @Test("a recents-chip tap mid-save is ignored and the save completes")
    func chipTapMidSaveIsIgnored() async throws {
        let store = try LocalStore(url: temporaryStoreURL())
        _ = try await store.seedStarterCategoriesIfNeeded(names: String.starterCategoryNames)
        let service = TimerService(store: store)
        try await service.startTimerDraft(text: "Gym", categoryIDs: [], startedAt: Date())
        let vm = TrackViewModel(service: service, connectivity: MockConnectivity(connected: true))
        await vm.loadIfNeeded()
        #expect(vm.state.isRunning)

        let gate = Gate()
        vm.stopGate = { await gate.wait() }
        let stopTask = Task { await vm.stop() }
        guard await waitUntilSaving(vm) else {
            Issue.record("stop() never entered .saving")
            await gate.go()
            return
        }
        vm.select(ExactName(text: "Gym", categoryIDs: [], firstCategoryID: nil))
        #expect(vm.state.isSaving, "chip tap mid-save must not flip to .ready")
        await gate.go()
        await stopTask.value

        guard case let .saved(draft, _) = vm.state else {
            Issue.record("expected .saved after the held save, got \(vm.state)")
            return
        }
        #expect(draft.text == "Gym")
        let entries = try await store.entries()
        #expect(entries.map(\.activityText) == ["Gym"])
    }

    /// Holds a `stop()` inside its save window: the test resumes it with
    /// `go()` after interleaving the racy call.
    actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { self.continuation = $0 }
        }

        func go() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// Polls for the transient `.saving` state (the save is gate-held, so
    /// this always resolves; the cap only bounds a broken-seam hang).
    private func waitUntilSaving(_ vm: TrackViewModel) async -> Bool {
        for _ in 0..<400 {
            if vm.state.isSaving { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func temporaryStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(LocalStore.databaseFileName(userID: "u1"))
    }

    private func makeEntry(
        id: String,
        text: String,
        categoryIDs: [String] = []
    ) -> TimeEntry {
        let now = Date()
        return TimeEntry(
            id: id,
            activityText: text,
            startedAt: now,
            endedAt: now.addingTimeInterval(60),
            durationSeconds: 60,
            source: "manual",
            categoryIDs: categoryIDs
        )
    }
}
