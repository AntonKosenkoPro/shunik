import Testing
import Foundation
@testable import Shunik

/// `TimelineViewModel` against a real store: All-vs-pet filtering, the
/// two-step undoable delete (buffered, no outbox row), single-pet chrome
/// hiding, and the weight grams path the form persists.
@MainActor
@Suite("TimelineViewModel")
struct TimelineViewModelTests {

    private func tempStore() throws -> LocalStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("test.db")
        return try LocalStore(url: url)
    }

    private func makeViewModel(store: LocalStore) -> TimelineViewModel {
        TimelineViewModel(
            store: store,
            undo: UndoBufferStore(store: store),
            sync: SyncController(store: store, connectivity: Connectivity())
        ) { "u1" }
    }

    private func samplePet(id: String, name: String) -> PetRecord {
        PetRecord(
            id: id, householdID: "hh-1", name: name, species: "cat",
            birthdate: nil, notes: "",
            createdAt: "2026-10-26T11:00:00.000Z",
            updatedAt: "2026-10-26T11:00:00.000Z", updatedBy: "u1"
        )
    }

    private func decodeEvent(_ json: String) throws -> EventRecord {
        try JSONDecoder().decode(EventRecord.self, from: Data(json.utf8))
    }

    private func eventJSON(
        id: String,
        petID: String,
        kind: String,
        occurredAt: String,
        title: String,
        detail: String
    ) -> String {
        "{\"id\":\"\(id)\",\"household_id\":\"hh-1\",\"pet_id\":\"\(petID)\"," +
        "\"kind\":\"\(kind)\",\"occurred_at\":\"\(occurredAt)\"," +
        "\"title\":\"\(title)\",\"detail\":{\(detail)}," +
        "\"created_at\":\"2026-10-26T11:00:00.000Z\"," +
        "\"updated_at\":\"2026-10-26T12:00:00.000Z\",\"updated_by\":\"u1\"}"
    }

    @Test("All shows every pet newest-first, selection filters to one pet")
    func filterAllVsPet() async throws {
        let store = try tempStore()
        _ = try await store.createPet(samplePet(id: "pet-1", name: "Barsik"), updatedBy: "u1")
        _ = try await store.createPet(samplePet(id: "pet-2", name: "Murzik"), updatedBy: "u1")
        _ = try await store.createEvent(try decodeEvent(eventJSON(
            id: "ev-old", petID: "pet-1", kind: "grooming",
            occurredAt: "2026-10-24T12:00:00.000Z", title: "Haircut",
            detail: "\"grooming\":{\"service\":\"cut\",\"place\":\"Salon\",\"notes\":\"\"}"
        )), updatedBy: "u1")
        _ = try await store.createEvent(try decodeEvent(eventJSON(
            id: "ev-new", petID: "pet-2", kind: "weight",
            occurredAt: "2026-10-26T12:00:00.000Z", title: "Weigh-in",
            detail: "\"weight\":{\"grams\":4300}"
        )), updatedBy: "u1")

        let vm = makeViewModel(store: store)
        await vm.load()
        #expect(vm.showsScopeChrome)
        #expect(vm.selectedPetID == nil)
        #expect(vm.events.map(\.id) == ["ev-new", "ev-old"])

        vm.selectedPetID = "pet-1"
        await vm.load()
        #expect(vm.events.map(\.id) == ["ev-old"])
        #expect(vm.events.allSatisfy { $0.petID == "pet-1" })
    }

    @Test("delete buffers the snapshot with no outbox row")
    func deleteBuffersWithoutOutbox() async throws {
        let store = try tempStore()
        _ = try await store.createPet(samplePet(id: "pet-1", name: "Barsik"), updatedBy: "u1")
        let stored = try await store.createEvent(try decodeEvent(eventJSON(
            id: "ev-1", petID: "pet-1", kind: "weight",
            occurredAt: "2026-10-26T12:00:00.000Z", title: "Weigh-in",
            detail: "\"weight\":{\"grams\":4300}"
        )), updatedBy: "u1")

        let vm = makeViewModel(store: store)
        await vm.load()
        #expect(vm.events.count == 1)

        await vm.delete(vm.events[0])
        #expect(try await store.getEvent(id: stored.id) == nil)
        // Buffered, not committed: no delete outbox row yet (the earlier
        // create rows stay pending — they push on the next cycle).
        let deletes = try await store.outboxRows().filter {
            $0.resource == SyncResource.event.rawValue && $0.op == "delete"
        }
        #expect(deletes.isEmpty)
        #expect(try await store.isBufferedForDeletion(resource: "event", recordID: stored.id))
        #expect(vm.events.isEmpty)
    }

    @Test("single pet hides chrome and filters to that pet")
    func singlePetNoChrome() async throws {
        let store = try tempStore()
        _ = try await store.createPet(samplePet(id: "pet-1", name: "Barsik"), updatedBy: "u1")
        _ = try await store.createEvent(try decodeEvent(eventJSON(
            id: "ev-1", petID: "pet-1", kind: "vaccination",
            occurredAt: "2026-10-26T12:00:00.000Z", title: "Rabies",
            detail: "\"vaccination\":{\"vaccine\":\"Rabies\",\"batch\":\"B1\",\"vet\":\"Doc\",\"notes\":\"\"}"
        )), updatedBy: "u1")

        let vm = makeViewModel(store: store)
        await vm.load()
        #expect(!vm.showsScopeChrome)
        #expect(vm.effectivePetID == "pet-1")
        #expect(vm.events.map(\.id) == ["ev-1"])
    }

    @Test("weight form path persists integer grams")
    func weightGramsPath() async throws {
        let store = try tempStore()
        _ = try await store.createPet(samplePet(id: "pet-1", name: "Barsik"), updatedBy: "u1")
        // What the form derives from a "4.3 kg" draft via UnitLens.
        let grams = try #require(UnitLens.grams(value: 4.3, unit: "kg"))
        let stored = try await store.createEvent(try decodeEvent(eventJSON(
            id: "ev-w", petID: "pet-1", kind: "weight",
            occurredAt: "2026-10-26T12:00:00.000Z", title: "Weigh-in",
            detail: "\"weight\":{\"grams\":\(grams)}"
        )), updatedBy: "u1")
        #expect(stored.weight == WeightDetail(grams: 4300))
        #expect(try await store.getEvent(id: stored.id)?.weight?.grams == 4300)
    }
}
