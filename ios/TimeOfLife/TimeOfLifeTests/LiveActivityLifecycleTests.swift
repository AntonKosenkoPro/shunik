import Testing
import Foundation
@testable import TimeOfLife

import LifioLiveActivityCore

/// TimerService ↔ Live Activity wiring (live-activities spec: "Live
/// Activity follows the running timer"). The fake stands in for
/// ActivityKit; the real service's singleton guard (same-text reuse) is
/// not unit-testable and is covered by the device smoke in task 4.3.
@MainActor
@Suite("LiveActivityLifecycle")
struct LiveActivityLifecycleTests {

    @Test("start mirrors the run with exact text and first icon")
    func startMirrorsRun() async throws {
        let fake = FakeLiveActivities()
        let service = makeService(liveActivities: fake)
        try await service.store.createCategory(Category(id: "c1", name: "Work", icon: CatalogIcon.briefcase.rawValue))
        let startedAt = Date(timeIntervalSince1970: 1_600_000_000)

        try await service.startTimerDraft(text: "Gym", categoryIDs: ["c1"], startedAt: startedAt)

        #expect(fake.started.count == 1)
        #expect(fake.started.first?.text == "Gym")
        #expect(fake.started.first?.iconSymbol == CatalogIcon.briefcase.rawValue)
        #expect(fake.started.first?.startedAt == startedAt)
        #expect(fake.started.first?.categoryChips == [
            LiveCategoryChip(name: "Work", iconSymbol: CatalogIcon.briefcase.rawValue)
        ])
        #expect(fake.ended.isEmpty)
    }

    @Test("start without known categories falls back to the timer icon")
    func startFallsBackToTimerIcon() async throws {
        let fake = FakeLiveActivities()
        let service = makeService(liveActivities: fake)
        let startedAt = Date(timeIntervalSince1970: 1_600_000_000)

        try await service.startTimerDraft(text: "Walk", categoryIDs: [], startedAt: startedAt)
        try await service.startTimerDraft(text: "Run", categoryIDs: ["gone"], startedAt: startedAt)

        #expect(fake.started.map(\.iconSymbol) == ["timer", "timer"])
    }

    @Test("mid-run retag re-mirrors with refreshed category chips")
    func retagRefreshesCategoryNames() async throws {
        let fake = FakeLiveActivities()
        let service = makeService(liveActivities: fake)
        try await service.store.createCategory(Category(id: "c1", name: "Work", icon: CatalogIcon.briefcase.rawValue))
        try await service.store.createCategory(Category(id: "c2", name: "Health", icon: CatalogIcon.heart.rawValue))
        let startedAt = Date(timeIntervalSince1970: 1_600_000_000)

        try await service.startTimerDraft(text: "Gym", categoryIDs: ["c1"], startedAt: startedAt)
        try await service.startTimerDraft(text: "Gym", categoryIDs: ["c1", "c2"], startedAt: startedAt)

        #expect(fake.started.count == 2)
        #expect(fake.started.map(\.categoryChips) == [
            [LiveCategoryChip(name: "Work", iconSymbol: CatalogIcon.briefcase.rawValue)],
            [
                LiveCategoryChip(name: "Work", iconSymbol: CatalogIcon.briefcase.rawValue),
                LiveCategoryChip(name: "Health", iconSymbol: CatalogIcon.heart.rawValue),
            ],
        ])
    }

    @Test("unknown category ids drop from the mirrored names")
    func unknownCategoryIDsDropFromNames() async throws {
        let fake = FakeLiveActivities()
        let service = makeService(liveActivities: fake)
        try await service.store.createCategory(Category(id: "c1", name: "Work", icon: CatalogIcon.briefcase.rawValue))
        let startedAt = Date(timeIntervalSince1970: 1_600_000_000)

        try await service.startTimerDraft(text: "Gym", categoryIDs: ["c1", "gone"], startedAt: startedAt)

        #expect(fake.started.first?.categoryChips == [
            LiveCategoryChip(name: "Work", iconSymbol: CatalogIcon.briefcase.rawValue)
        ])
    }

    @Test("stop ends the activity with the saved duration")
    func stopEndsActivity() async throws {
        let fake = FakeLiveActivities()
        let service = makeService(liveActivities: fake)
        let startedAt = Date(timeIntervalSince1970: 1_600_000_000)
        try await service.startTimerDraft(text: "Gym", categoryIDs: [], startedAt: startedAt)

        try await service.stopTimerDraft(
            text: "Gym",
            categoryIDs: [],
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(600)
        )

        #expect(fake.ended.count == 1)
        #expect(fake.ended.first?.startedAt == startedAt)
        #expect(fake.ended.first?.durationSeconds == 600)
    }

    @Test("stop without a start still fires end once (idempotent)")
    func stopWithoutStartEndsOnce() async throws {
        let fake = FakeLiveActivities()
        let service = makeService(liveActivities: fake)
        let startedAt = Date(timeIntervalSince1970: 1_600_000_000)

        try await service.stopTimerDraft(
            text: "Gym",
            categoryIDs: [],
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60)
        )

        #expect(fake.ended.count == 1)
    }

    @Test("load with a persisted draft re-mirrors the run (restore path)")
    func loadRestoresActivity() async throws {
        let fake = FakeLiveActivities()
        let store = try LocalStore(url: temporaryStoreURL())
        try await store.createCategory(Category(id: "c1", name: "Work", icon: CatalogIcon.briefcase.rawValue))
        let startedAt = Date(timeIntervalSince1970: 1_600_000_000)
        try await store.saveTimerDraft(activityText: "Gym", categoryIDs: ["c1"], startedAt: startedAt)
        let vm = TrackViewModel(
            service: TimerService(store: store, liveActivities: fake),
            connectivity: MockConnectivity(connected: true)
        )

        await vm.load()

        #expect(fake.started.count == 1)
        #expect(fake.started.first?.text == "Gym")
        #expect(fake.started.first?.iconSymbol == CatalogIcon.briefcase.rawValue)
        #expect(fake.started.first?.startedAt == startedAt)
    }

    @Test("orphan reaping skips when a draft is present (run genuinely active)")
    func orphanReapSkipsActiveDraft() async throws {
        let fake = FakeLiveActivities()
        let service = makeService(liveActivities: fake)
        try await service.startTimerDraft(text: "Gym", categoryIDs: [], startedAt: Date())

        await service.endOrphanedActivities(knownDurationSeconds: 60)

        #expect(fake.orphanEnds.isEmpty)
        #expect(try await service.runningTimerDraft() != nil)
    }

    @Test("orphan reaping delegates with the signaled duration when no draft exists")
    func orphanReapDelegatesWithoutDraft() async throws {
        let fake = FakeLiveActivities()
        let service = makeService(liveActivities: fake)

        await service.endOrphanedActivities(knownDurationSeconds: 60)
        await service.endOrphanedActivities()

        #expect(fake.orphanEnds == [60, nil])
    }

    @Test("orphan reaping fails closed when the draft read throws")
    func orphanReapFailsClosedOnReadError() async {
        let fake = FakeLiveActivities()
        // Unbound store: every operation throws — must end nothing.
        let service = TimerService(store: LocalStore(), liveActivities: fake)

        await service.endOrphanedActivities(knownDurationSeconds: 60)

        #expect(fake.orphanEnds.isEmpty)
    }

    @Test("nil-duration reap resolves a recent entry's duration (widget stop)")
    func orphanReapResolvesRecentEntryDuration() async throws {
        let fake = FakeLiveActivities()
        let service = makeService(liveActivities: fake)
        let now = Date()
        _ = try await service.store.createEntry(TimeEntry(
            id: UUID().uuidString,
            activityText: "Gym",
            startedAt: now.addingTimeInterval(-300),
            endedAt: now.addingTimeInterval(-60),
            durationSeconds: 240
        ))

        await service.endOrphanedActivities()

        #expect(fake.orphanEnds == [240])
    }

    @Test("nil-duration reap stays silent for an old entry (>10min)")
    func orphanReapIgnoresOldEntry() async throws {
        let fake = FakeLiveActivities()
        let service = makeService(liveActivities: fake)
        let now = Date()
        _ = try await service.store.createEntry(TimeEntry(
            id: UUID().uuidString,
            activityText: "Gym",
            startedAt: now.addingTimeInterval(-7_200),
            endedAt: now.addingTimeInterval(-3_600),
            durationSeconds: 3_600
        ))

        await service.endOrphanedActivities()

        #expect(fake.orphanEnds == [nil])
    }

    @Test("nil-duration reap stays silent with no entries")
    func orphanReapSilentWithNoEntries() async throws {
        let fake = FakeLiveActivities()
        let service = makeService(liveActivities: fake)

        await service.endOrphanedActivities()

        #expect(fake.orphanEnds == [nil])
    }

    @Test("nil-duration reap skips when a draft is present (run genuinely active)")
    func orphanReapSkipsActiveDraftNilDuration() async throws {
        let fake = FakeLiveActivities()
        let service = makeService(liveActivities: fake)
        try await service.startTimerDraft(text: "Gym", categoryIDs: [], startedAt: Date())

        await service.endOrphanedActivities()

        #expect(fake.orphanEnds.isEmpty)
    }

    // MARK: - Helpers

    private func makeService(liveActivities: LiveActivityControlling) -> TimerService {
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: temporaryStoreURL())
        return TimerService(store: store, liveActivities: liveActivities)
    }

    private func temporaryStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("liveactivity.sqlite")
    }
}

/// Capturing fake for `LiveActivityControlling`.
@MainActor
final class FakeLiveActivities: LiveActivityControlling {
    struct Started: Equatable {
        var text: String
        var iconSymbol: String
        var startedAt: Date
        var categoryChips: [LiveCategoryChip]
    }

    struct Ended: Equatable {
        var startedAt: Date
        var durationSeconds: Int
    }

    var started: [Started] = []
    var ended: [Ended] = []
    var orphanEnds: [Int?] = []

    func runStarted(text: String, iconSymbol: String, startedAt: Date, categoryChips: [LiveCategoryChip] = []) async {
        started.append(Started(text: text, iconSymbol: iconSymbol, startedAt: startedAt, categoryChips: categoryChips))
    }

    func runEnded(startedAt: Date, durationSeconds: Int) async {
        ended.append(Ended(startedAt: startedAt, durationSeconds: durationSeconds))
    }

    func endOrphanedActivities(knownDurationSeconds: Int?) async {
        orphanEnds.append(knownDurationSeconds)
    }
}
