import Testing
import Foundation
import Combine
@testable import TimeOfLife

@MainActor
@Suite("CategoryEditorViewModel Delete (unify-catalog-deletion)")
struct CategoryEditorDeleteTests {

    @Test("editor deleteConfirmed removes the category and returns true")
    func editorDeleteRemovesCategory() async throws {
        let store = try makeStore()
        try await store.createCategory(draft: CategoryDraft(name: "Work", icon: .briefcase), id: "c1", now: Date())
        let category = try #require(await store.category(id: "c1"))
        let vm = CategoryEditorViewModel(store: store, category: category, onSaved: { _ in }, onDuplicate: { _ in })

        let shouldDismiss = await vm.deleteConfirmed()

        #expect(shouldDismiss)
        #expect(try await store.category(id: "c1") == nil)
        // Buffered, not synced.
        #expect(try await store.undoBufferMostRecent() != nil)
        let rows = try await store.outboxRows()
        #expect(rows.allSatisfy { $0.op != "delete" })
    }

    @Test("editor deleteConfirmed on an already-gone category returns true")
    func editorDeleteMissingDismisses() async throws {
        let store = try makeStore()
        let vm = CategoryEditorViewModel(
            store: store,
            category: Category(id: "gone", name: "Gone", icon: "tag"),
            onSaved: { _ in },
            onDuplicate: { _ in }
        )

        #expect(await vm.deleteConfirmed())
    }

    @Test("create mode has nothing to delete")
    func createModeDeleteReturnsFalse() async throws {
        let store = try makeStore()
        let vm = CategoryEditorViewModel(store: store, category: nil, onSaved: { _ in }, onDuplicate: { _ in })

        #expect(await vm.deleteConfirmed() == false)
        #expect(!vm.isLoading)
    }

    @Test("successful delete releases the shared isLoading gate")
    func deleteReleasesIsLoadingOnSuccess() async throws {
        let store = try makeStore()
        try await store.createCategory(draft: CategoryDraft(name: "Work", icon: .briefcase), id: "c1", now: Date())
        let category = try #require(await store.category(id: "c1"))
        let vm = CategoryEditorViewModel(store: store, category: category, onSaved: { _ in }, onDuplicate: { _ in })
        var seen: [Bool] = []
        let cancellable = vm.$isLoading.sink { seen.append($0) }
        defer { cancellable.cancel() }

        #expect(await vm.deleteConfirmed())
        withExtendedLifetime(cancellable) {}
        #expect(seen.contains(true), "delete must raise the shared isLoading gate while in flight")
        #expect(seen.last == false, "delete must release the shared isLoading gate")
        #expect(vm.canSave)
    }

    @Test("already-gone delete releases the shared isLoading gate")
    func deleteReleasesIsLoadingWhenMissing() async throws {
        let store = try makeStore()
        let vm = CategoryEditorViewModel(
            store: store,
            category: Category(id: "gone", name: "Gone", icon: "tag"),
            onSaved: { _ in },
            onDuplicate: { _ in }
        )
        var seen: [Bool] = []
        let cancellable = vm.$isLoading.sink { seen.append($0) }
        defer { cancellable.cancel() }

        #expect(await vm.deleteConfirmed())
        withExtendedLifetime(cancellable) {}
        #expect(seen.contains(true), "delete must raise the shared isLoading gate while in flight")
        #expect(seen.last == false, "delete must release the shared isLoading gate")
    }

    @Test("delete refuses while a save is in flight and leaves the category intact")
    func deleteRefusesWhileSaveInFlight() async throws {
        let store = try makeStore()
        try await store.createCategory(draft: CategoryDraft(name: "Work", icon: .briefcase), id: "c1", now: Date())
        let category = try #require(await store.category(id: "c1"))
        let vm = CategoryEditorViewModel(store: store, category: category, onSaved: { _ in }, onDuplicate: { _ in })
        vm.name = "Renamed"
        vm.save()
        // save() raises the shared gate synchronously before its Task suspends.
        #expect(vm.isLoading, "save must raise the shared isLoading gate synchronously")
        // Same MainActor, no suspend before the guard: deterministic refusal.
        let refused = await vm.deleteConfirmed()
        #expect(refused == false, "delete must refuse while the shared gate is held")
        #expect(vm.isLoading, "refused delete must not clear the in-flight save gate")
        #expect(try await store.category(id: "c1") != nil)
        // Bounded settle for the in-flight save (no unbounded while).
        var settled = false
        for _ in 0..<200 where !settled {
            if !vm.isLoading {
                settled = true
            } else {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        #expect(settled, "save must settle within the bounded wait")
        #expect(try await store.category(id: "c1") != nil, "refused delete must not remove the category")
        #expect(try await store.category(id: "c1")?.name == "Renamed")
    }

    // MARK: - Helpers

    private func makeStore() throws -> LocalStore {
        try LocalStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(LocalStore.databaseFileName(userID: "u1")))
    }
}
