// swiftlint:disable file_length
import Testing
import Foundation
@testable import TimeOfLife

@MainActor
@Suite("LogTimeViewModel")
struct LogTimeViewModelTests {

    // MARK: - Defaults

    @Test("sheet opens with Start floored to 5 minutes and End one hour later")
    func defaultTimes() {
        // 2:37:20 PM -> Start 2:35 PM, End 3:35 PM.
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 9
        components.hour = 14
        components.minute = 37
        components.second = 20
        let now = Calendar.current.date(from: components)!
        let vm = makeViewModel(now: now)

        let calendar = Calendar.current
        #expect(calendar.component(.minute, from: vm.startsAt) == 35)
        #expect(calendar.component(.second, from: vm.startsAt) == 0)
        #expect(vm.endsAt.timeIntervalSince(vm.startsAt) == 3_600)
    }

    @Test("sheet opens with empty name, categories, and notes")
    func defaultEmptyFields() {
        let vm = makeViewModel()
        #expect(vm.name.isEmpty)
        #expect(vm.categoryIDs.isEmpty)
        #expect(vm.notes.isEmpty)
        #expect(!vm.isAddEnabled)
    }

    // MARK: - Validity gate

    @Test("Add is disabled with an empty name")
    func gateRequiresName() {
        let vm = makeViewModel()
        #expect(!vm.isAddEnabled)
    }

    @Test("Add is disabled with a whitespace-only name")
    func gateWhitespaceName() {
        let vm = makeViewModel()
        vm.name = "   "
        #expect(!vm.isAddEnabled)
    }

    @Test("Add enables when the trimmed name is non-empty and End is after Start")
    func gateValidForm() {
        let vm = makeViewModel()
        vm.name = " Reading "

        #expect(vm.isAddEnabled)
    }

    @Test("Add disables when End moves to Start")
    func gateEndEqualStart() {
        let vm = makeViewModel()
        vm.name = "Reading"

        vm.setEndsAt(vm.startsAt)

        #expect(!vm.isAddEnabled)
    }

    @Test("Add disables when End moves before Start")
    func gateEndBeforeStart() {
        let vm = makeViewModel()
        vm.name = "Reading"

        vm.setEndsAt(vm.startsAt.addingTimeInterval(-60))

        #expect(!vm.isAddEnabled)
    }

    // MARK: - Duration preservation

    @Test("moving Start past End auto-pushes End preserving duration")
    func startPastEndPushesEnd() {
        let vm = makeViewModel()
        let originalEnd = vm.endsAt

        vm.setStartsAt(originalEnd.addingTimeInterval(25 * 60))

        #expect(vm.endsAt == originalEnd.addingTimeInterval(25 * 60).addingTimeInterval(3_600))
    }

    @Test("moving Start earlier shifts End preserving duration")
    func startEarlierShiftsEnd() {
        let vm = makeViewModel()
        let originalStart = vm.startsAt
        let originalEnd = vm.endsAt

        vm.setStartsAt(vm.startsAt.addingTimeInterval(-95 * 60))

        #expect(vm.startsAt == originalStart.addingTimeInterval(-95 * 60))
        #expect(vm.endsAt == originalEnd.addingTimeInterval(-95 * 60))
        #expect(vm.endsAt.timeIntervalSince(vm.startsAt) == 3_600)
    }

    @Test("a shortened custom duration is the one preserved on push")
    func customDurationPreserved() {
        let vm = makeViewModel()
        vm.name = "Reading"
        vm.setEndsAt(vm.startsAt.addingTimeInterval(30 * 60))

        vm.setStartsAt(vm.startsAt.addingTimeInterval(2 * 3_600))

        #expect(vm.endsAt.timeIntervalSince(vm.startsAt) == 30 * 60)
    }

    @Test("moving End never moves Start")
    func endNeverMovesStart() {
        let vm = makeViewModel()
        let originalStart = vm.startsAt

        vm.setEndsAt(originalStart.addingTimeInterval(-10))

        #expect(vm.startsAt == originalStart)
    }

    // MARK: - Category selection

    @Test("toggling categories preserves selection order")
    func togglePreservesOrder() {
        let vm = makeViewModel()
        vm.toggleCategory("c1")
        vm.toggleCategory("c2")
        vm.toggleCategory("c3")
        #expect(vm.categoryIDs == ["c1", "c2", "c3"])

        vm.toggleCategory("c2")
        #expect(vm.categoryIDs == ["c1", "c3"])
    }

    @Test("deselect-then-reselect appends at the end (ordinal source order)")
    func reselectAppendsAtEnd() {
        let vm = makeViewModel()
        vm.toggleCategory("c1")
        vm.toggleCategory("c2")
        vm.toggleCategory("c1")
        vm.toggleCategory("c1")
        #expect(vm.categoryIDs == ["c2", "c1"])
    }

    // MARK: - Save

    @Test("save persists a manual entry with text, tags, notes, and derived duration")
    func savePersistsManualEntry() async throws {
        let vm = makeViewModel()
        try? await vm.service.store.createCategory(Category(id: "c1", name: "Work", icon: CatalogIcon.briefcase.rawValue))
        try? await vm.service.store.createCategory(Category(id: "c2", name: "Health", icon: CatalogIcon.briefcase.rawValue))
        vm.name = "  Reading  "
        vm.notes = "Chapter 4"
        vm.toggleCategory("c1")
        vm.toggleCategory("c2")

        let saved = await vm.save()

        #expect(saved)
        let entries = try await vm.service.store.entries()
        #expect(entries.count == 1)
        #expect(entries[0].activityText == "Reading")
        #expect(entries[0].categoryIDs == ["c1", "c2"])
        #expect(entries[0].notes == "Chapter 4")
        #expect(entries[0].startedAt == vm.startsAt)
        #expect(entries[0].endedAt == vm.endsAt)
        #expect(entries[0].durationSeconds == 3_600)
        #expect(entries[0].source == "manual")
        #expect(entries[0].sourceRef == nil)
    }

    @Test("save on an invalid form returns false without an error")
    func saveInvalidForm() async {
        let vm = makeViewModel()

        let saved = await vm.save()

        #expect(!saved)
        #expect(vm.errorMessage == nil)
    }

    @Test("save never re-resolves an activity — the entry owns its text")
    func saveWithoutActivityResolve() async throws {
        let vm = makeViewModel()
        vm.name = "Gym"

        let saved = await vm.save()

        #expect(saved)
        #expect(try await vm.service.store.entries().first?.activityText == "Gym")
    }

    // MARK: - Modes

    @Test("mode routing: none is create, manual is edit, imported is locked")
    func modeRouting() {
        #expect(LogTimeViewModel.mode(for: nil) == .create)
        #expect(LogTimeViewModel.mode(for: storedEntry(source: "manual")) == .edit)
        #expect(LogTimeViewModel.mode(for: storedEntry(source: "garmin")) == .locked)
        #expect(LogTimeViewModel.mode(for: storedEntry(source: "healthkit")) == .locked)
    }

    @Test("EDIT prefills name, categories, notes, and interval from the entry")
    func editPrefillsFromEntry() async throws {
        let entry = storedEntry(categoryIDs: ["c1", "c2"], notes: "Some notes")
        let vm = makeViewModel(editing: entry)

        #expect(vm.mode == .edit)
        #expect(!vm.isLocked)
        #expect(vm.name == "Reading")
        #expect(vm.categoryIDs == ["c1", "c2"])
        #expect(vm.notes == "Some notes")
        #expect(vm.startsAt == entry.startedAt)
        #expect(vm.endsAt == entry.endedAt)
        #expect(vm.isAddEnabled)
    }

    @Test("LOCKED exposes values read-only with no confirm path")
    func lockedHasNoConfirmPath() async throws {
        let entry = storedEntry(source: "garmin")
        let vm = makeViewModel(editing: entry)

        #expect(vm.mode == .locked)
        #expect(vm.isLocked)
        #expect(vm.name == "Reading")
        #expect(vm.startsAt == entry.startedAt)

        #expect(await vm.save() == false)
        #expect(vm.errorMessage == nil)
    }

    // MARK: - EDIT gate and duration

    @Test("Save disables in EDIT when End moves to Start")
    func editGateEndEqualStart() async throws {
        let vm = makeViewModel(editing: storedEntry())
        vm.setEndsAt(vm.startsAt)

        #expect(!vm.isAddEnabled)
        #expect(await vm.save() == false)
    }

    @Test("EDIT preserves duration when Start is pushed past End")
    func editStartPushPreservesDuration() async throws {
        let vm = makeViewModel(editing: storedEntry())
        let originalDuration = vm.endsAt.timeIntervalSince(vm.startsAt)

        vm.setStartsAt(vm.endsAt.addingTimeInterval(600))

        #expect(vm.endsAt.timeIntervalSince(vm.startsAt) == originalDuration)
    }

    // MARK: - EDIT save

    @Test("EDIT save persists the new interval through updateEntry")
    func editSavePersistsUpdate() async throws {
        let store = try await makeStore()
        let entry = storedEntry()
        try await store.createEntry(entry)
        let vm = makeViewModel(store: store, editing: entry)

        vm.setEndsAt(vm.endsAt.addingTimeInterval(1_800))
        let saved = await vm.save()

        #expect(saved)
        let stored = try #require(try await store.entry(id: "e1"))
        #expect(stored.endedAt == vm.endsAt)
        #expect(stored.durationSeconds == 5_400)
        #expect(stored.updatedAt >= entry.updatedAt)
        let updates = try await store.outboxRows().filter { $0.op == "update" && $0.recordID == "e1" }
        #expect(updates.count == 1)
    }

    @Test("EDIT save retexts and retags only this entry")
    func editSaveRetextsRetags() async throws {
        let store = try await makeStore()
        let entry = storedEntry()
        try await store.createEntry(entry)
        let other = storedEntry(id: "e2")
        try await store.createEntry(other)
        try await store.createCategory(Category(id: "c9", name: "Health", icon: CatalogIcon.briefcase.rawValue))
        let vm = makeViewModel(store: store, editing: entry)
        vm.name = "Workout"
        vm.toggleCategory("c9")

        #expect(await vm.save())

        #expect(try await store.entry(id: "e1")?.activityText == "Workout")
        #expect(try await store.entry(id: "e1")?.categoryIDs == ["c9"])
        // No other entry with the same text changes (per-entry isolation).
        #expect(try await store.entry(id: "e2")?.activityText == "Reading")
        #expect(try await store.entry(id: "e2")?.categoryIDs.isEmpty == true)
    }

    @Test("EDIT save fails with the draft intact on a stale write")
    func editSaveStaleKeepsDraft() async throws {
        let store = try await makeStore()
        let entry = storedEntry()
        try await store.createEntry(entry)
        let vm = makeViewModel(store: store, editing: entry)

        // A newer version lands underneath (e.g. a sync pull).
        var newer = entry
        newer.endedAt = entry.endedAt?.addingTimeInterval(60)
        newer.durationSeconds = 3_660
        newer.updatedAt = Date().addingTimeInterval(60)
        try await store.mergeEntry(newer)

        vm.setEndsAt(vm.endsAt.addingTimeInterval(1_800))
        let keptEnd = vm.endsAt
        let saved = await vm.save()

        #expect(!saved)
        #expect(vm.errorMessage == L10n.entryStaleError.text)
        #expect(vm.endsAt == keptEnd)
    }

    // MARK: - Delete into the undo buffer

    @Test("deleteConfirmed removes the entry into the buffer without syncing")
    func deleteConfirmedBuffersWithoutSync() async throws {
        let store = try await makeStore()
        let entry = storedEntry()
        try await store.createEntry(entry)
        let vm = makeViewModel(store: store, editing: entry)

        #expect(await vm.deleteConfirmed())

        #expect(try await store.entry(id: "e1") == nil)
        #expect(try await store.undoBufferMostRecent() != nil)
        #expect(try await store.outboxRows().allSatisfy { $0.op != "delete" })
    }

    @Test("deleteConfirmed on an already-gone entry still dismisses")
    func deleteConfirmedMissingDismisses() async throws {
        let store = try await makeStore()
        let vm = makeViewModel(store: store, editing: storedEntry())

        #expect(await vm.deleteConfirmed())
    }

    @Test("deleteConfirmed in CREATE mode does nothing")
    func deleteConfirmedCreateDoesNothing() async throws {
        let store = try await makeStore()
        let vm = makeViewModel(store: store)

        #expect(await vm.deleteConfirmed() == false)
        #expect(try await store.undoBufferMostRecent() == nil)
    }

    // MARK: - Duration subtitle helper (feat-entry-duration-subtitle)

    @Test("durationSubtitleSeconds returns the interval seconds when valid")
    func durationSubtitleValid() {
        let vm = makeViewModel()
        // Fresh sheet: Start floored, End = Start + 1h.
        #expect(vm.durationSubtitleSeconds == 3_600)
    }

    @Test("durationSubtitleSeconds is nil when End is at or before Start")
    func durationSubtitleInvalid() {
        let vm = makeViewModel()
        vm.setEndsAt(vm.startsAt)
        #expect(vm.durationSubtitleSeconds == nil)
        vm.setEndsAt(vm.startsAt.addingTimeInterval(-60))
        #expect(vm.durationSubtitleSeconds == nil)
    }

    @Test("touched sub-minute interval disables the gate with no subtitle")
    func durationSubtitleTouchedSubMinute() {
        let vm = makeViewModel()
        vm.name = "Reading"
        vm.setEndsAt(vm.startsAt.addingTimeInterval(0.4))
        #expect(!vm.isAddEnabled)
        #expect(vm.durationSubtitleSeconds == nil)
    }

    @Test("edited interval boundary: 30s disabled, exactly 60s enabled")
    func gateFloorBoundary() {
        let vm = makeViewModel()
        vm.name = "Reading"

        vm.setEndsAt(vm.startsAt.addingTimeInterval(30))
        #expect(!vm.isAddEnabled)

        vm.setEndsAt(vm.startsAt.addingTimeInterval(60))
        #expect(vm.isAddEnabled)
    }

    // MARK: - Name suggestions (feat-name-field-affordances)

    @Test("loadNameRecentsIfNeeded loads all names uncapped, newest-first")
    func loadNameRecentsLoadsAll() async throws {
        let store = try await makeStore()
        let base = Date(timeIntervalSinceReferenceDate: 20_000)
        for index in 0..<8 {
            let start = base.addingTimeInterval(Double(index))
            try await store.createEntry(TimeEntry(
                id: "e\(index)", activityText: "Text\(index)",
                startedAt: start, endedAt: start.addingTimeInterval(600),
                durationSeconds: 600, source: "manual",
                categoryIDs: [], notes: "",
                createdAt: start, updatedAt: start
            ))
        }
        let vm = makeViewModel(store: store)
        await vm.loadNameRecentsIfNeeded(store: store)
        #expect(vm.nameRecents.count == 8)
        #expect(vm.nameRecents.first?.text == "Text7")
        // Idempotent: a second load keeps the first result.
        await vm.loadNameRecentsIfNeeded(store: store)
        #expect(vm.nameRecents.count == 8)
    }

    @Test("applySuggestion fills text plus ordered categories without touching the rest")
    func applySuggestionFills() {
        let vm = makeViewModel()
        vm.notes = "keep me"
        vm.applySuggestion(text: "Gym", categoryIDs: ["c1", "c2"])
        #expect(vm.name == "Gym")
        #expect(vm.categoryIDs == ["c1", "c2"])
        #expect(vm.notes == "keep me")
        #expect(vm.isAddEnabled)
    }

    @Test("completeTypedName inherits categories on exact match")
    func completeTypedNameExactMatch() {
        let vm = makeViewModel()
        vm.nameRecents = [ExactName(text: "Gym", categoryIDs: ["c1"], firstCategoryID: "c1")]
        vm.completeTypedName("Gym")
        #expect(vm.name == "Gym")
        #expect(vm.categoryIDs == ["c1"])
    }

    @Test("completeTypedName keeps categories for a new name")
    func completeTypedNameNewName() {
        let vm = makeViewModel()
        vm.nameRecents = [ExactName(text: "Gym", categoryIDs: ["c1"], firstCategoryID: "c1")]
        vm.toggleCategory("c2")
        vm.completeTypedName("Run")
        #expect(vm.name == "Run")
        #expect(vm.categoryIDs == ["c2"])
    }

    @Test("completeTypedName is a no-op for empty input")
    func completeTypedNameEmpty() {
        let vm = makeViewModel()
        vm.name = "Gym"
        vm.completeTypedName("   ")
        #expect(vm.name == "Gym")
    }

    @Test("save preserves multiline notes with newlines")
    func savePreservesMultilineNotes() async throws {
        let vm = makeViewModel()
        vm.name = "Gym"
        vm.notes = "warmup\n5x5 squats\nstretch"

        let saved = await vm.save()

        #expect(saved)
        let entries = try await vm.service.store.entries()
        #expect(entries.count == 1)
        #expect(entries[0].notes == "warmup\n5x5 squats\nstretch")
    }

    @Test("EDIT prefills multiline notes verbatim")
    func editPrefillsMultilineNotes() {
        let entry = storedEntry(notes: "line one\nline two")
        let vm = makeViewModel(editing: entry)

        #expect(vm.mode == .edit)
        #expect(vm.notes == "line one\nline two")
    }

    @Test("loadNameRecentsIfNeeded loads the store recents once")
    func loadNameRecentsLoads() async throws {
        let store = try await makeStore()
        let start = Date(timeIntervalSinceReferenceDate: 20_000)
        try await store.createEntry(TimeEntry(
            id: "e9", activityText: "Gym",
            startedAt: start, endedAt: start.addingTimeInterval(600),
            durationSeconds: 600, source: "manual",
            categoryIDs: [], notes: "",
            createdAt: start, updatedAt: start
        ))
        let vm = makeViewModel(store: store)
        await vm.loadNameRecentsIfNeeded(store: store)
        #expect(vm.nameRecents.map(\.text) == ["Gym"])
        // Idempotent: a second load keeps the first result.
        await vm.loadNameRecentsIfNeeded(store: store)
        #expect(vm.nameRecents.count == 1)
    }

    // MARK: - Duration floor + grandfathering (time-picker-duration-floor)

    @Test("sub-minute prefill shows mapped pills with the true subtitle, gate enabled")
    func grandfatheredDisplayMapping() {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(2 * 3_600 + 35 * 60)
        let vm = makeViewModel(editing: storedEntry(start: start, duration: 33))

        #expect(vm.displayStartsAt == start)
        #expect(vm.displayEndsAt == start.addingTimeInterval(60))
        #expect(vm.durationSubtitleSeconds == 33)
        #expect(vm.isAddEnabled)
    }

    @Test("display mapping floors, never rounds (0:00:15–0:00:25 stays valid)")
    func displayMappingFloors() {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(15)
        let vm = makeViewModel(editing: storedEntry(start: start, duration: 10))

        #expect(vm.displayStartsAt == day)
        #expect(vm.displayEndsAt == day.addingTimeInterval(60))
        #expect(vm.isAddEnabled)
    }

    @Test("untouched save writes back the original sub-minute times")
    func grandfatheredSavePreservesOriginals() async throws {
        let store = try await makeStore()
        // Fixed past date, never "today": the LWW save guard compares the
        // stored updated_at against wall-clock now, so a today-dated entry
        // fails whenever the suite runs before 02:35 runner-local time
        // (cloud-only red). The date value is irrelevant to the behavior
        // under test (untouched sub-minute prefill writes back originals).
        let start = Date(timeIntervalSinceReferenceDate: 2 * 3_600 + 35 * 60)
        let entry = storedEntry(start: start, duration: 33)
        try await store.createEntry(entry)
        try? await store.createCategory(Category(id: "c1", name: "Work", icon: CatalogIcon.briefcase.rawValue))
        let vm = makeViewModel(store: store, editing: entry)

        vm.toggleCategory("c1")
        #expect(await vm.save())

        let stored = try #require(try await store.entry(id: "e1"))
        #expect(stored.startedAt == start)
        #expect(stored.endedAt == start.addingTimeInterval(33))
        #expect(stored.durationSeconds == 33)
    }

    @Test("first time touch adopts display values, then the gesture applies")
    func firstTouchAdoptsDisplayValues() {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(2 * 3_600 + 35 * 60)
        let vm = makeViewModel(editing: storedEntry(start: start, duration: 33))

        vm.setStartsAt(day.addingTimeInterval(2 * 3_600))

        // Adopted 2:35–2:36, then delta −35m applied on top.
        #expect(vm.startsAt == day.addingTimeInterval(2 * 3_600))
        #expect(vm.endsAt == day.addingTimeInterval(2 * 3_600 + 60))
        #expect(vm.isAddEnabled)
    }

    @Test("touched draft under one minute in EDIT disables the gate")
    func editTouchedFloorGate() {
        let vm = makeViewModel(editing: storedEntry())
        // 30s past the displayed (floored) start: minute-floored to a 0s draft.
        vm.setEndsAt(vm.displayStartsAt.addingTimeInterval(30))

        #expect(!vm.isAddEnabled)
        #expect(vm.durationSubtitleSeconds == nil)
    }

    @Test("zero-duration prefill keeps the invalid path")
    func zeroDurationPrefillDisabled() {
        let vm = makeViewModel(editing: storedEntry(duration: 0))

        #expect(!vm.isAddEnabled)
        #expect(vm.durationSubtitleSeconds == nil)
    }

    @Test("untouched draft with seconds displays floored pills with true subtitle")
    func secondsDraftDisplayMapping() {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(23 * 3_600 + 59 * 60 + 34)
        let vm = makeViewModel(editing: storedEntry(start: start, duration: 144))

        #expect(vm.displayStartsAt == day.addingTimeInterval(23 * 3_600 + 59 * 60))
        #expect(vm.displayEndsAt == day.addingTimeInterval(24 * 3_600 + 60))
        #expect(vm.durationSubtitleSeconds == 144)
        #expect(vm.isAddEnabled)
    }

    @Test("first touch drops seconds on both ends (23:59:34–00:01:58 → 23:59–00:01)")
    func firstTouchDropsSecondsShorter() {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(23 * 3_600 + 59 * 60 + 34)
        let vm = makeViewModel(editing: storedEntry(start: start, duration: 144))

        // Touch with the displayed value: pure normalization, no move.
        vm.setStartsAt(vm.displayStartsAt)

        #expect(vm.startsAt == day.addingTimeInterval(23 * 3_600 + 59 * 60))
        #expect(vm.endsAt == day.addingTimeInterval(24 * 3_600 + 60))
        #expect(vm.endsAt.timeIntervalSince(vm.startsAt) == 120)
        #expect(vm.isAddEnabled)
    }

    @Test("first touch floors both ends even when duration grows (2m29s → 3m)")
    func firstTouchDropsSecondsLonger() {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(23 * 3_600 + 59 * 60 + 34)
        let vm = makeViewModel(editing: storedEntry(start: start, duration: 149))

        vm.setStartsAt(vm.displayStartsAt)

        #expect(vm.startsAt == day.addingTimeInterval(23 * 3_600 + 59 * 60))
        #expect(vm.endsAt == day.addingTimeInterval(24 * 3_600 + 2 * 60))
        #expect(vm.endsAt.timeIntervalSince(vm.startsAt) == 180)
        #expect(vm.isAddEnabled)
    }

    @Test("start move on a seconds draft normalizes first, then shifts by delta")
    func startMoveOnSecondsDraftNormalizesFirst() {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(23 * 3_600 + 59 * 60 + 34)
        let vm = makeViewModel(editing: storedEntry(start: start, duration: 144))

        // Adopted 23:59–00:01, then +1h on top.
        vm.setStartsAt(day.addingTimeInterval(24 * 3_600 + 59 * 60))

        #expect(vm.startsAt == day.addingTimeInterval(24 * 3_600 + 59 * 60))
        #expect(vm.endsAt == day.addingTimeInterval(25 * 3_600 + 60))
        #expect(vm.endsAt.timeIntervalSince(vm.startsAt) == 120)
    }

    // MARK: - End range consistency (selection always inside range)

    @Test("seconds grandfathered selection lies inside the end-time range")
    func rangeContainsSecondsGrandfatheredSelection() {
        // The bot's exact example: raw backing would bind 2:37, the
        // display-derived bound is 2:36 == selection.
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(2 * 3_600 + 35 * 60 + 20)
        let vm = makeViewModel(editing: storedEntry(start: start, duration: 33))

        #expect(vm.endTimeRange.lowerBound == day.addingTimeInterval(2 * 3_600 + 36 * 60))
        #expect(vm.endTimeRange.contains(vm.displayEndsAt))
    }

    @Test("normal seconds draft selection lies inside both end ranges")
    func rangeContainsNormalSecondsSelection() {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(2 * 3_600 + 35 * 60 + 33)
        let vm = makeViewModel(editing: storedEntry(start: start, duration: 3_600))

        #expect(vm.endTimeRange.contains(vm.displayEndsAt))
        #expect(vm.endDateRange?.contains(vm.displayEndsAt) == true)
    }

    @Test("cross-day start move keeps the selection inside the end ranges")
    func rangeFollowsCrossDayStartMove() {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(10 * 3_600)
        let vm = makeViewModel(editing: storedEntry(start: start, duration: 3_600))

        vm.setStartsAt(start.addingTimeInterval(2 * 86_400))

        #expect(vm.endTimeRange.contains(vm.displayEndsAt))
        #expect(vm.endDateRange?.contains(vm.displayEndsAt) == true)
    }

    @Test("touched minute-exact bound is exactly start plus one minute")
    func rangeBoundExactForMinuteExactStart() {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(2 * 3_600 + 35 * 60)
        let vm = makeViewModel(editing: storedEntry(start: start, duration: 3_600))

        #expect(vm.endTimeRange.lowerBound == vm.displayStartsAt.addingTimeInterval(60))
    }

    @Test("corrupt same-day end-before-start falls back with the gate disabled")
    func rangeCorruptSameDayFallback() {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(3 * 3_600)
        // End an hour before Start, same day.
        let vm = makeViewModel(editing: storedEntry(start: start, duration: -3_600))

        #expect(vm.endTimeRange.contains(vm.displayEndsAt))
        #expect(!vm.isAddEnabled)
        #expect(vm.durationSubtitleSeconds == nil)
    }

    @Test("corrupt cross-day end-before-start leaves the date picker unbounded")
    func rangeCorruptCrossDayUnboundedDate() {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(86_400 + 10 * 3_600)
        // End a full day before Start.
        let vm = makeViewModel(editing: storedEntry(start: start, duration: -86_400))

        #expect(vm.endDateRange == nil)
        #expect(vm.endTimeRange.contains(vm.displayEndsAt))
        #expect(!vm.isAddEnabled)
    }

    // MARK: - Inline category creation

    @Test("attaching a created category selects it and loads store order")
    func attachCreatedCategorySelects() async throws {
        let store = try await makeStore()
        let garden = Category(id: "c2", name: "Garden", icon: "leaf")
        try await store.createCategory(garden)
        let vm = makeViewModel(store: store)
        await vm.attachCreatedCategory(garden)
        #expect(vm.availableCategories.map(\.id) == ["c2"])
        #expect(vm.categoryIDs == ["c2"])
    }

    @Test("attaching loads the canonical store order, not client collation")
    func attachCreatedCategoryLoadsStoreOrder() async throws {
        let store = try await makeStore()
        try await store.createCategory(Category(id: "c1", name: "Work", icon: "briefcase"))
        let vm = makeViewModel(store: store)
        let garden = Category(id: "c2", name: "Garden", icon: "leaf")
        try await store.createCategory(garden)
        await vm.attachCreatedCategory(garden)
        #expect(vm.availableCategories.map(\.name) == ["Garden", "Work"])
        #expect(vm.categoryIDs == ["c2"])
    }

    @Test("re-attaching never duplicates selection")
    func attachCreatedCategoryIdempotent() async throws {
        let store = try await makeStore()
        let category = Category(id: "c1", name: "Work", icon: "briefcase")
        try await store.createCategory(category)
        let vm = makeViewModel(store: store)
        await vm.attachCreatedCategory(category)
        await vm.attachCreatedCategory(category)
        #expect(vm.availableCategories.count == 1)
        #expect(vm.categoryIDs == ["c1"])
    }

    @Test("attaching preserves the rest of the draft")
    func attachCreatedCategoryPreservesDraft() async throws {
        let store = try await makeStore()
        let garden = Category(id: "c9", name: "Garden", icon: "leaf")
        try await store.createCategory(garden)
        let vm = makeViewModel(store: store)
        vm.name = "Planting"
        vm.notes = "Bed three"
        await vm.attachCreatedCategory(garden)
        #expect(vm.name == "Planting")
        #expect(vm.notes == "Bed three")
        #expect(vm.categoryIDs == ["c9"])
    }

    // MARK: - Helpers

    private func storedEntry(
        id: String = "e1",
        source: String = "manual",
        categoryIDs: [String] = [],
        notes: String = "",
        start: Date = Date(timeIntervalSinceReferenceDate: 10_000),
        duration: TimeInterval = 3_600
    ) -> TimeEntry {
        let end = start.addingTimeInterval(duration)
        return TimeEntry(
            id: id, activityText: "Reading",
            startedAt: start, endedAt: end,
            durationSeconds: Int(duration), source: source,
            categoryIDs: categoryIDs, notes: notes,
            createdAt: start, updatedAt: start
        )
    }

    private func makeStore() async throws -> LocalStore {
        try LocalStore(url: temporaryStoreURL())
    }

    private func makeViewModel(
        now: Date = Date()
    ) -> LogTimeViewModel {
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: temporaryStoreURL())
        let service = TimerService(store: store)
        return LogTimeViewModel(service: service, now: now)
    }

    private func makeViewModel(
        store: LocalStore,
        editing entry: TimeEntry? = nil
    ) -> LogTimeViewModel {
        let service = TimerService(store: store)
        return LogTimeViewModel(service: service, editing: entry)
    }

    private func makeViewModel(editing entry: TimeEntry) -> LogTimeViewModel {
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: temporaryStoreURL())
        let service = TimerService(store: store)
        return LogTimeViewModel(service: service, editing: entry)
    }

    private func temporaryStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(LocalStore.databaseFileName(userID: "u1"))
    }
}
