import Testing
import Foundation
@testable import Shunik

/// `PetsViewModel` (§6.1) against a real store: `load()` lists created pets,
/// and `delete(_:)` follows the two-step undo contract (buffer FIRST, then
/// remove locally) with no outbox delete row yet — the buffered deletion
/// commits on the next sync cycle, so an undo never touches the relay.
/// Plus `PetScope` unit tests for the adaptive-shell rule.
@MainActor
@Suite("Pets view model", .serialized)
struct PetsViewModelTests {

    private func makeContext() throws -> (store: LocalStore, vm: PetsViewModel) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = LocalStore.databaseURL(householdID: "pets-vm-hh", in: dir)
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: url, householdID: "pets-vm-hh")
        let undo = UndoBufferStore(store: store)
        let controller = SyncController(
            store: store,
            connectivity: MockConnectivity(connected: true)
        ) { "u1" }
        let vm = PetsViewModel(store: store, undo: undo, sync: controller) { "u1" }
        return (store, vm)
    }

    private func samplePet(id: String = "pet-1", name: String = "Barsik") -> PetRecord {
        PetRecord(
            id: id, householdID: "pets-vm-hh", name: name, species: "cat",
            birthdate: "2020-05-01", notes: "",
            createdAt: "2026-10-26T11:00:00.000Z",
            updatedAt: "2026-10-26T11:00:00.000Z", updatedBy: "u1"
        )
    }

    @Test("load lists created pets")
    func loadListsCreatedPets() async throws {
        let (store, vm) = try makeContext()
        _ = try await store.createPet(samplePet(id: "pet-1", name: "Barsik"), updatedBy: "u1")
        _ = try await store.createPet(samplePet(id: "pet-2", name: "Rex"), updatedBy: "u1")
        await vm.load()
        #expect(vm.pets.count == 2)
        #expect(vm.errorMessage == nil)
    }

    @Test("delete buffers first, removes the row, and enqueues no outbox delete")
    func deleteBuffersThenRemoves() async throws {
        let (store, vm) = try makeContext()
        let stored = try await store.createPet(samplePet(), updatedBy: "u1")
        await vm.load()
        #expect(vm.pets.count == 1)

        await vm.delete(stored)

        #expect(vm.errorMessage == nil)
        #expect(vm.pets.isEmpty)
        #expect(try await store.getPet(id: stored.id) == nil)
        #expect(try await store.isBufferedForDeletion(resource: "pet", recordID: stored.id))
        let deletes = try await store.outboxRows().filter {
            $0.resource == SyncResource.pet.rawValue && $0.recordID == stored.id && $0.op == "delete"
        }
        #expect(deletes.isEmpty)
    }

    @Test("PetScope requires chrome only for multi-pet households")
    func scopeRequiresChrome() {
        #expect(!PetScope.requiresChrome(petCount: 0))
        #expect(!PetScope.requiresChrome(petCount: 1))
        #expect(PetScope.requiresChrome(petCount: 2))
    }

    @Test("PetScope clears the selection for zero/single-pet households")
    func scopeEffectiveSelection() {
        #expect(PetScope.effectiveSelection(petCount: 0, selectedID: "pet-1") == nil)
        #expect(PetScope.effectiveSelection(petCount: 1, selectedID: "pet-1") == nil)
        #expect(PetScope.effectiveSelection(petCount: 2, selectedID: "pet-1") == "pet-1")
        #expect(PetScope.effectiveSelection(petCount: 2, selectedID: nil) == nil)
    }
}
