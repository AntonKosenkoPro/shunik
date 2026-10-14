import Testing
import Foundation
import Combine
@testable import TimeOfLife

/// First-paint snapshot (steady-track-launch): one shared query set serves
/// the gate preload and `TrackViewModel.load()`; every resolution publishes
/// in a single commit, and identical reloads publish nothing.
@MainActor
@Suite("TrackSnapshot")
struct TrackSnapshotTests {

    // MARK: - Loader

    @Test("loadSnapshot returns recents, names, categories, and draft together")
    func loaderReturnsEverythingTogether() async throws {
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: temporaryStoreURL(), userID: "snap-u1")
        let service = TimerService(store: store)
        try await store.createCategory(Category(id: "c1", name: "Work", icon: CatalogIcon.briefcase.rawValue))
        for i in 0..<3 {
            let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 60))
            try await service.stopTimerDraft(
                text: "Entry \(i)", categoryIDs: ["c1"],
                startedAt: start, endedAt: start.addingTimeInterval(60), notes: ""
            )
        }
        try await service.startTimerDraft(text: "Running", categoryIDs: [], startedAt: Date())

        let snapshot = try await service.loadSnapshot(recentsLimit: TrackViewModel.recentsLimit)

        #expect(snapshot.recents.count == 3)
        #expect(snapshot.allNames.count == 3, "committed entry names only — the running draft is not an entry")
        #expect(snapshot.categories.count == 1)
        #expect(snapshot.draft?.activityText == "Running")
        #expect(snapshot.restoredName == "Running")
    }

    @Test("loadSnapshot on an empty store returns empties and no draft")
    func loaderEmptyStore() async throws {
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: temporaryStoreURL(), userID: "snap-u1")
        let service = TimerService(store: store)

        let snapshot = try await service.loadSnapshot(recentsLimit: TrackViewModel.recentsLimit)

        #expect(snapshot.recents.isEmpty)
        #expect(snapshot.allNames.isEmpty)
        #expect(snapshot.categories.isEmpty)
        #expect(snapshot.draft == nil)
        #expect(snapshot.restoredName == nil)
    }

    @Test("loadSnapshot throws on an unbound store")
    func loaderUnboundThrows() async {
        let service = TimerService(store: LocalStore())
        var threw = false
        do {
            _ = try await service.loadSnapshot(recentsLimit: TrackViewModel.recentsLimit)
        } catch {
            threw = true
        }
        #expect(threw, "tracker reads precede binding nowhere")
    }

    // MARK: - Adopt

    @Test("adopt paints complete without re-querying")
    func adoptPaintsComplete() async throws {
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: temporaryStoreURL(), userID: "snap-u1")
        let service = TimerService(store: store)
        try await store.createCategory(Category(id: "c1", name: "Work", icon: CatalogIcon.briefcase.rawValue))
        try await service.startTimerDraft(text: "Running", categoryIDs: ["c1"], startedAt: Date())
        let snapshot = try await service.loadSnapshot(recentsLimit: TrackViewModel.recentsLimit)
        let vm = TrackViewModel(service: service, connectivity: MockConnectivity(connected: true))

        vm.adopt(snapshot)

        #expect(vm.categories.count == 1)
        #expect(vm.state.isRunning)
        #expect(vm.nameDraft == "Running")
        #expect(vm.firstLoadSettled)
    }

    @Test("adopt seeds elapsed synchronously for a running draft")
    func adoptSeedsElapsed() async throws {
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: temporaryStoreURL(), userID: "snap-u1")
        let service = TimerService(store: store)
        try await service.startTimerDraft(
            text: "Running", categoryIDs: [],
            startedAt: Date().addingTimeInterval(-150)
        )
        let snapshot = try await service.loadSnapshot(recentsLimit: TrackViewModel.recentsLimit)
        let vm = TrackViewModel(service: service, connectivity: MockConnectivity(connected: true))

        vm.adopt(snapshot)

        #expect(vm.elapsed > 140 && vm.elapsed <= 180,
                "first paint shows the true elapsed, never 00:00-until-first-tick")
    }

    // MARK: - Single-commit and suppression

    @Test("identical reload publishes nothing")
    func identicalReloadSilent() async throws {
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: temporaryStoreURL(), userID: "snap-u1")
        let vm = TrackViewModel(
            service: TimerService(store: store),
            connectivity: MockConnectivity(connected: true)
        )
        await vm.load()
        var emissions = 0
        let cancellable = vm.objectWillChange.sink { _ in emissions += 1 }
        defer { _ = cancellable }

        await vm.load()

        #expect(emissions == 0, "a no-op reload (e.g. an empty sync exit) renders nothing")
        #expect(vm.errorMessage == nil)
    }

    @Test("failed load banners without blanking and marks settled")
    func failedLoadKeepsSnapshot() async {
        let vm = TrackViewModel(
            service: TimerService(store: LocalStore()),
            connectivity: MockConnectivity(connected: true)
        )
        vm.recents = [ExactName(text: "Kept", categoryIDs: [])]

        await vm.load()

        #expect(vm.errorMessage != nil)
        #expect(vm.recents.map(\.text) == ["Kept"])
        #expect(vm.firstLoadSettled)
    }

    // MARK: - Helpers

    private func temporaryStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(LocalStore.databaseFileName(userID: "snap-u1"))
    }
}
