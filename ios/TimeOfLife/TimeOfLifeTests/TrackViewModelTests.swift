// swiftlint:disable file_length
import Testing
import Foundation
import GRDB
@testable import TimeOfLife

@MainActor
@Suite("TrackViewModel")
struct TrackViewModelTests {

    // MARK: - State transitions

    @Test("initial state is idle with no draft")
    func initialState() {
        let vm = makeViewModel()
        #expect(vm.state == .idle)
        #expect(vm.state.draft == nil)
        #expect(vm.elapsed == 0)
        #expect(!vm.canStart)
    }

    @Test("empty trimmed text cannot start")
    func emptyTextCannotStart() {
        let vm = makeViewModel()
        vm.nameDraft = "   "
        vm.state = .ready(TrackState.Draft(text: "   "))
        #expect(!vm.canStart)
        vm.start()
        #expect(vm.state == .ready(TrackState.Draft(text: "   ")))
    }

    @Test("start transitions ready to running and persists the draft")
    func startRuns() async throws {
        let vm = makeViewModel()
        let store = vm.service.store
        try await store.createCategory(Category(id: "c1", name: "Work", icon: CatalogIcon.briefcase.rawValue))
        try await store.createEntry(makeEntry(id: "e1", text: "Coding", categoryIDs: ["c1"]))
        vm.recents = try await storeRecents(store)
        vm.nameDraft = "Coding"
        vm.state = .ready(TrackState.Draft(text: "Coding", categoryIDs: ["c1"]))
        vm.start()

        await waitForPersistedDraft(vm)
        guard case let .running(draft, _) = vm.state else {
            Issue.record("expected running state")
            return
        }
        #expect(draft.text == "Coding")
        // Exact-recent match inherits its full ordered categories.
        #expect(draft.categoryIDs == ["c1"])
        #expect(vm.state.isRunning)

        let state = try await vm.service.runningTimerDraft()
        #expect(state != nil)
        #expect(state?.status == "running")
        #expect(state?.activityText == "Coding")
    }

    @Test("start without an exact recents match starts with empty categories")
    func startInheritsNothingWithoutMatch() async throws {
        let vm = makeViewModel()
        vm.nameDraft = "Novel"
        vm.state = .ready(TrackState.Draft(text: "Novel"))
        vm.start()

        try? await Task.sleep(nanoseconds: 50_000_000)
        guard case let .running(draft, _) = vm.state else {
            Issue.record("expected running state")
            return
        }
        #expect(draft.categoryIDs.isEmpty)
    }

    @Test("stop saves entry with final tags and returns to saved then ready")
    func stopSaves() async {
        let vm = makeViewModel()
        try? await vm.service.store.createCategory(Category(id: "c9", name: "Health", icon: CatalogIcon.briefcase.rawValue))
        vm.nameDraft = "Reading"
        vm.state = .ready(TrackState.Draft(text: "Reading"))
        vm.start()
        await waitForPersistedDraft(vm)
        guard case .running = vm.state else {
            Issue.record("expected running state")
            return
        }
        vm.toggleDraftCategory("c9")

        await vm.stop()

        guard case let .saved(draft, duration) = vm.state else {
            Issue.record("expected saved state")
            return
        }
        #expect(draft.text == "Reading")
        #expect(draft.categoryIDs == ["c9"])
        #expect(duration >= 0)
        #expect(!vm.state.isRunning)

        let entries = try? await vm.service.store.entries()
        #expect(entries?.count == 1)
        #expect(entries?.first?.source == "manual")
        #expect(entries?.first?.activityText == "Reading")
        #expect(entries?.first?.categoryIDs == ["c9"])
        #expect(entries?.first?.notes.isEmpty == true)

        let state = try? await vm.service.runningTimerDraft()
        #expect(state == nil)
    }

    @Test("stop saves the entry with the final draft notes")
    func stopSavesNotes() async throws {
        let vm = makeViewModel()
        vm.nameDraft = "Reading"
        vm.state = .ready(TrackState.Draft(text: "Reading"))
        vm.start()
        await waitForPersistedDraft(vm)
        guard case .running = vm.state else {
            Issue.record("expected running state")
            return
        }
        await vm.updateDraftNotes("steady pace\nsecond wind")

        await vm.stop()

        let entries = try await vm.service.store.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.notes == "steady pace\nsecond wind")
    }

    @Test("toggling tags mid-run rewrites only the running draft snapshot")
    func toggleRewritesDraftOnly() async throws {
        let vm = makeViewModel()
        // Seeded explicitly (awaited): the toggle persist is fire-and-forget,
        // so racing it against start()'s own un-awaited write would flake.
        let startedAt = Date()
        try await vm.service.store.saveTimerDraft(activityText: "Work", categoryIDs: ["c1"], startedAt: startedAt)
        vm.state = .running(TrackState.Draft(text: "Work", categoryIDs: ["c1"]), startedAt: startedAt)

        vm.toggleDraftCategory("c1") // deselect
        vm.toggleDraftCategory("c2") // select
        await waitForPersistedDraft(vm) { $0?.categoryIDs == ["c2"] }

        guard case let .running(draft, _) = vm.state else {
            Issue.record("expected running state")
            return
        }
        // Order preserved: the surviving selection appends in toggle order.
        #expect(draft.categoryIDs == ["c2"])
        #expect(try await vm.service.store.entries().isEmpty)
        let persisted = try await vm.service.runningTimerDraft()
        #expect(persisted?.categoryIDs == ["c2"])
        // No entry exists mid-run; nothing entered History.
        #expect(try await vm.service.store.outboxRows().allSatisfy { $0.resource != "entry" })
    }

    @Test("saving notes mid-run rewrites only the draft snapshot")
    func notesRewritesDraftOnly() async throws {
        let vm = makeViewModel()
        vm.nameDraft = "Work"
        vm.state = .ready(TrackState.Draft(text: "Work", categoryIDs: ["c1"]))
        vm.start()
        await waitForPersistedDraft(vm)

        await vm.updateDraftNotes("remember HR belt")

        guard case let .running(draft, _) = vm.state else {
            Issue.record("expected running state")
            return
        }
        #expect(draft.notes == "remember HR belt")
        #expect(draft.text == "Work")
        #expect(draft.categoryIDs == ["c1"])
        #expect(try await vm.service.store.entries().isEmpty)
        let persisted = try await vm.service.runningTimerDraft()
        #expect(persisted?.notes == "remember HR belt")
        #expect(persisted?.activityText == "Work")
        // No entry exists mid-run; nothing entered History.
        #expect(try await vm.service.store.outboxRows().allSatisfy { $0.resource != "entry" })
    }

    @Test("saving notes in the error state preserves the error case")
    func notesInErrorPreservesCase() async throws {
        let vm = makeViewModel()
        let startedAt = Date()
        try await vm.service.store.saveTimerDraft(activityText: "Work", categoryIDs: [], startedAt: startedAt)
        vm.state = .error(TrackState.Draft(text: "Work"), startedAt: startedAt)

        await vm.updateDraftNotes("retry with notes")

        guard case let .error(draft, _) = vm.state else {
            Issue.record("expected error state")
            return
        }
        #expect(draft.notes == "retry with notes")
        #expect(try await vm.service.runningTimerDraft()?.notes == "retry with notes")
    }

    @Test("notes save failure surfaces an error preserving the draft")
    func notesSaveFailureSurfacesError() async throws {
        // A failed persist must never report silent success: with the
        // table gone the UPDATE throws, the banner raises, and the
        // in-memory notes survive for a retry (beginRunning grammar).
        let url = temporaryStoreURL()
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: url)
        let service = TimerService(store: store)
        let vm = TrackViewModel(service: service, connectivity: MockConnectivity(connected: true))
        let startedAt = Date()
        try await store.saveTimerDraft(activityText: "Work", categoryIDs: [], startedAt: startedAt)
        vm.state = .running(TrackState.Draft(text: "Work"), startedAt: startedAt)
        try dropTimerStateTable(at: url)

        await vm.updateDraftNotes("unsaved thought")

        #expect(vm.errorMessage != nil)
        guard case let .running(draft, _) = vm.state else {
            Issue.record("expected running state")
            return
        }
        #expect(draft.notes == "unsaved thought")
    }

    /// Drops the draft table to force persistence failures. Fixture-only:
    /// app mutation paths stay behind LocalStore.
    private func dropTimerStateTable(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "DROP TABLE timer_state")
        }
    }

    @Test("load restores persisted draft notes into the running state")
    func loadRestoresDraftNotes() async throws {
        let vm = makeViewModel()
        let startedAt = Date().addingTimeInterval(-60)
        try await vm.service.store.saveTimerDraft(
            activityText: "Work",
            categoryIDs: [],
            startedAt: startedAt,
            notes: "resumed thought"
        )

        await vm.load()

        guard case let .running(draft, _) = vm.state else {
            Issue.record("expected running state")
            return
        }
        #expect(draft.notes == "resumed thought")
    }

    @Test("load with no persisted draft reconciles a running state back to ready")
    func loadReconcilesExternallyStoppedTimer() async {
        // The external-stop path (compact-timer stop on another
        // destination): a `.running` state with no persisted draft must
        // leave running instead of counting forever — and must not carry
        // the previous run's notes into the next Start.
        let vm = makeViewModel()
        vm.state = .running(
            TrackState.Draft(text: "Work", categoryIDs: ["c1"], notes: "stale"),
            startedAt: Date().addingTimeInterval(-30)
        )

        await vm.load()

        guard case let .ready(draft) = vm.state else {
            Issue.record("expected ready state")
            return
        }
        #expect(draft.text == "Work")
        #expect(draft.categoryIDs == ["c1"])
        #expect(draft.notes.isEmpty)
        #expect(vm.elapsed == 0)
    }

    @Test("elapsed formatting matches TimeFormatter")
    func elapsedFormatting() {
        let vm = makeViewModel()
        vm.nameDraft = "Work"
        vm.state = .ready(TrackState.Draft(text: "Work"))
        vm.start()
        vm.elapsed = 125

        #expect(TimeFormatter.formattedDuration(vm.elapsed) == "02:05")
        #expect(TimeFormatter.formattedDuration(3661) == "1:01:01")
    }

    // MARK: - Recents

    @Test("load populates the recents and the categories map")
    func loadPopulatesRecents() async throws {
        let vm = makeViewModel()
        let store = vm.service.store
        try await store.createCategory(Category(id: "c1", name: "Work", icon: CatalogIcon.briefcase.rawValue))
        try await store.createEntry(makeEntry(id: "e1", text: "Coding", categoryIDs: ["c1"]))

        await vm.load()

        #expect(vm.recents.map(\.text) == ["Coding"])
        #expect(vm.recents.first?.firstCategoryID == "c1")
        #expect(vm.categories["c1"]?.name == "Work")
    }

    @Test("load on a fresh store leaves recents empty without seeding")
    func loadEmptyRecents() async throws {
        let vm = makeViewModel()

        await vm.load()

        #expect(vm.recents.isEmpty)
        // Seeding lives behind the sign-in gate (`RootView`) only — this
        // load never seeds, so a fresh dataset reports no categories until
        // the gate seeds them.
        #expect(vm.categories.isEmpty)
    }

    @Test("exact text identity: Gym and GYM are separate recents")
    func exactRecentsIdentity() async throws {
        let vm = makeViewModel()
        let store = vm.service.store
        try await store.createEntry(makeEntry(id: "e1", text: "Gym", startedAt: Date(timeIntervalSinceNow: -100)))
        try await store.createEntry(makeEntry(id: "e2", text: "GYM"))

        await vm.load()

        #expect(Set(vm.recents.map(\.text)) == ["Gym", "GYM"])
        // Newest first by that text's newest started_at.
        #expect(vm.recents.first?.text == "GYM")
    }

    @Test("selecting a recents chip prepares it without starting")
    func selectChipPrepares() async throws {
        let vm = makeViewModel()
        vm.recents = [ExactName(text: "Reading", categoryIDs: ["c1"], firstCategoryID: "c1")]

        vm.select(vm.recents[0])

        #expect(vm.state == .ready(TrackState.Draft(text: "Reading", categoryIDs: ["c1"])))
        #expect(vm.elapsed == 0)
        #expect(!vm.state.isRunning)
        #expect(try await vm.service.store.entries().isEmpty)
    }

    @Test("editing after a chip selection re-derives the draft from the field")
    func editAfterChipReselects() async throws {
        let vm = makeViewModel()
        let store = vm.service.store
        try await store.createCategory(Category(id: "c1", name: "Work", icon: CatalogIcon.briefcase.rawValue))
        try await store.createEntry(makeEntry(id: "e1", text: "Gym", categoryIDs: ["c1"]))
        vm.recents = try await storeRecents(store)
        vm.select(vm.recents[0])
        #expect(vm.state == .ready(TrackState.Draft(text: "Gym", categoryIDs: ["c1"])))

        // Typing a different text must follow the field, not the stale chip.
        vm.nameDraft = "Gym2"
        vm.syncReadyFromDraft()
        #expect(vm.state == .ready(TrackState.Draft(text: "Gym2", categoryIDs: [])))

        // Clearing the field returns to idle.
        vm.nameDraft = "   "
        vm.syncReadyFromDraft()
        #expect(vm.state == .idle)
    }

    @Test("typing a history-tagged name inherits its categories after reload")
    func typingInheritsAfterHistoryEdit() async throws {
        let vm = makeViewModel()
        let store = vm.service.store
        try await store.createCategory(Category(id: "c1", name: "Sport", icon: CatalogIcon.briefcase.rawValue))
        // Entry first saved categoryless (e.g. from the timer), then tagged
        // from the History entry form.
        try await store.createEntry(makeEntry(id: "e1", text: "Gym"))
        var tagged = try #require(try await store.entry(id: "e1"))
        tagged.categoryIDs = ["c1"]
        tagged.updatedAt = Date().addingTimeInterval(10)
        #expect(try await store.updateEntry(tagged))

        // Returning to Track reloads recents + categories (AppShellView).
        await vm.load()
        #expect(vm.recents.first?.categoryIDs == ["c1"])
        #expect(vm.categories["c1"]?.name == "Sport")

        vm.nameDraft = "Gym"
        vm.syncReadyFromDraft()
        #expect(vm.state == .ready(TrackState.Draft(text: "Gym", categoryIDs: ["c1"])))

        vm.start()
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard case let .running(draft, _) = vm.state else {
            Issue.record("expected running state")
            return
        }
        #expect(draft.categoryIDs == ["c1"])
    }

    @Test("start is immediate: ready transitions to running on the tap")
    func startIsImmediate() async {
        let vm = makeViewModel()
        vm.nameDraft = "Gym"
        vm.state = .ready(TrackState.Draft(text: "Gym"))

        let tapTime = Date()
        vm.start()
        guard case let .running(draft, startedAt) = vm.state else {
            Issue.record("expected running state immediately")
            return
        }
        #expect(draft.text == "Gym")
        #expect(startedAt >= tapTime)
        #expect(startedAt.timeIntervalSince(tapTime) < 1)
    }

    @Test("a draft edit before start prepares the fresh text")
    func draftEditBeforeStartPreparesFreshText() async {
        let vm = makeViewModel()
        vm.nameDraft = "Gym"
        vm.state = .ready(TrackState.Draft(text: "Gym"))

        vm.nameDraft = "Gym2"
        vm.syncReadyFromDraft()
        vm.start()

        guard case let .running(draft, _) = vm.state else {
            Issue.record("expected running state")
            return
        }
        #expect(draft.text == "Gym2")
    }

    @Test("start after a post-stop edit starts on the first tap with fresh text")
    func staleDraftFirstTapStarts() async {
        let vm = makeViewModel()
        // Post-stop state: the committed draft is stale for the edited field.
        vm.nameDraft = "Gym"
        vm.state = .ready(TrackState.Draft(text: "Gym"))
        vm.nameDraft = "Gym2"

        vm.start()
        // Tap-time sync brings the preparation up to date at once.
        guard case let .running(draft, _) = vm.state else {
            Issue.record("expected running state after the first tap")
            return
        }
        #expect(draft.text == "Gym2")
    }

    @Test("editing during the saved confirmation returns to ready at once")
    func editDuringSavedReturnsToReady() {
        let vm = makeViewModel()
        vm.nameDraft = "Reading"
        vm.state = .saved(TrackState.Draft(text: "Reading"), duration: 65)

        vm.nameDraft = "Gym"
        vm.syncReadyFromDraft()

        #expect(vm.state == .ready(TrackState.Draft(text: "Gym", categoryIDs: [])))
    }

    // MARK: - Recoverable save failure

    @Test("stop retry after a recoverable failure preserves elapsed state")
    func retryStopPreservesState() async {
        let vm = makeViewModel()
        vm.nameDraft = "Reading"
        vm.state = .ready(TrackState.Draft(text: "Reading"))
        vm.start()
        try? await Task.sleep(nanoseconds: 10_000_000)
        guard case let .running(draft, startedAt) = vm.state else {
            Issue.record("expected running state")
            return
        }

        // Simulate the recoverable error path.
        vm.state = .error(draft, startedAt: startedAt)
        await vm.retryStop()

        guard case let .saved(saved, _) = vm.state else {
            Issue.record("expected saved state")
            return
        }
        #expect(saved.text == "Reading")
        #expect((try? await vm.service.store.entries().count) == 1)
    }

    // MARK: - Name affordances (feat-name-field-affordances)

    @Test("load fills both the capped recents and the uncapped picker names")
    func loadFillsRecentsAndAllNames() async throws {
        let vm = makeViewModel()
        let store = vm.service.store
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        for index in 0..<14 {
            try await store.createEntry(makeEntry(
                id: "e\(index)",
                text: "Text\(index)",
                startedAt: base.addingTimeInterval(Double(index))
            ))
        }
        await vm.load()
        #expect(vm.recents.count == 12)
        #expect(vm.recents.first?.text == "Text13")
        #expect(vm.allNames.count == 14)
        #expect(vm.allNames.first?.text == "Text13")
    }

    @Test("stop refreshes recents and picker names in lockstep")
    func stopRefreshesBothLists() async {
        let vm = makeViewModel()
        vm.nameDraft = "Gym"
        vm.state = .running(TrackState.Draft(text: "Gym"), startedAt: Date())
        await vm.stop()
        #expect(vm.recents.map(\.text) == ["Gym"])
        #expect(vm.allNames.map(\.text) == ["Gym"])
    }

    // MARK: - Inline category creation

    @Test("attaching while running appends to the draft and persists the snapshot")
    func attachCreatedCategoryWhileRunning() async {
        let vm = makeViewModel()
        vm.nameDraft = "Reading"
        vm.state = .ready(TrackState.Draft(text: "Reading"))
        vm.start()
        await waitForPersistedDraft(vm)

        vm.attachCreatedCategory(Category(id: "c1", name: "Garden", icon: "leaf"))
        guard case let .running(draft, _) = vm.state else {
            Issue.record("expected running state")
            return
        }
        #expect(draft.categoryIDs == ["c1"])
        #expect(vm.categories["c1"]?.name == "Garden")
        await waitForPersistedDraft(vm) { $0?.categoryIDs == ["c1"] }
        let persisted = try? await vm.service.runningTimerDraft()
        #expect(persisted?.categoryIDs == ["c1"], "persisted draft must carry the attached category; wait alone passes on timeout")
    }

    /// Attaching in the recoverable error state appends to the held draft
    /// (updateDraftNotes parity), so a category created mid-run is not lost
    /// when the stop is retried.
    @Test("attaching in the error state appends to the held draft")
    func attachCreatedCategoryWhileError() async {
        let vm = makeViewModel()
        vm.state = .error(TrackState.Draft(text: "Reading"), startedAt: Date())
        vm.attachCreatedCategory(Category(id: "c1", name: "Garden", icon: "leaf"))
        guard case let .error(draft, _) = vm.state else {
            Issue.record("expected error state")
            return
        }
        #expect(draft.categoryIDs == ["c1"])
        #expect(vm.categories["c1"]?.name == "Garden")
        await waitForPersistedDraft(vm) { $0?.categoryIDs == ["c1"] }
        let persisted = try? await vm.service.runningTimerDraft()
        #expect(persisted?.categoryIDs == ["c1"], "persisted draft must carry the attached category; wait alone passes on timeout")
    }

    @Test("attaching outside a held draft only freshens the pool")
    func attachCreatedCategoryWhileIdle() {
        let vm = makeViewModel()
        vm.attachCreatedCategory(Category(id: "c1", name: "Garden", icon: "leaf"))
        #expect(vm.categories["c1"]?.name == "Garden")
        #expect(vm.state == .idle)
    }

    // MARK: - Helpers

    private func makeEntry(
        id: String,
        text: String,
        categoryIDs: [String] = [],
        startedAt: Date = Date(),
        duration: Int = 60
    ) -> TimeEntry {
        TimeEntry(
            id: id,
            activityText: text,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(TimeInterval(duration)),
            durationSeconds: duration,
            source: "manual",
            categoryIDs: categoryIDs
        )
    }

    private func storeRecents(_ store: LocalStore) async throws -> [ExactName] {
        try await store.recents(limit: TrackViewModel.recentsLimit).map(ExactName.init(storeRecent:))
    }

    private func makeViewModel() -> TrackViewModel {
        let connectivity = MockConnectivity(connected: true)
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: temporaryStoreURL())
        let service = TimerService(store: store)
        return TrackViewModel(service: service, connectivity: connectivity)
    }

    /// Waits for a persisted-draft condition (bounded): `start()` persists
    /// via an un-awaited Task, so fixed delays flake under CI load. Callers
    /// asserting persisted state must wait on the signal, not the clock.
    private func waitForPersistedDraft(
        _ vm: TrackViewModel,
        matching condition: (RunningTimerDraft?) -> Bool = { $0 != nil }
    ) async {
        for _ in 0..<100 {
            do {
                if condition(try await vm.service.runningTimerDraft()) { return }
            } catch {
                // Store read failed; retry within the bound.
                continue
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func temporaryStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(LocalStore.databaseFileName(userID: "u1"))
    }
}
