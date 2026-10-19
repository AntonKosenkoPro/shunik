// swiftlint:disable file_length
import Testing
import Foundation
@testable import TimeOfLife

@MainActor
@Suite("HistoryViewModel")
struct HistoryViewModelTests {

    private func makeStore() throws -> LocalStore {
        try LocalStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(LocalStore.databaseFileName(userID: "u1")))
    }

    private func entry(
        id: String,
        startedAt: Date,
        text: String? = nil,
        categoryIDs: [String] = [],
        durationSeconds: Int? = nil,
        endedAt: Date? = nil
    ) -> TimeEntry {
        TimeEntry(
            id: id,
            activityText: text ?? "Entry \(id)",
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: durationSeconds,
            categoryIDs: categoryIDs
        )
    }

    // MARK: - Day grouping (D2)

    @Test("groups entries by calendar day, newest day first, newest entry first")
    func groupsByDay() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Self.date("2026-09-03 15:00", calendar: calendar)
        let groups = HistoryViewModel.makeDayGroups(
            entries: [
                entry(id: "old-day-b", startedAt: Self.date("2026-08-31 10:00", calendar: calendar)),
                entry(id: "today-a", startedAt: Self.date("2026-09-03 08:00", calendar: calendar)),
                entry(id: "old-day-a", startedAt: Self.date("2026-08-31 18:00", calendar: calendar)),
                entry(id: "today-b", startedAt: Self.date("2026-09-03 12:00", calendar: calendar))
            ],
            now: now,
            calendar: calendar
        )

        #expect(groups.count == 2)
        #expect(groups[0].id == "2026-09-03")
        #expect(groups[0].entries.map(\.id) == ["today-b", "today-a"])
        #expect(groups[1].id == "2026-08-31")
        #expect(groups[1].entries.map(\.id) == ["old-day-a", "old-day-b"])
    }

    @Test("empty entries produce no groups")
    func emptyEntries() {
        let groups = HistoryViewModel.makeDayGroups(entries: [], now: Date())
        #expect(groups.isEmpty)
    }

    @Test("entries on the same day across midnight boundaries group by startedAt day")
    func midnightBoundary() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Self.date("2026-09-03 12:00", calendar: calendar)
        let groups = HistoryViewModel.makeDayGroups(
            entries: [
                entry(id: "late", startedAt: Self.date("2026-09-02 23:30", calendar: calendar)),
                entry(id: "early", startedAt: Self.date("2026-09-03 00:10", calendar: calendar))
            ],
            now: now,
            calendar: calendar
        )
        #expect(groups.count == 2)
        #expect(groups[0].id == "2026-09-03")
        #expect(groups[1].id == "2026-09-02")
    }

    // MARK: - Day labels (D3)

    @Test("today and yesterday use relative labels")
    func relativeLabels() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Self.date("2026-09-03 15:00", calendar: calendar)
        #expect(HistoryViewModel.dayLabel(
            for: Self.date("2026-09-03 00:00", calendar: calendar),
            now: now,
            calendar: calendar
        ) == L10n.historyDayToday.text)
        #expect(HistoryViewModel.dayLabel(
            for: Self.date("2026-09-02 23:59", calendar: calendar),
            now: now,
            calendar: calendar
        ) == L10n.historyDayYesterday.text)
    }

    @Test("older days use the regional absolute date")
    func absoluteLabels() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Self.date("2026-09-03 15:00", calendar: calendar)
        let label = HistoryViewModel.dayLabel(
            for: Self.date("2026-08-31 10:00", calendar: calendar),
            now: now,
            calendar: calendar
        )
        #expect(label != L10n.historyDayToday.text)
        #expect(label != L10n.historyDayYesterday.text)
        #expect(!label.isEmpty)
    }

    // MARK: - Day totals (D8)

    @Test("day total sums known durations")
    func dayTotalSumsDurations() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Self.date("2026-09-03 15:00", calendar: calendar)
        let groups = HistoryViewModel.makeDayGroups(
            entries: [
                entry(id: "a", startedAt: Self.date("2026-09-03 09:00", calendar: calendar), durationSeconds: 4800),
                entry(id: "b", startedAt: Self.date("2026-09-03 14:00", calendar: calendar), durationSeconds: 1200)
            ],
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en")
        )
        #expect(groups[0].total == "1h 40m")
    }

    @Test("day total renders Russian units under the ru locale")
    func dayTotalRussianUnits() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Self.date("2026-09-03 15:00", calendar: calendar)
        let groups = HistoryViewModel.makeDayGroups(
            entries: [
                entry(id: "a", startedAt: Self.date("2026-09-03 09:00", calendar: calendar), durationSeconds: 4800),
                entry(id: "b", startedAt: Self.date("2026-09-03 14:00", calendar: calendar), durationSeconds: 1200)
            ],
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "ru")
        )
        #expect(groups[0].total == "1 ч 40 мин")
    }

    @Test("in-progress entries contribute zero to the day total")
    func inProgressContributesZero() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Self.date("2026-09-03 15:00", calendar: calendar)
        let groups = HistoryViewModel.makeDayGroups(
            entries: [
                entry(id: "done", startedAt: Self.date("2026-09-03 09:00", calendar: calendar), durationSeconds: 4800),
                entry(id: "running", startedAt: Self.date("2026-09-03 14:00", calendar: calendar))
            ],
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en")
        )
        #expect(groups[0].total == "1h 20m")
    }

    @Test("empty day total is 0s")
    func emptyDayTotal() {
        let total = HistoryViewModel.naturalDuration(0, locale: Locale(identifier: "en"))
        #expect(total == "0s")
    }

    // MARK: - Entry-owned category resolution (remove-activities-layer 4.4)

    @Test("rows read categories from the entry itself, position-preserved")
    func loadsAndResolvesCategories() async throws {
        // Fixed midday anchors: relative `Date(timeIntervalSinceNow:)`
        // offsets straddle midnight when the suite runs just after 00:00,
        // splitting the two entries across day groups (device/CI flake).
        let noon = Date(timeIntervalSince1970: 1_718_449_200)
        let store = try makeStore()
        try await store.createCategory(Category(id: "c1", name: "Health", icon: "figure.run"))
        try await store.createCategory(Category(id: "c2", name: "Work", icon: "briefcase"))
        try await store.createEntry(entry(
            id: "e1",
            startedAt: noon.addingTimeInterval(-3600),
            text: "Running",
            categoryIDs: ["c2", "c1"],
            durationSeconds: 3600,
            endedAt: noon
        ))
        try await store.createEntry(entry(
            id: "e2",
            startedAt: noon.addingTimeInterval(-7200),
            text: "Meditation",
            durationSeconds: 600,
            endedAt: noon.addingTimeInterval(-6000)
        ))

        let vm = HistoryViewModel(store: store, undoBuffer: UndoBufferStore(store: store))
        await vm.load()

        #expect(vm.dayGroups.count == 1)
        #expect(vm.dayGroups[0].entries.count == 2)

        let running = vm.dayGroups[0].entries.first { $0.id == "e1" }!
        #expect(vm.icon(for: running) == "briefcase")
        #expect(vm.categoryNames(for: running) == "Work, Health")

        let meditation = vm.dayGroups[0].entries.first { $0.id == "e2" }!
        #expect(vm.icon(for: meditation) == "questionmark")
        #expect(vm.categoryNames(for: meditation).isEmpty)
    }

    @Test("a deleted category vanishes from rows while entries survive")
    func deletedCategoryStripsRows() async throws {
        let store = try makeStore()
        try await store.createCategory(Category(id: "c1", name: "Health", icon: "figure.run"))
        try await store.createEntry(entry(
            id: "e1",
            startedAt: Date(timeIntervalSinceNow: -3600),
            text: "Running",
            categoryIDs: ["c1"],
            durationSeconds: 60,
            endedAt: Date(timeIntervalSinceNow: -3540)
        ))

        let vm = HistoryViewModel(store: store, undoBuffer: UndoBufferStore(store: store))
        await vm.loadIfNeeded()
        #expect(vm.categoryNames(for: vm.dayGroups[0].entries[0]) == "Health")

        try await store.deleteCategory(id: "c1")
        vm.invalidate()
        await vm.loadIfNeeded()

        #expect(vm.dayGroups.count == 1)
        #expect(vm.icon(for: vm.dayGroups[0].entries[0]) == "questionmark")
        #expect(vm.categoryNames(for: vm.dayGroups[0].entries[0]).isEmpty)
    }

    @Test("in-progress entry shows the in-progress indicator")
    func inProgressDisplay() async throws {
        let store = try makeStore()
        try await store.createEntry(entry(id: "e1", startedAt: Date(timeIntervalSinceNow: -60)))

        let vm = HistoryViewModel(store: store, undoBuffer: UndoBufferStore(store: store))
        await vm.load()

        let running = vm.dayGroups[0].entries[0]
        #expect(vm.isInProgress(running))
        #expect(vm.durationText(for: running) == L10n.historyInProgress.text)
        #expect(vm.timeframeText(for: running).contains(L10n.historyInProgress.text))
    }

    // MARK: - Reload contract (loadIfNeeded / invalidate)

    @Test("loadIfNeeded serves the cached snapshot until invalidate, then reloads")
    func reloadAfterInvalidate() async throws {
        let store = try makeStore()
        try await store.createEntry(entry(
            id: "e1",
            startedAt: Date(timeIntervalSinceNow: -3600),
            durationSeconds: 60,
            endedAt: Date(timeIntervalSinceNow: -3540)
        ))

        let vm = HistoryViewModel(store: store, undoBuffer: UndoBufferStore(store: store))
        await vm.loadIfNeeded()
        #expect(vm.dayGroups.flatMap(\.entries).map(\.id) == ["e1"])

        // Entry saved elsewhere (Track tab, compact timer) while History is
        // off-screen must not leak into the cached snapshot…
        try await store.createEntry(entry(
            id: "e2",
            startedAt: Date(timeIntervalSinceNow: -600),
            durationSeconds: 30,
            endedAt: Date(timeIntervalSinceNow: -570)
        ))
        await vm.loadIfNeeded()
        #expect(vm.dayGroups.flatMap(\.entries).map(\.id) == ["e1"])

        // …but appears after invalidate (History re-appears) + loadIfNeeded.
        vm.invalidate()
        await vm.loadIfNeeded()
        #expect(vm.dayGroups.flatMap(\.entries).map(\.id) == ["e2", "e1"])
    }

    // MARK: - Entry edit/delete propagation (entry-editor)

    @Test("edited entry values appear after invalidate + reload")
    func editedEntryReflectedAfterReload() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSinceNow: -3600)
        // Fixed timestamps: the LWW gate (`updated_at < ?`) must hold by
        // construction, never by wall-clock luck (GRDB stores dates at
        // millisecond precision; two racing `Date()`s can land in one).
        let createdAt = Date(timeIntervalSinceNow: -7200)
        try await store.createEntry(TimeEntry(
            id: "e1", activityText: "Entry e1",
            startedAt: start, endedAt: start.addingTimeInterval(60),
            durationSeconds: 60, categoryIDs: [],
            createdAt: createdAt, updatedAt: createdAt
        ))

        let vm = HistoryViewModel(store: store, undoBuffer: UndoBufferStore(store: store))
        await vm.loadIfNeeded()
        #expect(vm.durationText(for: vm.dayGroups[0].entries[0], locale: Locale(identifier: "en")) == "1m")

        // Edit behind the entry form cover (the updateEntry path).
        var updated = try #require(try await store.entry(id: "e1"))
        updated.endedAt = start.addingTimeInterval(3_700)
        updated.durationSeconds = 3_700
        updated.updatedAt = createdAt.addingTimeInterval(3_600)
        #expect(try await store.updateEntry(updated))

        vm.invalidate()
        await vm.loadIfNeeded()
        #expect(vm.dayGroups.flatMap(\.entries).map(\.id) == ["e1"])
        #expect(vm.durationText(for: vm.dayGroups[0].entries[0], locale: Locale(identifier: "en")) == "1h 1m")
    }

    @Test("deleted entry disappears and empties its day group after reload")
    func deletedEntryRemovedAfterReload() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSinceNow: -3600)
        try await store.createEntry(entry(
            id: "e1",
            startedAt: start,
            durationSeconds: 60,
            endedAt: start.addingTimeInterval(60)
        ))

        let vm = HistoryViewModel(store: store, undoBuffer: UndoBufferStore(store: store))
        await vm.loadIfNeeded()
        #expect(vm.dayGroups.count == 1)

        // Delete behind the entry form (the undoable path).
        _ = try await store.deleteEntryUndoable(id: "e1", deletedAt: Date())

        vm.invalidate()
        await vm.loadIfNeeded()
        #expect(vm.dayGroups.isEmpty)
    }

    // MARK: - Sync merge propagation (fix-history-sync-refresh)

    @Test("synced pull appears and tombstone deletion disappears after invalidate + reload")
    func syncMergeReflectedAfterReload() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSinceNow: -3600)
        try await store.createEntry(entry(
            id: "local",
            startedAt: start,
            durationSeconds: 60,
            endedAt: start.addingTimeInterval(60)
        ))

        let vm = HistoryViewModel(store: store, undoBuffer: UndoBufferStore(store: store))
        await vm.loadIfNeeded()
        #expect(vm.dayGroups.flatMap(\.entries).map(\.id) == ["local"])

        // A sync pull merges a cross-device entry behind the visible list.
        let remoteStart = Date(timeIntervalSinceNow: -600)
        try await store.mergeEntry(entry(
            id: "remote",
            startedAt: remoteStart,
            text: "Remote",
            durationSeconds: 30,
            endedAt: remoteStart.addingTimeInterval(30)
        ))
        // The guarded snapshot hides it — the stale-list bug.
        await vm.loadIfNeeded()
        #expect(vm.dayGroups.flatMap(\.entries).map(\.id) == ["local"])

        // The view's sync observer runs invalidate + loadIfNeeded on cycle end.
        vm.invalidate()
        await vm.loadIfNeeded()
        #expect(vm.dayGroups.flatMap(\.entries).map(\.id) == ["remote", "local"])

        // A tombstone for a cross-device delete converges on the next cycle.
        try await store.applyDeletionTombstone(Deletion(
            resource: "entry",
            recordID: "remote",
            deletedAt: Date()
        ))
        vm.invalidate()
        await vm.loadIfNeeded()
        #expect(vm.dayGroups.flatMap(\.entries).map(\.id) == ["local"])
    }

    // MARK: - Entry shake-to-undo (fix-87)

    @Test("registerSystemUndo registers the newest entry deletion and performUndo restores it")
    func entryUndoRegistersAndRestores() async throws {
        let store = try makeStore()
        try await store.createCategory(Category(id: "c1", name: "Health", icon: "figure.run"))
        try await store.createCategory(Category(id: "c2", name: "Work", icon: "briefcase"))
        try await store.createEntry(entry(
            id: "e1",
            startedAt: Date(timeIntervalSinceNow: -3600),
            text: "Running",
            categoryIDs: ["c2", "c1"],
            durationSeconds: 600,
            endedAt: Date(timeIntervalSinceNow: -3000)
        ))
        _ = try await store.deleteEntryUndoable(id: "e1", deletedAt: Date())

        let vm = HistoryViewModel(store: store, undoBuffer: UndoBufferStore(store: store))
        await vm.loadIfNeeded()
        #expect(vm.dayGroups.isEmpty)

        let undoManager = UndoManager()
        await vm.registerSystemUndo(with: undoManager)
        #expect(undoManager.canUndo)
        #expect(undoManager.undoActionName == L10n.entryDeleteConfirm.text)

        await vm.performUndo()

        #expect(try await store.entry(id: "e1")?.activityText == "Running")
        #expect(vm.dayGroups.flatMap(\.entries).map(\.id) == ["e1"])
        let restored = try #require(vm.dayGroups.flatMap(\.entries).first { $0.id == "e1" })
        #expect(vm.categoryNames(for: restored) == "Work, Health")
        #expect(vm.undoError == nil)
        let rows = try await store.outboxRows()
        #expect(rows.allSatisfy { $0.op != "delete" })
    }

    @Test("a category-newest buffer offers nothing to the entry path")
    func categoryNewestOffersNothing() async throws {
        let store = try makeStore()
        try await store.createCategory(Category(id: "c1", name: "Work", icon: "briefcase"))
        _ = try await store.deleteCategoryUndoable(id: "c1", deletedAt: Date())

        let vm = HistoryViewModel(store: store, undoBuffer: UndoBufferStore(store: store))
        let undoManager = UndoManager()
        await vm.registerSystemUndo(with: undoManager)
        await vm.performUndo()

        #expect(!undoManager.canUndo)
        // The foreign buffer row is untouched and still restorable by its owner.
        #expect(try await store.undoBufferMostRecent() != nil)
        #expect(try await store.category(id: "c1") == nil)
        #expect(vm.undoError == nil)
    }

    @Test("performUndo is refused with the persistence error while the push is in flight")
    func inFlightPushRefusesUndo() async throws {
        let store = try makeStore()
        try await store.createEntry(entry(
            id: "e1",
            startedAt: Date(timeIntervalSinceNow: -3600),
            durationSeconds: 60,
            endedAt: Date(timeIntervalSinceNow: -3540)
        ))
        _ = try await store.deleteEntryUndoable(id: "e1", deletedAt: Date())

        let vm = HistoryViewModel(store: store, undoBuffer: UndoBufferStore(store: store))
        await store.setUndoPushInFlight(true)
        await vm.performUndo()
        await store.setUndoPushInFlight(false)

        #expect(vm.undoError == L10n.errorLocalPersistence.text)
        #expect(try await store.entry(id: "e1") == nil)
        #expect(try await store.undoBufferMostRecent() != nil)
        // The dialog dismiss path clears the error.
        vm.clearUndoError()
        #expect(vm.undoError == nil)
    }

    // MARK: - Notes indicator (history-entry-notes-icon)

    @Test("hasNotes is true only for non-blank notes")
    func hasNotesFlagsNonBlankNotes() throws {
        let store = try makeStore()
        let vm = HistoryViewModel(store: store, undoBuffer: UndoBufferStore(store: store))
        func flagged(_ notes: String) -> Bool {
            vm.hasNotes(for: TimeEntry(id: "e", activityText: "T", startedAt: Date(), notes: notes))
        }
        #expect(!flagged(""))
        #expect(!flagged("   "))
        #expect(!flagged("\n  \n"))
        #expect(flagged("leg day"))
        #expect(flagged("  padded  "))
    }

    // MARK: - Helpers

    private static func date(_ iso: String, calendar: Calendar) -> Date {
        let parts = iso.split(separator: " ")
        let dateParts = parts[0].split(separator: "-").compactMap { Int($0) }
        let timeParts = parts[1].split(separator: ":").compactMap { Int($0) }
        var comps = DateComponents()
        comps.year = dateParts[0]
        comps.month = dateParts[1]
        comps.day = dateParts[2]
        comps.hour = timeParts[0]
        comps.minute = timeParts[1]
        comps.calendar = calendar
        return comps.date!
    }
}
