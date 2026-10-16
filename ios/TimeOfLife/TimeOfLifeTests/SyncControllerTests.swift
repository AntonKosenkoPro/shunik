// swiftlint:disable file_length
import Testing
import Foundation
@testable import TimeOfLife

@MainActor
@Suite("SyncController")
struct SyncControllerTests {

    // MARK: - Cycle ordering

    @Test("first sync pulls categories before draining the entry outbox")
    func firstSyncPullsBeforeDrain() async throws {
        let (store, mock, controller) = makeContext()
        try await store.createEntry(makeEntry(id: "e1", text: "Local"))

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        let pullIndex = mock.calls.firstIndex { $0.method == "fetchCategories" }
        let pushIndex = mock.calls.firstIndex { $0.method == "createEntry" }
        #expect(pullIndex != nil)
        #expect(pushIndex != nil)
        if let pullIndex, let pushIndex {
            #expect(pullIndex < pushIndex)
        }
        #expect(isIdle(controller.status))
        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("delta pull advances the per-resource cursor and reuses it")
    func deltaPullAdvancesCursor() async throws {
        let (store, mock, controller) = makeContext()
        let cursor = Date(timeIntervalSince1970: 1_700_000_000)
        mock.entriesResult = [makeEntry(id: "e1", text: "Server", updatedAt: cursor)]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(try await store.lastSyncedAt(resource: "entry") == cursor)

        mock.clearLog()
        await controller.syncNow(userID: "u1")

        #expect(mock.fetchedModifiedSince.first == cursor)
    }

    @Test("paged pull converges the full history and advances the cursor over all pages")
    func pagedPullConvergesFullHistory() async throws {
        let (store, mock, controller) = makeContext()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 120 server entries, relay order newest-started_at first across 3
        // pages (50/50/20). The global updated_at max sits on the LAST page:
        // page order (started_at) is uncorrelated with cursor order
        // (updated_at), so advancing to a partial-page max would strand the
        // tail forever.
        let globalMax = base.addingTimeInterval(1_000_000)
        var all: [TimeEntry] = []
        for i in 0..<120 {
            let updatedAt = i == 5 ? globalMax : base.addingTimeInterval(TimeInterval(i))
            all.append(makeEntry(
                id: "pg-e\(i)", text: "Entry \(i)",
                startedAt: base.addingTimeInterval(TimeInterval(i) * 3600),
                createdAt: base.addingTimeInterval(TimeInterval(i) * 3600),
                updatedAt: updatedAt
            ))
        }
        let newestFirst = all.sorted { $0.startedAt > $1.startedAt }
        mock.entriesPages = [
            Array(newestFirst[0..<50]),
            Array(newestFirst[50..<100]),
            Array(newestFirst[100..<120]),
        ]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // Every page fetched with the delta filter held fixed, resumed by cursor.
        #expect(mock.fetchedEntryPageCursors == [nil, "page-1", "page-2"])
        // The complete history merged — including the last page's rows.
        #expect(try await store.entries().count == 120)
        #expect(try await store.entry(id: "pg-e5")?.activityText == "Entry 5")
        // The cursor reflects the complete result, not the first page.
        #expect(try await store.lastSyncedAt(resource: "entry") == globalMax)

        // The follow-up delta reuses the global cursor.
        mock.clearLog()
        await controller.syncNow(userID: "u1")

        #expect(mock.fetchedModifiedSince.first == globalMax)
        #expect(isIdle(controller.status))
    }

    @Test("upgrade with a poisoned cursor heals the truncated tail on the next cycle")
    func poisonedCursorHealsOnUpgrade() async throws {
        let (store, _, controller, _, globalMax) = try await makePoisonedUpgradeContext()

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // The re-baseline ran (flag row present) ...
        #expect(try await store.lastSyncedAt(resource: "entry_rebaseline") != nil)
        // ... so the poisoned cursor never constrained the pull: all 120
        // rows converged, including a first-page row no delta could see.
        #expect(try await store.entries().count == 120)
        #expect(try await store.entry(id: "up-e119")?.activityText == "Entry 119")
        // ... and the cursor landed on the global max.
        #expect(try await store.lastSyncedAt(resource: "entry") == globalMax)
        #expect(isIdle(controller.status))
    }

    @Test("re-baseline runs exactly once: the next cycle is a normal delta")
    func rebaselineRunsExactlyOnce() async throws {
        let (store, mock, controller, _, globalMax) = try await makePoisonedUpgradeContext()

        controller.activate(userID: "u1")
        await waitForCycle(controller)
        #expect(try await store.entries().count == 120)

        mock.clearLog()
        await controller.syncNow(userID: "u1")

        // No cursor discard: the delta starts at the healed global max, the
        // relay (filtering strictly newer) returns nothing, and the cursor
        // is untouched.
        #expect(mock.fetchedModifiedSince.first == globalMax)
        #expect(try await store.entries().count == 120)
        #expect(try await store.lastSyncedAt(resource: "entry") == globalMax)
        #expect(isIdle(controller.status))
    }

    /// A relay history whose first page holds the SMALLEST updatedAts
    /// (updatedAt inverse to startedAt, except a global-max trap on the last
    /// page) plus a store cursor poisoned by a pre-fix single-page pull
    /// (that page's partial max). Returns the poisoned cursor and global max.
    private func makePoisonedUpgradeContext() async throws -> (
        store: LocalStore, mock: MockCatalogRepository, controller: SyncController,
        poisoned: Date, globalMax: Date
    ) {
        let (store, mock, controller) = makeContext()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let globalMax = base.addingTimeInterval(10_000)
        var all: [TimeEntry] = []
        for i in 0..<120 {
            let updatedAt = i == 5 ? globalMax : base.addingTimeInterval(TimeInterval(119 - i))
            all.append(makeEntry(
                id: "up-e\(i)", text: "Entry \(i)",
                startedAt: base.addingTimeInterval(TimeInterval(i) * 3600),
                createdAt: base.addingTimeInterval(TimeInterval(i) * 3600),
                updatedAt: updatedAt
            ))
        }
        let newestFirst = all.sorted { $0.startedAt > $1.startedAt }
        mock.entriesPages = [
            Array(newestFirst[0..<50]),
            Array(newestFirst[50..<100]),
            Array(newestFirst[100..<120]),
        ]
        mock.filterPagesByModifiedSince = true
        let poisoned = base.addingTimeInterval(49)
        try await store.setLastSyncedAt(resource: "entry", date: poisoned)
        return (store, mock, controller, poisoned, globalMax)
    }

    // MARK: - LWW merge

    @Test("LWW merge applies a newer server entry")
    func lwwMergeAppliesNewerServerEntry() async throws {
        let (store, mock, controller) = makeContext()
        let local = makeEntry(
            id: "e1", text: "Local",
            createdAt: Date(timeIntervalSince1970: 1_500_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        try await store.mergeEntry(local)
        let server = makeEntry(
            id: "e1", text: "Server",
            createdAt: Date(timeIntervalSince1970: 1_500_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        mock.entriesResult = [server]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        let entry = try await store.entry(id: "e1")
        #expect(entry?.activityText == "Server")
    }

    @Test("LWW merge keeps a newer local entry")
    func lwwMergeKeepsNewerLocalEntry() async throws {
        let (store, mock, controller) = makeContext()
        let local = makeEntry(
            id: "e1", text: "Local",
            createdAt: Date(timeIntervalSince1970: 1_500_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.mergeEntry(local)
        let server = makeEntry(
            id: "e1", text: "Server",
            createdAt: Date(timeIntervalSince1970: 1_500_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        mock.entriesResult = [server]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        let entry = try await store.entry(id: "e1")
        #expect(entry?.activityText == "Local")
    }

    @Test("equal texts with different ids stay independent records (no remap)")
    func nameCollisionKeepsBothRecords() async throws {
        let (store, mock, controller) = makeContext()
        try await store.mergeEntry(makeEntry(id: "local-gym", text: "Gym"))
        mock.entriesResult = [makeEntry(id: "server-gym", text: "Gym")]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(isIdle(controller.status))
        #expect(try await store.entry(id: "local-gym") != nil)
        #expect(try await store.entry(id: "server-gym") != nil)
        #expect(try await store.outboxRows().isEmpty)
    }

    // MARK: - Outbox drain

    @Test("outbox drain is idempotent")
    func outboxDrainIsIdempotent() async throws {
        let (store, mock, controller) = makeContext()
        try await store.createEntry(makeEntry(id: "e1", text: "A"))
        try await store.createEntry(makeEntry(id: "e2", text: "B"))

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        let pushes = mock.calls.filter { $0.method == "createEntry" }
        #expect(Set(pushes.compactMap(\.id)) == Set(["e1", "e2"]))
        #expect(try await store.outboxRows().isEmpty)

        mock.clearLog()
        try await store.createEntry(makeEntry(id: "e3", text: "C"))
        try await store.createEntry(makeEntry(id: "e4", text: "D"))
        let rowsBefore = try await store.outboxRows()

        await controller.syncNow(userID: "u1")

        let replayPushes = mock.calls.filter { $0.method == "createEntry" }
        #expect(replayPushes.map(\.id) == rowsBefore.map(\.recordID))
        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("entry push carries the entries-only payload with ordered tags")
    func entryPushCarriesPayload() async throws {
        let (store, mock, controller) = makeContext()
        var pushed: TimeEntry?
        mock.createEntryHandler = { pushed = $0 }
        try await store.mergeCategory(Category(id: "c1", name: "Work", icon: "tag"))
        try await store.mergeCategory(Category(id: "c2", name: "Health", icon: "tag"))
        try await store.createEntry(makeEntry(id: "e1", text: "Gym", categoryIDs: ["c1", "c2"], notes: "Leg day"))

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(pushed?.activityText == "Gym")
        #expect(pushed?.categoryIDs == ["c1", "c2"])
        #expect(pushed?.notes == "Leg day")
    }

    @Test("conflict adopts the server version")
    func conflictAdoptsServerVersion() async throws {
        let (store, mock, controller) = makeContext()
        try await store.createEntry(makeEntry(id: "e1", text: "Local"))
        let server = makeEntry(id: "e1", text: "Server", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        mock.createEntryHandler = { _ in
            throw APIError.server(code: "conflict", message: "stale", details: [:])
        }
        mock.fetchEntryHandler = { id in
            #expect(id == "e1")
            return server
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(try await store.outboxRows().isEmpty)
        let entry = try await store.entry(id: "e1")
        #expect(entry?.activityText == "Server")
    }

    // MARK: - Prune-unknown-category (remove-activities-layer D7)

    @Test("a pulled entry's unknown category id is pruned with the remainder kept")
    func pullPrunesUnknownCategory() async throws {
        let (store, mock, controller) = makeContext()
        let local = Category(id: "c-keep", name: "Sport", icon: "figure.run")
        mock.categoriesResult = [local]
        mock.entriesResult = [
            makeEntry(id: "e1", text: "Gym", categoryIDs: ["c-keep", "c-unknown"])
        ]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        let entry = try await store.entry(id: "e1")
        #expect(entry?.categoryIDs == ["c-keep"])
        #expect(isIdle(controller.status))
    }

    @Test("a pulled entry whose category ids are all unknown survives untagged")
    func pullPrunesAllUnknownCategories() async throws {
        let (store, mock, controller) = makeContext()
        mock.categoriesResult = []
        mock.entriesResult = [
            makeEntry(id: "e1", text: "Gym", categoryIDs: ["c-ghost"])
        ]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        let entry = try await store.entry(id: "e1")
        #expect(entry != nil)
        #expect(entry?.categoryIDs.isEmpty == true)
        #expect(isIdle(controller.status))
    }

    @Test("conflict adoption prunes unknown categories too")
    func conflictAdoptionPrunesUnknownCategories() async throws {
        let (store, mock, controller) = makeContext()
        try await store.createEntry(makeEntry(id: "e1", text: "Local"))
        let server = makeEntry(
            id: "e1", text: "Server", categoryIDs: ["c-unknown"],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        mock.categoriesResult = []

        mock.createEntryHandler = { _ in
            throw APIError.server(code: "conflict", message: "stale", details: [:])
        }
        mock.fetchEntryHandler = { _ in server }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        let entry = try await store.entry(id: "e1")
        #expect(entry?.activityText == "Server")
        #expect(entry?.categoryIDs.isEmpty == true)
    }

    // MARK: - In-progress drafts never sync (remove-activities-layer D3/D7)

    @Test("a running draft never enters the outbox and never syncs")
    func draftsNeverSync() async throws {
        let (store, mock, controller) = makeContext()
        try await store.saveTimerDraft(activityText: "Work", categoryIDs: ["c1"], startedAt: Date())

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(mock.calls.allSatisfy { $0.resource != "entry" || $0.method != "createEntry" })
        #expect(try await store.outboxRows().isEmpty)
        #expect(try await store.timerDraft() != nil)
    }

    // MARK: - Category sync (category-management D6)

    @Test("starter categories with pending create rows survive snapshot reconciliation")
    func starterCategoriesSurviveFirstSync() async throws {
        let (store, mock, controller) = makeContext()
        // First-sync with starter outbox rows: the relay has NO categories yet.
        mock.categoriesResult = []
        let seeded = try await store.seedStarterCategoriesIfNeeded(
            names: ["Work", "Hobby", "Sport", "Education", "Relax", "Sleep", "Entertainment"]
        )
        guard case let .seeded(starterCategories) = seeded else {
            Issue.record("expected seeded")
            return
        }
        let starterIDs = Set(starterCategories.map(\.id))

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        let stored = try await store.categories()
        #expect(Set(stored.map(\.id)) == starterIDs)
        // Their create outbox rows were drained but the categories remain.
        #expect(stored.count == 7)
    }

    @Test("clean local categories absent from the relay snapshot are removed")
    func cleanLocalCategoriesRemovedBySnapshot() async throws {
        let (store, mock, controller) = makeContext()
        // A clean local category (no pending outbox work) that the relay no
        // longer has must be removed by the authoritative snapshot.
        try await store.mergeCategory(Category(id: "local-cat", name: "Old", icon: "tag"))
        mock.categoriesResult = []

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(try await store.category(id: "local-cat") == nil)
    }

    @Test("categories with pending outbox work are preserved even when absent from the snapshot")
    func dirtyLocalCategoriesPreserved() async throws {
        let (store, mock, controller) = makeContext()
        try await store.createCategory(Category(id: "pending-cat", name: "Pending", icon: "tag"))
        mock.categoriesResult = []

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        let stored = try await store.category(id: "pending-cat")
        #expect(stored != nil)
        #expect(stored?.name == "Pending")
        // The create row was drained, so the relay now owns it; a subsequent
        // pull snapshot includes it.
    }

    @Test("remote category deletion arrives and strips entry joins while entries survive")
    func remoteCategoryDeletionConverges() async throws {
        let (store, mock, controller) = makeContext()
        // A clean local category (no pending outbox row): merged, not created.
        try await store.mergeCategory(Category(id: "cat-1", name: "Sport", icon: "tag"))
        try await store.createEntry(makeEntry(id: "e1", text: "Gym", categoryIDs: ["cat-1"]))
        // The relay snapshot no longer contains cat-1 (deleted on another
        // device); there is no pending outbox work for the category.
        mock.categoriesResult = []

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(try await store.category(id: "cat-1") == nil)
        let entry = try await store.entry(id: "e1")
        #expect(entry != nil)
        #expect(entry?.categoryIDs.isEmpty == true)
        // No category delete was ever sent to the relay.
        #expect(!mock.calls.contains(Call("deleteCategory", "category", "cat-1")))
    }

    @Test("idempotent replay after a failed pull does not duplicate categories")
    func idempotentReplayNoDuplicates() async throws {
        let (store, mock, controller) = makeContext()
        let category = Category(id: "cat-1", name: "Work", icon: "briefcase")
        mock.categoriesResult = [category]

        controller.activate(userID: "u1")
        await waitForCycle(controller)
        mock.clearLog()

        mock.categoriesResult = [category]
        await controller.syncNow(userID: "u1")
        await waitForCycle(controller)

        #expect(try await store.categories().count == 1)
        let fetches = mock.calls.filter { $0.method == "fetchCategories" }
        #expect(fetches.count == 1)
    }

    @Test("pull adopts a newer server category on a normalized-name collision")
    func pullAdoptsNewerServerCategory() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let new = Date(timeIntervalSince1970: 1_700_000_000)
        // Fresh-device seed (older) with its queued create row.
        try await store.createCategory(
            Category(
                id: "local-sport", name: "Sport", icon: "figure.run",
                createdAt: old, updatedAt: old
            )
        )
        mock.categoriesResult = [
            Category(
                id: "server-sport", name: "Sport", icon: "figure.run",
                createdAt: old, updatedAt: new
            )
        ]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // Server identity adopted during pull — no push round-trip, no failure.
        #expect(isIdle(controller.status))
        #expect(try await store.category(id: "local-sport") == nil)
        #expect(try await store.category(id: "server-sport")?.name == "Sport")
        #expect(try await store.outboxRows().isEmpty)
        #expect(mock.calls.allSatisfy { $0.method != "createCategory" })
    }

    @Test("pull keeps a newer local category and skips the server branch")
    func pullKeepsNewerLocalCategory() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let new = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.createCategory(
            Category(
                id: "local-sport", name: "Sport", icon: "figure.run",
                createdAt: new, updatedAt: new
            )
        )
        mock.categoriesResult = [
            Category(
                id: "server-sport", name: "Sport", icon: "figure.run",
                createdAt: old, updatedAt: old
            )
        ]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(isIdle(controller.status))
        #expect(try await store.category(id: "local-sport")?.name == "Sport")
        #expect(try await store.category(id: "server-sport") == nil)
    }

    @Test("category_exists remaps entry joins, removes the losing identity, and clears its create row")
    func categoryExistsRemapsWithoutLosingEntries() async throws {
        let (store, mock, controller) = makeContext()
        try await store.createCategory(Category(id: "local-id", name: "Sport", icon: "figure.run"))
        try await store.createEntry(makeEntry(id: "e1", text: "Gym", categoryIDs: ["local-id"]))
        let winner = Category(id: "server-id", name: "Sport", icon: "figure.run")

        mock.createCategoryHandler = { _ in
            throw APIError.server(
                code: "category_exists", message: "exists",
                details: ["id": "server-id", "name": "Sport"]
            )
        }
        mock.fetchCategoryHandler = { id in
            #expect(id == "server-id")
            return winner
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // The winning category is available locally.
        let storedWinner = try await store.category(id: "server-id")
        #expect(storedWinner?.name == "Sport")
        // The losing identity is gone, without a delete operation.
        #expect(try await store.category(id: "local-id") == nil)
        // The entry is intact and references the winner.
        let stored = try await store.entry(id: "e1")
        #expect(stored != nil)
        #expect(stored?.categoryIDs == ["server-id"])
        // The losing create row is cleared; no category delete row exists.
        let rows = try await store.outboxRows()
        #expect(rows.allSatisfy { $0.resource != "category" })
        #expect(isIdle(controller.status))
    }

    @Test("category_exists with a failing winner fetch keeps the row and merges nothing")
    func categoryExistsFetchFailureKeepsRow() async throws {
        let (store, mock, controller) = makeContext()
        try await store.createCategory(Category(id: "local-id", name: "Sport", icon: "figure.run"))

        mock.createCategoryHandler = { _ in
            throw APIError.server(
                code: "category_exists", message: "exists",
                details: ["id": "server-id", "name": "Sport"]
            )
        }
        mock.fetchCategoryHandler = { _ in throw APIError.offline }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // No stub merged: the losing identity keeps its real name.
        #expect(try await store.category(id: "server-id") == nil)
        #expect(try await store.category(id: "local-id")?.name == "Sport")
        // The outbox row stays queued for retry; the cycle surfaces the failure.
        let rows = try await store.outboxRows()
        #expect(rows.contains { $0.resource == "category" && $0.op == "create" && $0.recordID == "local-id" })
        guard case .error = controller.status else {
            Issue.record("expected error status, got \(controller.status)")
            return
        }
    }

    // MARK: - Delete-wins for entries and categories (remove-activities-layer)

    @Test("first sync does not resurrect an entry with a pending delete")
    func firstSyncSkipsPendingEntryDelete() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        // A previously synced record, now locally deleted (committed path,
        // so the outbox holds only the delete row).
        try await store.mergeEntry(makeEntry(id: "e1", text: "Gym", createdAt: old, updatedAt: old))
        try await store.deleteEntry(id: "e1")
        // The relay still holds it: pull-first merges before the drain pushes
        // the DELETE.
        mock.entriesResult = [makeEntry(id: "e1", text: "Gym", createdAt: old, updatedAt: old)]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(try await store.entry(id: "e1") == nil)
        #expect(mock.calls.contains(Call("deleteEntry", "entry", "e1")))
        #expect(try await store.outboxRows().isEmpty)
        #expect(isIdle(controller.status))
    }

    @Test("first sync does not resurrect a category with a pending delete")
    func firstSyncSkipsPendingCategoryDelete() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try await store.mergeCategory(
            Category(id: "c1", name: "Sport", icon: "figure.run", createdAt: old, updatedAt: old)
        )
        try await store.deleteCategory(id: "c1")
        mock.categoriesResult = [
            Category(id: "c1", name: "Sport", icon: "figure.run", createdAt: old, updatedAt: old)
        ]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(try await store.category(id: "c1") == nil)
        #expect(mock.calls.contains(Call("deleteCategory", "category", "c1")))
        #expect(isIdle(controller.status))
    }

    @Test("pull does not resurrect a buffered entry deletion (the buffered push commits it)")
    func pullSkipsBufferedEntryDeletion() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "Gym", createdAt: old, updatedAt: old))
        let deleted = try await store.deleteEntryUndoable(id: "e1")
        guard case .deleted = deleted else {
            Issue.record("expected deleted, got \(deleted)")
            return
        }
        mock.entriesResult = [makeEntry(id: "e1", text: "Gym", createdAt: old, updatedAt: old)]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // The pull skipped the relay copy (no resurrection), then the
        // buffered push committed the deletion: DELETE went out and the
        // buffer cleared — undo ends at push success.
        #expect(try await store.entry(id: "e1") == nil)
        #expect(mock.calls.contains(Call("deleteEntry", "entry", "e1")))
        #expect(try await store.undoBufferMostRecent() == nil)
        #expect(isIdle(controller.status))
    }

    @Test("pull does not resurrect a buffered category deletion (the buffered push commits it)")
    func pullSkipsBufferedCategoryDeletion() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try await store.mergeCategory(
            Category(id: "c1", name: "Sport", icon: "figure.run", createdAt: old, updatedAt: old)
        )
        let deleted = try await store.deleteCategoryUndoable(id: "c1")
        guard case .deleted = deleted else {
            Issue.record("expected deleted, got \(deleted)")
            return
        }
        mock.categoriesResult = [
            Category(id: "c1", name: "Sport", icon: "figure.run", createdAt: old, updatedAt: old)
        ]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(try await store.category(id: "c1") == nil)
        #expect(mock.calls.contains(Call("deleteCategory", "category", "c1")))
        #expect(try await store.undoBufferMostRecent() == nil)
        #expect(isIdle(controller.status))
    }

    @Test("update conflict does not resurrect a locally deleted entry")
    func conflictAdoptSkipsPendingDelete() async throws {
        let (store, mock, controller) = makeContext()
        let t0 = Date(timeIntervalSince1970: 1_600_000_000)
        let t1 = Date(timeIntervalSince1970: 1_650_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "Gym", createdAt: t0, updatedAt: t0))
        _ = try await store.updateEntry(makeEntry(id: "e1", text: "Gym v2", createdAt: t0, updatedAt: t1))
        try await store.deleteEntry(id: "e1")
        mock.updateEntryHandler = { _ in
            throw APIError.server(code: "conflict", message: "stale", details: [:])
        }
        mock.fetchEntryHandler = { _ in
            makeEntry(id: "e1", text: "Server", createdAt: t0, updatedAt: t2)
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(try await store.entry(id: "e1") == nil)
        #expect(mock.calls.contains(Call("deleteEntry", "entry", "e1")))
        #expect(try await store.outboxRows().isEmpty)
        #expect(isIdle(controller.status))
    }

    // MARK: - Deletion tombstones (entries and categories only)

    @Test("entry tombstone converges with joins cascade, no outbox, and cursor advance")
    func entryTombstoneConverges() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let deletedAt = Date(timeIntervalSince1970: 1_650_000_000)
        try await store.mergeCategory(Category(
            id: "cat-1", name: "Work", icon: "briefcase", createdAt: old, updatedAt: old
        ))
        try await store.mergeEntry(
            makeEntry(id: "e1", text: "Gym", categoryIDs: ["cat-1"], createdAt: old, updatedAt: old)
        )
        mock.deletionsResult = [Deletion(resource: "entry", recordID: "e1", deletedAt: deletedAt)]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(isIdle(controller.status))
        #expect(try await store.entry(id: "e1") == nil)
        #expect(try await store.outboxRows().isEmpty)
        #expect(try await store.lastSyncedAt(resource: "deletions") == deletedAt)
        // First sync: no cursor yet, so the fetch ran without `deleted_since`.
        #expect(mock.fetchedDeletionsSince.first! == nil)
    }

    @Test("category tombstone removes joins and the row while entries survive untagged")
    func categoryTombstoneConverges() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let deletedAt = Date(timeIntervalSince1970: 1_650_000_000)
        try await store.mergeCategory(Category(
            id: "cat-1", name: "Work", icon: "briefcase", createdAt: old, updatedAt: old
        ))
        try await store.createEntry(makeEntry(id: "e1", text: "Gym", categoryIDs: ["cat-1"]))
        mock.deletionsResult = [Deletion(resource: "category", recordID: "cat-1", deletedAt: deletedAt)]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(isIdle(controller.status))
        #expect(try await store.category(id: "cat-1") == nil)
        let stored = try await store.entry(id: "e1")
        #expect(stored?.categoryIDs.isEmpty == true)
        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("an unknown-resource tombstone is ignored but still advances the cursor")
    func unknownResourceTombstoneIsIgnored() async throws {
        let (store, mock, controller) = makeContext()
        let deletedAt = Date(timeIntervalSince1970: 1_650_000_000)
        mock.deletionsResult = [Deletion(resource: "activity", recordID: "a1", deletedAt: deletedAt)]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(isIdle(controller.status))
        #expect(try await store.outboxRows().isEmpty)
        #expect(try await store.lastSyncedAt(resource: "deletions") == deletedAt)
    }

    @Test("stale tombstone keeps a clean local row newer than the deletion (R1)")
    func staleTombstoneKeepsCleanNewerRow() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let deletedAt = Date(timeIntervalSince1970: 1_650_000_000)
        let recreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "Gym", createdAt: old, updatedAt: recreatedAt))
        // No pending create/update rows: a recreation via the pull-merge path
        // is clean, and its updated_at is newer than the stale tombstone.
        mock.deletionsResult = [Deletion(resource: "entry", recordID: "e1", deletedAt: deletedAt)]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(isIdle(controller.status))
        #expect(try await store.entry(id: "e1")?.activityText == "Gym")
        #expect(try await store.lastSyncedAt(resource: "deletions") == deletedAt)
        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("tombstones drop a stale pending update before the drain, so the 404-throwing update mock is never called")
    func tombstonesDropStalePendingUpdatePreDrain() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let deletedAt = Date(timeIntervalSince1970: 1_650_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "Gym", createdAt: old, updatedAt: old))
        _ = try await store.updateEntry(makeEntry(
            id: "e1", text: "Gym v2", createdAt: old,
            updatedAt: Date(timeIntervalSince1970: 1_620_000_000)
        ))
        mock.deletionsResult = [Deletion(resource: "entry", recordID: "e1", deletedAt: deletedAt)]
        mock.updateEntryHandler = { _ in
            throw APIError.server(code: "not_found", message: "gone", details: [:])
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // The tombstone step removed the row and its pending update row
        // before the drain ran — no update was ever pushed, and the cycle
        // stayed idle (a push would have thrown).
        #expect(mock.calls.allSatisfy { $0.method != "updateEntry" })
        #expect(isIdle(controller.status))
        #expect(try await store.entry(id: "e1") == nil)
        #expect(try await store.outboxRows().isEmpty)
        #expect(try await store.lastSyncedAt(resource: "deletions") == deletedAt)
    }

    @Test("empty deletions list keeps the cursor nil")
    func emptyDeletionsKeepCursor() async throws {
        let (store, mock, controller) = makeContext()
        mock.deletionsResult = []

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(isIdle(controller.status))
        #expect(try await store.lastSyncedAt(resource: "deletions") == nil)
        #expect(mock.calls.contains(Call("fetchDeletions", "deletion")))
    }

    @Test("tombstone for an unknown id is a no-op that still advances the cursor")
    func unknownIDTombstoneIsNoOp() async throws {
        let (store, mock, controller) = makeContext()
        let deletedAt = Date(timeIntervalSince1970: 1_650_000_000)
        mock.deletionsResult = [Deletion(resource: "entry", recordID: "unknown", deletedAt: deletedAt)]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(isIdle(controller.status))
        #expect(try await store.entry(id: "unknown") == nil)
        #expect(try await store.outboxRows().isEmpty)
        #expect(try await store.lastSyncedAt(resource: "deletions") == deletedAt)
    }

    @Test("deletions cursor advances to the max deleted_at across a batch")
    func deletionsCursorAdvancesToMax() async throws {
        let (store, mock, controller) = makeContext()
        let earlier = Date(timeIntervalSince1970: 1_640_000_000)
        let later = Date(timeIntervalSince1970: 1_650_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "Gym", createdAt: earlier, updatedAt: earlier))
        try await store.mergeEntry(makeEntry(id: "e2", text: "Run", createdAt: earlier, updatedAt: earlier))
        mock.deletionsResult = [
            Deletion(resource: "entry", recordID: "e1", deletedAt: earlier),
            Deletion(resource: "entry", recordID: "e2", deletedAt: later),
        ]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(isIdle(controller.status))
        #expect(try await store.entry(id: "e1") == nil)
        #expect(try await store.entry(id: "e2") == nil)
        #expect(try await store.lastSyncedAt(resource: "deletions") == later)
    }

    @Test("second sync sends the deletions cursor")
    func secondSyncSendsDeletionsCursor() async throws {
        let (store, mock, controller) = makeContext()
        let deletedAt = Date(timeIntervalSince1970: 1_650_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "Gym", createdAt: deletedAt, updatedAt: deletedAt))
        mock.deletionsResult = [Deletion(resource: "entry", recordID: "e1", deletedAt: deletedAt)]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        mock.clearLog()
        await controller.syncNow(userID: "u1")

        #expect(mock.fetchedDeletionsSince.first == deletedAt)
        #expect(try await store.lastSyncedAt(resource: "deletions") == deletedAt)
    }

    @Test("pending DELETE row survives tombstone application (converges via 404-as-success)")
    func tombstoneKeepsPendingDeleteRow() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let deletedAt = Date(timeIntervalSince1970: 1_650_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "Gym", createdAt: old, updatedAt: old))
        try await store.deleteEntry(id: "e1")
        mock.deletionsResult = [Deletion(resource: "entry", recordID: "e1", deletedAt: deletedAt)]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // The locally queued DELETE drained normally; the tombstone found
        // nothing to remove and dropped nothing but stale create/update rows.
        #expect(isIdle(controller.status))
        #expect(try await store.outboxRows().isEmpty)
        #expect(try await store.lastSyncedAt(resource: "deletions") == deletedAt)
    }

    // MARK: - Buffered deletions push before the drain (push-then-commit)

    @Test("buffered entry deletion pushes DELETE on the next cycle and clears the buffer")
    func bufferedEntryDeletionPushes() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "Gym", createdAt: old, updatedAt: old))
        let outcome = try await store.deleteEntryUndoable(id: "e1")
        guard case .deleted = outcome else {
            Issue.record("expected the entry to be buffered for undo")
            return
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(isIdle(controller.status))
        #expect(mock.calls.contains(Call("deleteEntry", "entry", "e1")))
        #expect(try await store.entry(id: "e1") == nil)
        #expect(try await store.bufferedDeletions().isEmpty)
        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("buffered category deletion pushes DELETE on the next cycle and clears the buffer")
    func bufferedCategoryDeletionPushes() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try await store.mergeCategory(Category(
            id: "cat-1", name: "Work", icon: "briefcase", createdAt: old, updatedAt: old
        ))
        _ = try await store.deleteCategoryUndoable(id: "cat-1")

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(isIdle(controller.status))
        #expect(mock.calls.contains(Call("deleteCategory", "category", "cat-1")))
        #expect(try await store.category(id: "cat-1") == nil)
        #expect(try await store.bufferedDeletions().isEmpty)
        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("404 on a buffered push is success: the buffer clears and the cycle stays idle")
    func bufferedPush404ClearsBuffer() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "Gym", createdAt: old, updatedAt: old))
        _ = try await store.deleteEntryUndoable(id: "e1")
        mock.deleteEntryHandler = { _ in
            throw APIError.server(code: "not_found", message: "gone", details: [:])
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(isIdle(controller.status))
        #expect(try await store.bufferedDeletions().isEmpty)
        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("failed buffered push keeps the row buffered and undoable, and fails the cycle loudly")
    func bufferedPushFailureKeepsRowUndoable() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "Gym", createdAt: old, updatedAt: old))
        _ = try await store.deleteEntryUndoable(id: "e1")
        mock.deleteEntryHandler = { _ in
            throw APIError.server(code: "internal", message: "boom", details: [:])
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // Loud failure, nothing committed — and the deletion is still
        // restorable afterwards (the in-flight flag was cleared on error).
        if case .error = controller.status {} else {
            Issue.record("expected the cycle to fail loudly")
        }
        #expect(try await store.bufferedDeletions().count == 1)
        let recent = try await store.undoBufferMostRecent()
        let restored = try await store.undoEntryDeletion(bufferID: recent!.id)
        #expect(restored?.id == "e1")
        #expect(try await store.entry(id: "e1")?.activityText == "Gym")
    }

    @Test("undo refused while a buffered push is in flight, allowed again after")
    func undoRefusedDuringBufferedPush() async throws {
        let (store, _, _) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "Gym", createdAt: old, updatedAt: old))
        _ = try await store.deleteEntryUndoable(id: "e1")
        let recent = try await store.undoBufferMostRecent()

        await store.setUndoPushInFlight(true)
        await #expect(throws: UndoError.pushInFlight) {
            try await store.undoEntryDeletion(bufferID: recent!.id)
        }
        await store.setUndoPushInFlight(false)
        let restored = try await store.undoEntryDeletion(bufferID: recent!.id)
        #expect(restored?.id == "e1")
    }

    @Test("buffered push runs before the drain: a stale queued update for the same id is dropped, never pushed")
    func bufferedPushRunsBeforeDrain() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "Gym", createdAt: old, updatedAt: old))
        // A stale queued update…
        _ = try await store.updateEntry(makeEntry(
            id: "e1", text: "Gym v2", createdAt: old,
            updatedAt: Date(timeIntervalSince1970: 1_620_000_000)
        ))
        // …then the user deletes the entry (buffered, no outbox row).
        _ = try await store.deleteEntryUndoable(id: "e1")
        mock.updateEntryHandler = { _ in
            throw APIError.server(code: "not_found", message: "gone", details: [:])
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(isIdle(controller.status))
        #expect(mock.calls.contains(Call("deleteEntry", "entry", "e1")))
        #expect(mock.calls.allSatisfy { $0.method != "updateEntry" })
        #expect(try await store.outboxRows().isEmpty)
        #expect(try await store.bufferedDeletions().isEmpty)
    }

    // MARK: - Push-404 resurrection (entries and categories only)

    @Test("stale entry update re-posts as create")
    func entryUpdateNotFoundRepostsAsCreate() async throws {
        let (store, mock, controller) = makeContext()
        let t0 = Date(timeIntervalSince1970: 1_600_000_000)
        let t1 = Date(timeIntervalSince1970: 1_650_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "Gym", createdAt: t0, updatedAt: t0))
        _ = try await store.updateEntry(makeEntry(id: "e1", text: "Gym", createdAt: t0, updatedAt: t1))
        mock.updateEntryHandler = { _ in
            throw APIError.server(code: "not_found", message: "gone", details: [:])
        }
        var createdIDs: [String] = []
        mock.createEntryHandler = { createdIDs.append($0.id) }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(createdIDs == ["e1"])
        #expect(try await store.entry(id: "e1") != nil)
        #expect(try await store.outboxRows().isEmpty)
        #expect(isIdle(controller.status))
    }

    @Test("stale category update re-posts the full local row as create")
    func categoryUpdateNotFoundRepostsAsCreate() async throws {
        let (store, mock, controller) = makeContext()
        let t0 = Date(timeIntervalSince1970: 1_600_000_000)
        let t1 = Date(timeIntervalSince1970: 1_650_000_000)
        try await store.mergeCategory(
            Category(id: "c1", name: "Sport", icon: "figure.run", createdAt: t0, updatedAt: t0)
        )
        _ = try await store.updateCategory(
            Category(id: "c1", name: "Sport", icon: "tag", createdAt: t0, updatedAt: t1)
        )
        mock.updateCategoryHandler = { _ in
            throw APIError.server(code: "not_found", message: "gone", details: [:])
        }
        var createdIDs: [String] = []
        mock.createCategoryHandler = { createdIDs.append($0.id) }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(createdIDs == ["c1"])
        #expect(try await store.category(id: "c1")?.icon == "tag")
        #expect(try await store.outboxRows().isEmpty)
        #expect(isIdle(controller.status))
    }

    @Test("an update row for a locally missing entry clears without pushing")
    func locallyMissingUpdateClears() async throws {
        let (store, mock, controller) = makeContext()
        let t0 = Date(timeIntervalSince1970: 1_600_000_000)
        let t1 = Date(timeIntervalSince1970: 1_650_000_000)
        // A create whose push will be superseded, plus a stacked update for
        // the same record that no longer exists locally.
        try await store.createEntry(makeEntry(id: "e1", text: "Gym", createdAt: t0, updatedAt: t0))
        _ = try await store.updateEntry(makeEntry(id: "e1", text: "Gym v2", createdAt: t0, updatedAt: t1))
        try await store.deleteEntry(id: "e1") // commit the delete: removes the local row
        // The tombstone drops the create row; the update row would 404 forever.
        mock.deletionsResult = [Deletion(resource: "entry", recordID: "e1", deletedAt: Date())]
        var updateCalls = 0
        mock.updateEntryHandler = { _ in
            updateCalls += 1
            throw APIError.server(code: "not_found", message: "gone", details: [:])
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(updateCalls == 0)
        #expect(try await store.entry(id: "e1") == nil)
        #expect(try await store.outboxRows().isEmpty)
        #expect(isIdle(controller.status))
    }

    @Test("pre-tombstone relay does not fail the cycle")
    func fetchDeletionsNotFoundSkipsTombstones() async throws {
        let (store, mock, controller) = makeContext()
        try await store.createEntry(makeEntry(id: "e1", text: "Gym"))
        mock.fetchDeletionsHandler = { _ in
            throw APIError.server(code: "not_found", message: "gone", details: [:])
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // Drain and pull ran normally around the skipped tombstone step.
        #expect(mock.calls.contains(Call("createEntry", "entry", "e1")))
        #expect(mock.calls.contains(Call("fetchEntries", "entry", nil)))
        #expect(try await store.outboxRows().isEmpty)
        #expect(try await store.lastSyncedAt(resource: "deletions") == nil)
        #expect(isIdle(controller.status))
    }

    @Test("failed cycle exposes its message through status")
    func failedCycleExposesMessage() async {
        let (store, mock, controller) = makeContext()
        try? await store.createCategory(Category(id: "c1", name: "Sport", icon: "figure.run"))
        mock.createCategoryHandler = { _ in
            throw APIError.server(code: "internal_error", message: "boom", details: [:])
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(controller.status == .error("server(internal_error): boom"))
    }

    @Test("not_found on delete is treated as success")
    func notFoundOnDeleteIsSuccess() async throws {
        let (store, mock, controller) = makeContext()
        try await store.deleteEntry(id: "e1")

        mock.deleteEntryHandler = { _ in
            throw APIError.server(code: "not_found", message: "gone", details: [:])
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(try await store.outboxRows().isEmpty)
        #expect(mock.calls.contains(Call("deleteEntry", "entry", "e1")))
        #expect(isIdle(controller.status))
    }

    @Test("offline activation errors without network calls")
    func offlineActivationErrorsWithoutNetworkCalls() async throws {
        let (_, mock, controller) = makeContext(connected: false)
        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(mock.calls.isEmpty)
        #expect(controller.status == .error("offline"))
    }

    @Test("deactivate stops sync and syncNow is a no-op")
    func deactivateStopsSync() async throws {
        let (_, mock, controller) = makeContext()
        controller.activate(userID: "u1")
        await waitForCycle(controller)

        controller.deactivate()
        #expect(controller.status == .inactive)

        mock.clearLog()
        await controller.syncNow(userID: "u1")
        #expect(mock.calls.isEmpty)
    }

    @Test("trigger is single-flight")
    func triggerIsSingleFlight() async throws {
        let (_, mock, controller) = makeContext()
        controller.activate(userID: "u1")
        await waitForCycle(controller)

        mock.clearLog()
        controller.trigger(userID: "u1")
        controller.trigger(userID: "u1")
        await waitUntil { mock.calls.count == 3 }

        let fetches = mock.calls.filter { $0.method == "fetchEntries" }
        #expect(fetches.count == 1)
    }

    // MARK: - Join instead of fork (history-pull-to-sync)

    @Test("concurrent syncNow calls join a single cycle")
    func syncNowJoinsInFlightCycle() async throws {
        let (store, mock, controller) = makeContext()
        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // A slow push keeps the first cycle in flight while the second
        // syncNow arrives (pull joining a Profile-started cycle, or two
        // pulls racing).
        try await store.createEntry(makeEntry(id: "e1", text: "Gym"))
        mock.createEntryHandler = { _ in
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        mock.clearLog()

        let first = Task { await controller.syncNow(userID: "u1") }
        await waitUntil { controller.status == .syncing }
        await controller.syncNow(userID: "u1")
        await first.value
        await waitForCycle(controller)

        let pushes = mock.calls.filter { $0.method == "createEntry" }
        #expect(pushes.count == 1)
        #expect(isIdle(controller.status))
        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("syncNow joins a trigger-started cycle")
    func syncNowJoinsTriggerCycle() async throws {
        let (store, mock, controller) = makeContext()
        controller.activate(userID: "u1")
        await waitForCycle(controller)

        try await store.createEntry(makeEntry(id: "e1", text: "Gym"))
        mock.createEntryHandler = { _ in
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        mock.clearLog()

        controller.trigger(userID: "u1")
        await waitUntil { controller.status == .syncing }
        await controller.syncNow(userID: "u1")
        await waitForCycle(controller)

        let pushes = mock.calls.filter { $0.method == "createEntry" }
        #expect(pushes.count == 1)
        #expect(isIdle(controller.status))
    }

    @Test("trigger during a syncNow cycle does not fork")
    func triggerDuringSyncNowDoesNotFork() async throws {
        let (store, mock, controller) = makeContext()
        controller.activate(userID: "u1")
        await waitForCycle(controller)

        try await store.createEntry(makeEntry(id: "e1", text: "Gym"))
        mock.createEntryHandler = { _ in
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        mock.clearLog()

        let syncing = Task { await controller.syncNow(userID: "u1") }
        await waitUntil { controller.status == .syncing }
        controller.trigger(userID: "u1")
        controller.trigger(userID: "u1")
        await syncing.value
        await waitForCycle(controller)

        let pushes = mock.calls.filter { $0.method == "createEntry" }
        #expect(pushes.count == 1)
        #expect(isIdle(controller.status))
    }

    @Test("sequential syncNow calls run separate cycles")
    func sequentialSyncNowRunsSeparateCycles() async throws {
        let (_, mock, controller) = makeContext()
        controller.activate(userID: "u1")
        await waitForCycle(controller)

        mock.clearLog()
        await controller.syncNow(userID: "u1")
        await controller.syncNow(userID: "u1")

        // The boundary "race" (cycle already over at check time) is a fresh
        // cheap cycle, not a join: one fetchEntries per call.
        let fetches = mock.calls.filter { $0.method == "fetchEntries" }
        #expect(fetches.count == 2)
        #expect(isIdle(controller.status))
    }

    // MARK: - Category-before-entry drain (fix-entry-category-sync)

    @Test("drain pushes categories before entries even when the entry was queued first")
    func drainPushesCategoriesBeforeEntries() async throws {
        let (store, mock, controller) = makeContext()
        // Entry queued first (no categories so it can exist before c1), then
        // the category. Global created_at order would push the entry first;
        // dependency ordering must push the category first.
        try await store.createEntry(makeEntry(id: "e1", text: "Gym"))
        try await store.createCategory(Category(id: "c1", name: "Sport", icon: "figure.run"))

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        let categoryIndex = mock.calls.firstIndex { $0.method == "createCategory" }
        let entryIndex = mock.calls.firstIndex { $0.method == "createEntry" }
        #expect(categoryIndex != nil)
        #expect(entryIndex != nil)
        if let categoryIndex, let entryIndex {
            #expect(categoryIndex < entryIndex)
        }
        #expect(isIdle(controller.status))
        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("entry push creates a relay-unknown category first and pushes the full set")
    func entryPushValidationHealsByPruning() async throws {
        let (store, mock, controller) = makeContext()
        mock.categoriesResult = [Category(id: "c-keep", name: "Sport", icon: "figure.run")]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // Clean local rows (no outbox): the relay knows c-keep but not c-new,
        // so only the drain's ensure step can create c-new before pushing.
        try await store.mergeCategory(Category(id: "c-keep", name: "Sport", icon: "figure.run"))
        try await store.mergeCategory(Category(id: "c-new", name: "Music", icon: "music.note"))
        try await store.createEntry(makeEntry(id: "e1", text: "Gym", categoryIDs: ["c-keep", "c-new"]))
        var pushed: [TimeEntry] = []
        var createdCategoryIDs: [String] = []
        mock.createCategoryHandler = { category in
            createdCategoryIDs.append(category.id)
            // Simulate the relay now owning the created category.
            if !mock.categoriesResult.contains(where: { $0.id == category.id }) {
                mock.categoriesResult.append(category)
            }
        }
        mock.createEntryHandler = { entry in
            pushed.append(entry)
            let known = Set(mock.categoriesResult.map(\.id))
            if !Set(entry.categoryIDs).isSubset(of: known) {
                throw APIError.server(
                    code: "validation_error", message: "Validation failed",
                    details: ["category_ids": "One or more categories do not exist"]
                )
            }
        }

        await controller.syncNow(userID: "u1")

        #expect(createdCategoryIDs == ["c-new"])
        #expect(pushed.count == 1)
        #expect(pushed.first?.categoryIDs == ["c-keep", "c-new"])
        #expect(try await store.entry(id: "e1")?.categoryIDs == ["c-keep", "c-new"])
        #expect(try await store.outboxRows().isEmpty)
        #expect(isIdle(controller.status))
    }

    @Test("entry push with a row-less dangling category id still prunes as a last resort")
    func entryPushValidationHealsDanglingID() async throws {
        let (store, mock, controller) = makeContext()
        try await store.mergeCategory(Category(id: "c-keep", name: "Sport", icon: "figure.run"))
        try await store.createEntry(makeEntry(id: "e1", text: "Gym", categoryIDs: ["c-keep"]))
        // Rewrite the queued payload to reference a dangling id with no local
        // row: ensure must skip it, the push 422s, and the last-resort heal
        // prunes it.
        let dangling = makeEntry(id: "e1", text: "Gym", categoryIDs: ["c-keep", "c-ghost"])
        try await store.rewriteOutboxPayload(resource: "entry", recordID: "e1", payload: dangling)
        mock.categoriesResult = [Category(id: "c-keep", name: "Sport", icon: "figure.run")]
        var pushed: [TimeEntry] = []
        mock.createEntryHandler = { entry in
            pushed.append(entry)
            if entry.categoryIDs.contains("c-ghost") {
                throw APIError.server(
                    code: "validation_error", message: "Validation failed",
                    details: ["category_ids": "One or more categories do not exist"]
                )
            }
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(pushed.count == 2)
        #expect(pushed.last?.categoryIDs == ["c-keep"])
        #expect(mock.calls.allSatisfy { $0.method != "createCategory" })
        #expect(try await store.outboxRows().isEmpty)
        #expect(isIdle(controller.status))
    }

    @Test("entry push 422 with nothing to prune still fails loudly")
    func entryPushValidationWithoutPruneFails() async throws {
        let (store, mock, controller) = makeContext()
        try await store.mergeCategory(Category(id: "c1", name: "Sport", icon: "figure.run"))
        try await store.createEntry(makeEntry(id: "e1", text: "Gym", categoryIDs: ["c1"]))
        mock.categoriesResult = [Category(id: "c1", name: "Sport", icon: "figure.run")]
        mock.createEntryHandler = { _ in
            throw APIError.server(
                code: "validation_error", message: "Validation failed",
                details: ["category_ids": "One or more categories do not exist"]
            )
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        guard case .error = controller.status else {
            Issue.record("expected error status, got \(controller.status)")
            return
        }
        #expect(!(try await store.outboxRows()).isEmpty)
    }

    @Test("pull remaps a relay-known id to a newer same-name local rival and adopts snapshot-only ids")
    func pullAdoptsOrRemapsRelayKnownCategories() async throws {
        let (store, mock, controller) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let new = Date(timeIntervalSince1970: 1_700_000_000)
        // The local "Sport" rival is newer than the relay row, so the pull
        // keeps it; it stays dirty (pending create) so snapshot
        // reconciliation preserves it.
        try await store.createCategory(Category(
            id: "local-sport", name: "Sport", icon: "figure.run",
            createdAt: new, updatedAt: new
        ))
        mock.categoriesResult = [
            Category(
                id: "server-sport", name: "Sport", icon: "figure.run",
                createdAt: old, updatedAt: old
            ),
            Category(
                id: "server-only", name: "Music", icon: "music.note",
                createdAt: old, updatedAt: old
            ),
        ]
        mock.entriesResult = [
            makeEntry(
                id: "e1", text: "Gym", categoryIDs: ["server-sport", "server-only"],
                createdAt: old, updatedAt: old
            )
        ]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // server-sport remapped to the local rival, server-only adopted: the
        // entry keeps a category for both, with no outbox row enqueued for
        // the remap itself.
        #expect(try await store.entry(id: "e1")?.categoryIDs == ["local-sport", "server-only"])
        #expect(try await store.category(id: "local-sport")?.name == "Sport")
        #expect(try await store.category(id: "server-only")?.name == "Music")
        #expect(try await store.category(id: "server-sport") == nil)
        #expect(try await store.outboxRows().isEmpty)
        #expect(isIdle(controller.status))
    }

    @Test("a tie pull with a local category superset enqueues a healing update that drains with the full set")
    func tiePullHealsCategoryFork() async throws {
        let (store, mock, controller) = makeContext()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.mergeCategory(Category(
            id: "c1", name: "Sport", icon: "figure.run", createdAt: stamp, updatedAt: stamp
        ))
        try await store.mergeCategory(Category(
            id: "c2", name: "Music", icon: "music.note", createdAt: stamp, updatedAt: stamp
        ))
        try await store.mergeEntry(makeEntry(
            id: "e1", text: "Gym", categoryIDs: ["c1", "c2"], createdAt: stamp, updatedAt: stamp
        ))
        // The relay silently pruned c2 while storing the client timestamp
        // verbatim: the tie keeps local and must heal.
        mock.categoriesResult = [
            Category(
                id: "c1", name: "Sport", icon: "figure.run", createdAt: stamp, updatedAt: stamp
            ),
            Category(
                id: "c2", name: "Music", icon: "music.note", createdAt: stamp, updatedAt: stamp
            ),
        ]
        mock.entriesResult = [
            makeEntry(id: "e1", text: "Gym", categoryIDs: ["c1"], createdAt: stamp, updatedAt: stamp)
        ]
        var updated: [TimeEntry] = []
        mock.updateEntryHandler = { updated.append($0) }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(updated.count == 1)
        #expect(updated.first?.categoryIDs == ["c1", "c2"])
        #expect(updated.first.map { $0.updatedAt > stamp } == true)
        #expect(try await store.entry(id: "e1")?.categoryIDs == ["c1", "c2"])
        #expect(try await store.outboxRows().isEmpty)
        #expect(isIdle(controller.status))
    }

    @Test("a tie pull with a server category superset adopts the joins locally without enqueueing")
    func tiePullAdoptsServerCategorySuperset() async throws {
        let (store, mock, controller) = makeContext()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.mergeCategory(Category(
            id: "c1", name: "Sport", icon: "figure.run", createdAt: stamp, updatedAt: stamp
        ))
        try await store.mergeCategory(Category(
            id: "c2", name: "Music", icon: "music.note", createdAt: stamp, updatedAt: stamp
        ))
        // A pre-fix pull wiped the join; the entry's ms timestamp ties with
        // the relay's sub-ms one forever (whole-row LWW never adopts).
        try await store.mergeEntry(makeEntry(
            id: "e1", text: "Gym", categoryIDs: [], createdAt: stamp, updatedAt: stamp
        ))
        mock.categoriesResult = [
            Category(
                id: "c1", name: "Sport", icon: "figure.run", createdAt: stamp, updatedAt: stamp
            ),
            Category(
                id: "c2", name: "Music", icon: "music.note", createdAt: stamp, updatedAt: stamp
            ),
        ]
        mock.entriesResult = [
            makeEntry(id: "e1", text: "Gym", categoryIDs: ["c1", "c2"], createdAt: stamp, updatedAt: stamp)
        ]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // Local-only adoption: joins restored, timestamp unchanged, no push.
        let entry = try await store.entry(id: "e1")
        #expect(entry?.categoryIDs == ["c1", "c2"])
        #expect(entry?.updatedAt == stamp)
        #expect(try await store.outboxRows().isEmpty)
        #expect(isIdle(controller.status))
    }

    @Test("a server-older pull keeps local joins even when the server set supersets")
    func serverOlderPullDoesNotAdoptServerSuperset() async throws {
        let (store, mock, controller) = makeContext()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let older = stamp.addingTimeInterval(-10)
        try await store.mergeCategory(Category(
            id: "c1", name: "Sport", icon: "figure.run", createdAt: older, updatedAt: older
        ))
        try await store.mergeEntry(makeEntry(
            id: "e1", text: "Gym", categoryIDs: [], createdAt: older, updatedAt: stamp
        ))
        mock.categoriesResult = [
            Category(id: "c1", name: "Sport", icon: "figure.run", createdAt: older, updatedAt: older)
        ]
        // A legitimate relay prune on another device: older server version
        // with the pruned (here empty→untagged) set. Server set is a strict
        // superset of the (empty) local set but the tie is absent: keep local.
        mock.entriesResult = [
            makeEntry(id: "e1", text: "Gym", categoryIDs: [], createdAt: older, updatedAt: older)
        ]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        let entry = try await store.entry(id: "e1")
        #expect(entry?.categoryIDs.isEmpty == true)
        #expect(entry?.updatedAt == stamp)
        #expect(try await store.outboxRows().isEmpty)
        #expect(isIdle(controller.status))
    }

    // MARK: - Same-account guard (account-bound-local-data 4.1)

    @Test("activate A then switch the session to B: no cycle runs, outbox stays in A's file")
    func accountMismatchRefusesCycle() async throws {
        let (store, mock, controller) = makeContext()
        // A's outbox holds a pending create row.
        try await store.createEntry(makeEntry(id: "e1", text: "A's entry"))
        controller.activate(userID: "u1")
        await waitForCycle(controller)
        // Steady state drained; queue a fresh row, then swap the session.
        try await store.createEntry(makeEntry(id: "e2", text: "A's queued"))
        mock.clearLog()

        // Account B becomes the authenticated session; the controller is
        // still bound to A. Every trigger is refused — A's rows are never
        // pushed under B's token.
        let swapped = SyncController(
            store: store, remote: mock, connectivity: MockConnectivity(connected: true)
        ) { "u2" }
        swapped.activate(userID: "u1")
        await waitForCycle(swapped)
        await swapped.syncNow(userID: "u2")
        swapped.trigger(userID: "u2")
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(mock.calls.isEmpty)
        let rows = try await store.outboxRows()
        #expect(rows.contains { $0.recordID == "e2" && $0.op == "create" })
        guard case .inactive = swapped.status else {
            Issue.record("expected inactive status, got \(swapped.status)")
            return
        }
    }

    @Test("a cycle in flight aborts mid-way when the account changes, without draining further rows")
    func midCycleAccountChangeAborts() async throws {
        let (store, mock, _) = makeContext()
        // Two queued rows; the first push holds the cycle in flight while
        // the session flips to another account.
        try await store.createEntry(makeEntry(id: "e1", text: "First"))
        try await store.createEntry(makeEntry(id: "e2", text: "Second"))
        let session = SessionUserIDHolder("u1")
        let held = HeldCycleStart()
        mock.createEntryHandler = { _ in
            if !held.started {
                held.started = true
                // Session changes to B while A's cycle is draining.
                session.value = "u2"
            }
        }
        let controller = SyncController(
            store: store, remote: mock, connectivity: MockConnectivity(connected: true)
        ) { session.value }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // The abort left the remaining row(s) in A's file: e2's create was
        // never pushed under B's session. Same-tick rows drain in insertion
        // order (created_at, rowid), so e1 was deterministically first.
        let rows = try await store.outboxRows()
        #expect(rows.contains { $0.recordID == "e2" && $0.op == "create" })
        #expect(mock.calls.contains { $0.method == "createEntry" && $0.id == "e1" })
        #expect(!mock.calls.contains { $0.method == "createEntry" && $0.id == "e2" })
        // The abort surfaces no error and deactivates: the shell's next
        // activate(sessionID) rebinds (activate only rebinds from inactive).
        if case .inactive = controller.status {} else {
            Issue.record("expected inactive after abort, got \(controller.status)")
        }
    }

    @Test("cancel-then-fail stays inactive so the next activate rebinds and drains")
    func cancelThenFailStaysInactive() async throws {
        let (store, mock, controller) = makeContext()
        try await store.createEntry(makeEntry(id: "e1", text: "Gym"))
        let gate = Gate()
        let firstPush = HeldCycleStart()
        mock.createEntryHandler = { _ in
            if !firstPush.started {
                firstPush.started = true
                await gate.wait()
                throw APIError.server(code: "internal", message: "boom", details: [:])
            }
        }

        controller.activate(userID: "u1")
        await waitUntil { mock.calls.contains { $0.method == "createEntry" && $0.id == "e1" } }
        // Cancel while the push is in flight (deactivate closes the binding);
        // the late transport failure must not overwrite .inactive with .error.
        controller.deactivate()
        #expect(controller.status == .inactive)
        gate.open()
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(controller.status == .inactive)
        // The next activate rebinds (it early-returns unless .inactive) and
        // drains the still-queued row.
        mock.createEntryHandler = nil
        mock.clearLog()
        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(isIdle(controller.status))
        #expect(mock.calls.contains { $0.method == "createEntry" && $0.id == "e1" })
        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("sign-out waits for a held cycle before close: no .error, next sign-in syncs")
    func signOutWaitsForHeldCycle() async throws {
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: temporaryStoreURL())
        let mock = MockCatalogRepository()
        let session = SessionUserIDHolder("u1")
        let controller = SyncController(
            store: store, remote: mock, connectivity: MockConnectivity(connected: true)
        ) { session.value }
        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // A steady-state cycle (drain before pull) held at its first push.
        try await store.createEntry(makeEntry(id: "e1", text: "First"))
        try await store.createEntry(makeEntry(id: "e2", text: "Second"))
        let gate = Gate()
        let firstPush = HeldCycleStart()
        mock.createEntryHandler = { _ in
            if !firstPush.started {
                firstPush.started = true
                await gate.wait()
            }
        }
        controller.trigger(userID: "u1")
        await waitUntil { mock.calls.contains { $0.method == "createEntry" && $0.id == "e1" } }
        // Sign-out mid-cycle: the session clears and sync deactivates while
        // the push is held. The dead-wait bug surfaced here — deactivate()
        // nils the handle, so a pre-close wait observed "not live" at once.
        session.value = nil
        controller.deactivate()
        #expect(controller.isCycleLive)
        gate.open()
        await waitUntil { !controller.isCycleLive }
        // The released cycle aborts at e2's per-row guard (never pushed under
        // the cleared session) and stays .inactive — never .error — so the
        // close is safe and the next sign-in rebinds.
        #expect(controller.status == .inactive)
        let rows = try await store.outboxRows()
        #expect(!rows.contains { $0.recordID == "e1" })
        #expect(rows.contains { $0.recordID == "e2" && $0.op == "create" })
        session.value = "u1"
        controller.activate(userID: "u1")
        await waitUntil { !controller.isCycleLive }
        #expect(isIdle(controller.status))
        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("mid-stage swap aborts buffered deletes with no cross-account write")
    func midStageSwapAbortsBufferedDeletes() async throws {
        let (store, mock, _) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "A", createdAt: old, updatedAt: old))
        try await store.mergeEntry(makeEntry(id: "e2", text: "B", createdAt: old, updatedAt: old))
        _ = try await store.deleteEntryUndoable(id: "e1")
        _ = try await store.deleteEntryUndoable(id: "e2")
        let session = SessionUserIDHolder("u1")
        let controller = SyncController(
            store: store, remote: mock, connectivity: MockConnectivity(connected: true)
        ) { session.value }
        let swapped = HeldCycleStart()
        mock.deleteEntryHandler = { _ in
            if !swapped.started {
                swapped.started = true
                // Swap to B while A's buffered push is in flight: at most the
                // one in-flight DELETE goes out.
                session.value = "u2"
            }
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        let deletes = mock.calls.filter { $0.method == "deleteEntry" }
        #expect(deletes.count == 1)
        // The uncommitted buffer rows stay for the owning account — nothing
        // was committed under B's session.
        #expect(!(try await store.bufferedDeletions()).isEmpty)
        if case .inactive = controller.status {} else {
            Issue.record("expected inactive after abort, got \(controller.status)")
        }
    }

    @Test("mid-stage swap aborts tombstone application with no cross-account write")
    func midStageSwapAbortsTombstones() async throws {
        let (store, mock, _) = makeContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try await store.mergeEntry(makeEntry(id: "e1", text: "Keep", createdAt: old, updatedAt: old))
        try await store.mergeEntry(makeEntry(id: "e2", text: "Keep", createdAt: old, updatedAt: old))
        let deletedAt = Date(timeIntervalSince1970: 1_650_000_000)
        let session = SessionUserIDHolder("u1")
        let controller = SyncController(
            store: store, remote: mock, connectivity: MockConnectivity(connected: true)
        ) { session.value }
        mock.fetchDeletionsHandler = { _ in
            // Swap to B during the tombstone fetch: the fetch ran under A's
            // session, so none of it may apply into the now-foreign file.
            session.value = "u2"
            return [
                Deletion(resource: "entry", recordID: "e1", deletedAt: deletedAt),
                Deletion(resource: "entry", recordID: "e2", deletedAt: deletedAt),
            ]
        }

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(try await store.entry(id: "e1") != nil)
        #expect(try await store.entry(id: "e2") != nil)
        #expect(try await store.lastSyncedAt(resource: "deletions") == nil)
        if case .inactive = controller.status {} else {
            Issue.record("expected inactive after abort, got \(controller.status)")
        }
    }

    @Test("mid-stage swap aborts pull merges with no cross-account write")
    func midStageSwapAbortsPullMerges() async throws {
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: temporaryStoreURL())
        let mock = MockCatalogRepository()
        let session = SessionUserIDHolder("u1")
        let remote = SwapOnEntriesFetchRemote(inner: mock, session: session)
        let controller = SyncController(
            store: store, remote: remote, connectivity: MockConnectivity(connected: true)
        ) { session.value }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        mock.entriesResult = [
            makeEntry(id: "srv-1", text: "Server 1", createdAt: stamp, updatedAt: stamp),
            makeEntry(id: "srv-2", text: "Server 2", createdAt: stamp, updatedAt: stamp),
        ]

        controller.activate(userID: "u1")
        await waitForCycle(controller)

        // The entries fetch ran under A's session but the session swapped
        // mid-pull: none of it merged into the now-foreign file, and the
        // cursor never advanced.
        #expect(try await store.entry(id: "srv-1") == nil)
        #expect(try await store.entry(id: "srv-2") == nil)
        #expect(try await store.lastSyncedAt(resource: "entry") == nil)
        if case .inactive = controller.status {} else {
            Issue.record("expected inactive after abort, got \(controller.status)")
        }
    }

    @Test("re-login of the same account resumes the dormant drain (outbox + cursors ride the per-user file)")
    func reloginResumesDormantDrain() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let url = base.appendingPathComponent(LocalStore.databaseFileName(userID: "u1"))

        // Signed in as u1: queue a create, advance the entry cursor, sign out.
        // swiftlint:disable:next force_try
        let signedIn = try! LocalStore(url: url, userID: "u1")
        try await signedIn.createEntry(makeEntry(id: "e1", text: "Offline draft"))
        let cursor = Date(timeIntervalSince1970: 1_700_000_000)
        try await signedIn.setLastSyncedAt(resource: "entry", date: cursor)
        await signedIn.closeAccount()

        // Re-login reopens the same file: the first cycle re-baselines the
        // stored (pre-pagination) cursor — a full pull fetched with nil —
        // while the dormant outbox still drains; the next cycle resumes
        // normal deltas from the healed cursor.
        // swiftlint:disable:next force_try
        let reopened = try! LocalStore(url: url, userID: "u1")
        let mock = MockCatalogRepository()
        mock.entriesResult = [makeEntry(id: "srv-1", text: "Server", updatedAt: cursor.addingTimeInterval(60))]
        let controller = SyncController(
            store: reopened, remote: mock, connectivity: MockConnectivity(connected: true)
        ) { "u1" }
        controller.activate(userID: "u1")
        await waitForCycle(controller)

        #expect(mock.calls.contains(Call("createEntry", "entry", "e1")))
        #expect(try await reopened.outboxRows().isEmpty)
        let firstFilter = try #require(mock.fetchedModifiedSince.first)
        #expect(firstFilter == nil)
        #expect(try await reopened.lastSyncedAt(resource: "entry") == cursor.addingTimeInterval(60))
        #expect(isIdle(controller.status))

        mock.clearLog()
        await controller.syncNow(userID: "u1")

        #expect(mock.fetchedModifiedSince.first == cursor.addingTimeInterval(60))
        #expect(isIdle(controller.status))
    }

    // MARK: - Cycle generation (deactivate → rapid re-activate race)

    /// Awaitable one-shot gate for holding a cycle's push in flight while
    /// the test re-activates the controller (same sendability shape as
    /// `SessionUserIDHolder`).
    private final class Gate: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// Mutable push-call counter (all access is main-actor serialized).
    private final class PushCounter: @unchecked Sendable {
        var value = 0
    }

    @Test("sign-out then rapid sign-in of the SAME account leaves the new cycle's handle live and draining")
    func rapidReactivationSameAccountKeepsNewCycle() async throws {
        let (store, mock, controller) = makeContext()
        // Two queued rows: the predecessor holds at e1's push, the successor
        // (started by the in-handler deactivate → activate) holds at its own
        // e1 push. The predecessor is released FIRST, so its finishing defer
        // lands while the successor cycle is provably still in flight.
        try await store.createEntry(makeEntry(id: "e1", text: "First"))
        try await store.createEntry(makeEntry(id: "e2", text: "Second"))
        let gate1 = Gate()
        let gate2 = Gate()
        let counter = PushCounter()
        mock.createEntryHandler = { _ in
            counter.value += 1
            if counter.value == 1 {
                // Sign-out → rapid sign-in of the SAME account while the
                // predecessor cycle is in flight at its push.
                controller.deactivate()
                controller.activate(userID: "u1")
                await gate1.wait()
            } else if counter.value == 2 {
                await gate2.wait()
            }
        }

        controller.activate(userID: "u1")
        await waitUntil { mock.calls.contains { $0.method == "createEntry" && $0.id == "e1" } }
        // The successor cycle started and holds at its own e1 push.
        await waitUntil { mock.calls.filter { $0.method == "createEntry" }.count == 2 }
        #expect(controller.isCycleLive)

        // Release the cancelled predecessor: it finishes its tail. Its defer
        // must NOT wipe the successor's cycleTask.
        gate1.open()
        await waitUntil { mock.calls.filter { $0.method == "createEntry" }.count == 3 }
        #expect(controller.isCycleLive)

        // Release the successor: it drains to idle and owns the cleanup.
        gate2.open()
        await waitUntil { !controller.isCycleLive }
        #expect(isIdle(controller.status))
        #expect(try await store.outboxRows().isEmpty)
        // Single-flight intact: the controller is immediately usable again.
        try await store.createEntry(makeEntry(id: "e3", text: "Third"))
        await controller.syncNow(userID: "u1")
        #expect(isIdle(controller.status))
        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("sign-out then rapid sign-in of a DIFFERENT account leaves the new cycle live and unstranded")
    func rapidReactivationDifferentAccountKeepsNewCycle() async throws {
        let (store, mock, _) = makeContext()
        let session = SessionUserIDHolder("u1")
        let controller = SyncController(
            store: store, remote: mock, connectivity: MockConnectivity(connected: true)
        ) { session.value }
        try await store.createEntry(makeEntry(id: "e1", text: "A's entry"))
        let gate1 = Gate()
        let gate2 = Gate()
        let counter = PushCounter()
        mock.createEntryHandler = { _ in
            counter.value += 1
            if counter.value == 1 {
                // The session flips to B; sign-out → rapid sign-in as B
                // while A's cycle is in flight at its push.
                session.value = "u2"
                controller.deactivate()
                controller.activate(userID: "u2")
                await gate1.wait()
            } else if counter.value == 2 {
                await gate2.wait()
            }
        }

        controller.activate(userID: "u1")
        await waitUntil { mock.calls.contains { $0.method == "createEntry" && $0.id == "e1" } }
        await waitUntil { mock.calls.filter { $0.method == "createEntry" }.count == 2 }
        #expect(controller.isCycleLive)

        gate1.open()
        // The predecessor's tail ran (e2's per-row guard refused it under
        // u2's session → abort) while the successor is provably still in
        // flight.
        try await Task.sleep(nanoseconds: 200_000_000)
        // The cancelled predecessor's defer did not wipe the new (u2)
        // cycle's handle while it was still in flight.
        #expect(controller.isCycleLive)

        gate2.open()
        await waitUntil { !controller.isCycleLive }
        #expect(isIdle(controller.status))
        #expect(try await store.outboxRows().isEmpty)
        // The guard semantics are unchanged: no push ran without a matching
        // bound account (both pushes ran for their own bound session user).
        #expect(mock.calls.contains { $0.method == "createEntry" && $0.id == "e1" })
    }

    @Test("sign-out then rapid sign-in of the SAME account leaves one live cycle that drains")
    func rapidReactivationSameAccountDrainsOnce() async throws {
        let (store, mock, controller) = makeContext()
        try await store.createEntry(makeEntry(id: "e1", text: "First"))
        try await store.createEntry(makeEntry(id: "e2", text: "Second"))
        let firstStarted = HeldCycleStart()
        mock.createEntryHandler = { _ in
            if !firstStarted.started {
                firstStarted.started = true
                // Sign-out → rapid sign-in of the SAME account while the
                // predecessor cycle is in flight at its push. deactivate()
                // already cancelled this task, so the sleep below aborts it
                // with CancellationError right after the re-activation.
                controller.deactivate()
                controller.activate(userID: "u1")
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        controller.activate(userID: "u1")
        // The successor cycle owns the handle and drains the whole outbox to
        // idle. The old bug: the cancelled predecessor's unconditional defer
        // wiped the NEW cycle's cycleTask/activeCycleUserID, so the successor
        // aborted at the per-row guard and stranded .inactive with rows
        // queued.
        await waitUntil {
            !controller.isCycleLive
        }
        #expect(!controller.isCycleLive)
        #expect(isIdle(controller.status))
        #expect(try await store.outboxRows().isEmpty)
        // Single-flight intact: the controller is immediately usable again.
        try await store.createEntry(makeEntry(id: "e3", text: "Third"))
        await controller.syncNow(userID: "u1")
        #expect(isIdle(controller.status))
        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("sign-out then rapid sign-in of a DIFFERENT account leaves the new cycle live and unstranded")
    func rapidReactivationDifferentAccountDrains() async throws {
        let (store, mock, _) = makeContext()
        try await store.createEntry(makeEntry(id: "e1", text: "A's entry"))
        let session = SessionUserIDHolder("u1")
        let controller = SyncController(
            store: store, remote: mock, connectivity: MockConnectivity(connected: true)
        ) { session.value }
        let firstStarted = HeldCycleStart()
        mock.createEntryHandler = { _ in
            if !firstStarted.started {
                firstStarted.started = true
                // The session flips to B; sign-out → rapid sign-in as B
                // while A's cycle is in flight at its push.
                session.value = "u2"
                controller.deactivate()
                controller.activate(userID: "u2")
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        controller.activate(userID: "u1")
        await waitUntil {
            !controller.isCycleLive
        }

        // The successor (u2) cycle owns the handle, drains, and lands idle —
        // never stranded .inactive by the cancelled predecessor's defer.
        #expect(!controller.isCycleLive)
        #expect(isIdle(controller.status))
        #expect(try await store.outboxRows().isEmpty)
        // A's pushed row converged (it was pushed by whichever cycle owned
        // the handle when the drain reached it); the guard semantics are
        // unchanged — no push ever ran without a matching session user.
        #expect(mock.calls.contains { $0.method == "createEntry" && $0.id == "e1" })
    }

    /// Mutable session-user holder for the guard tests (the sync controller's
    /// `sessionUserIDProvider` reads it live to simulate an account swap).
    /// `@unchecked Sendable`: the only concurrent access is the cycle task's
    /// guard read versus the test's write, both serialized on the main actor.
    private final class SessionUserIDHolder: @unchecked Sendable {
        var value: String?
        init(_ value: String?) { self.value = value }
    }

    /// One-shot flag holder for handler closures (same sendability shape as
    /// `SessionUserIDHolder`).
    private final class HeldCycleStart: @unchecked Sendable {
        var started = false
    }

    /// Forwarding `CatalogSending` that flips the session to another account
    /// when the pull's entries fetch returns — simulating an account swap
    /// during pull's in-flight fetch. All other calls delegate to the inner
    /// mock untouched.
    private final class SwapOnEntriesFetchRemote: CatalogSending, @unchecked Sendable {
        let inner: MockCatalogRepository
        let session: SessionUserIDHolder
        init(inner: MockCatalogRepository, session: SessionUserIDHolder) {
            self.inner = inner
            self.session = session
        }
        func fetchCategories() async throws -> [Category] {
            try await inner.fetchCategories()
        }
        func fetchEntries(modifiedSince: Date?) async throws -> [TimeEntry] {
            let result = try await inner.fetchEntries(modifiedSince: modifiedSince)
            session.value = "u2"
            return result
        }
        func fetchEntryPage(modifiedSince: Date?, cursor: String?) async throws -> EntryPage {
            let result = try await inner.fetchEntryPage(modifiedSince: modifiedSince, cursor: cursor)
            session.value = "u2"
            return result
        }
        func fetchDeletions(since: Date?) async throws -> [Deletion] {
            try await inner.fetchDeletions(since: since)
        }
        func fetchCategory(id: String) async throws -> Category {
            try await inner.fetchCategory(id: id)
        }
        func fetchEntry(id: String) async throws -> TimeEntry {
            try await inner.fetchEntry(id: id)
        }
        func createCategory(_ category: Category) async throws {
            try await inner.createCategory(category)
        }
        func updateCategory(_ category: Category) async throws {
            try await inner.updateCategory(category)
        }
        func deleteCategory(id: String) async throws {
            try await inner.deleteCategory(id: id)
        }
        func createEntry(_ entry: TimeEntry) async throws {
            try await inner.createEntry(entry)
        }
        func updateEntry(_ entry: TimeEntry) async throws {
            try await inner.updateEntry(entry)
        }
        func deleteEntry(id: String) async throws {
            try await inner.deleteEntry(id: id)
        }
    }

    private func makeEntry(
        id: String,
        text: String,
        categoryIDs: [String] = [],
        notes: String = "",
        startedAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) -> TimeEntry {
        TimeEntry(
            id: id,
            activityText: text,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(600),
            durationSeconds: 600,
            source: "manual",
            categoryIDs: categoryIDs,
            notes: notes,
            createdAt: createdAt ?? startedAt,
            updatedAt: updatedAt ?? startedAt
        )
    }

    private func makeContext(
        connected: Bool = true
    ) -> (store: LocalStore, mock: MockCatalogRepository, controller: SyncController) {
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: temporaryStoreURL())
        let mock = MockCatalogRepository()
        let connectivity = MockConnectivity(connected: connected)
        let controller = SyncController(
            store: store,
            remote: mock,
            connectivity: connectivity
        ) { "u1" }
        return (store, mock, controller)
    }

    private func temporaryStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(LocalStore.databaseFileName(userID: "u1"))
    }

    private func waitForCycle(_ controller: SyncController) async {
        await waitUntil {
            if case .syncing = controller.status { return false }
            return true
        }
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func isIdle(_ status: SyncController.SyncStatus) -> Bool {
        if case .idle = status { return true }
        return false
    }
}

private typealias Call = MockCatalogRepository.Call
