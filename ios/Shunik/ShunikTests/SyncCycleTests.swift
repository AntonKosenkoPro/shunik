import Testing
import Foundation
@testable import Shunik

/// Sync cycle integration (runCycle with a real `LocalStore` + scripted
/// relay): pull-merge LWW, tombstone delete-wins + recreation-wins, and
/// outbox drain recovery (404 resurrect/delete-success, 409 rebase, 422
/// loud-keep). Push-then-commit ordering for buffered deletions included.
@MainActor
@Suite("SyncCycle")
struct SyncCycleTests {

    // MARK: - Harness

    private final class ScriptRelay: SyncRelay, @unchecked Sendable {
        var pets: [PetRecord] = []
        var events: [EventRecord] = []
        var intakes: [IntakeRecord] = []
        var documents: [DocumentRecord] = []
        var deletions: [TombstoneRecord] = []

        var updatePetBehavior: (PetUpdateBody) throws -> PetRecord = { _ in throw APIError.offline }
        var updateCalls = 0
        var createdPetIDs: [String] = []
        var deletedPetIDs: [String] = []
        var deletePetError: Error?
        var updateIntakeBehavior: (IntakeUpdateBody) throws -> IntakeRecord = { _ in throw APIError.offline }

        func listPets(since: String?) async throws -> PetListResponse {
            PetListResponse(pets: pets, cursor: "")
        }

        func createPet(_ pet: PetRecord) async throws -> PetRecord {
            createdPetIDs.append(pet.id)
            return pet
        }

        func updatePet(id: String, body: PetUpdateBody) async throws -> PetRecord {
            updateCalls += 1
            return try updatePetBehavior(body)
        }

        func deletePet(id: String) async throws {
            deletedPetIDs.append(id)
            if let deletePetError {
                // Mirror SyncRelayRepository.deleteResource: 404 is success.
                if let api = deletePetError as? APIError, api.code == "not_found" { return }
                throw deletePetError
            }
        }

        func listEvents(since: String?, petID: String?) async throws -> EventListResponse {
            EventListResponse(events: events, cursor: "")
        }

        func createEvent(_ event: EventRecord) async throws -> EventRecord { event }
        func updateEvent(id: String, body: EventUpdateBody) async throws -> EventRecord { throw APIError.offline }
        func deleteEvent(id: String) async throws {}

        func listIntakes(since: String?, courseID: String?) async throws -> IntakeListResponse {
            IntakeListResponse(intakes: intakes, cursor: "")
        }

        func createIntake(_ intake: IntakeRecord) async throws -> IntakeRecord { intake }

        func updateIntake(id: String, body: IntakeUpdateBody) async throws -> IntakeRecord {
            try updateIntakeBehavior(body)
        }

        func deleteIntake(id: String) async throws {}

        func listDocuments(since: String?) async throws -> DocumentListResponse {
            DocumentListResponse(documents: documents, cursor: "")
        }

        func createDocument(_ doc: DocumentRecord) async throws -> DocumentRecord { doc }
        func updateDocument(id: String, body: DocumentUpdateBody) async throws -> DocumentRecord { throw APIError.offline }
        func deleteDocument(id: String) async throws {}

        func listDeletions(since: String?) async throws -> DeletionListResponse {
            DeletionListResponse(deletions: deletions, cursor: "")
        }

        func fetchHousehold() async throws -> HouseholdWithMembers { throw APIError.offline }
    }

    private func makeContext(relay: ScriptRelay) throws -> (LocalStore, SyncController) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("cycle.db")
        let store = try LocalStore(url: url, householdID: "hh-cycle")
        let controller = SyncController(
            store: store,
            connectivity: MockConnectivity(connected: true)
        ) { "u1" }
        controller.relay = relay
        return (store, controller)
    }

    private func samplePet(id: String, name: String, updatedAt: String) -> PetRecord {
        PetRecord(
            id: id, householdID: "hh-cycle", name: name, species: "cat",
            birthdate: nil, notes: "",
            createdAt: "2026-10-26T11:00:00.000Z",
            updatedAt: updatedAt, updatedBy: "u1"
        )
    }

    private func runCycle(_ controller: SyncController) async {
        controller.activate(userID: "u1")
        await controller.waitForCycleEnd(timeout: 5)
    }

    /// Shifts an RFC3339-millisecond timestamp by whole hours. Test fixtures
    /// use real `now()` stamps for local writes, so older/newer server rows
    /// must be computed relative to them — never hardcoded.
    private func hourOffset(_ base: String, _ hours: Double) -> String {
        // swiftlint:disable:next force_unwrapping
        let date = RFC3339Milli.parse(base)!
        return RFC3339Milli.format(date.addingTimeInterval(hours * 3600))
    }

    // MARK: - Pull-merge

    @Test("pull adopts newer server rows and ignores older ones")
    func pullMergeLWW() async throws {
        let relay = ScriptRelay()
        let (store, controller) = try makeContext(relay: relay)
        // Local pet, freshly created (updatedAt = now).
        let local = try await store.createPet(
            samplePet(id: "pet-1", name: "Local", updatedAt: "2026-10-26T12:00:00.000Z"),
            updatedBy: "u1"
        )
        _ = local
        // Server: pet-1 older (ignored), pet-2 brand new (adopted).
        relay.pets = [
            samplePet(id: "pet-1", name: "Stale", updatedAt: hourOffset(local.updatedAt, -1)),
            samplePet(id: "pet-2", name: "Server", updatedAt: hourOffset(local.updatedAt, 1)),
        ]
        await runCycle(controller)

        #expect(try await store.getPet(id: "pet-1")?.name == "Local")
        #expect(try await store.getPet(id: "pet-2")?.name == "Server")
    }

    // MARK: - Tombstones

    @Test("tombstone deletes the local row; a newer local recreation wins")
    func tombstonesDeleteWins() async throws {
        let relay = ScriptRelay()
        let (store, controller) = try makeContext(relay: relay)
        _ = try await store.createPet(
            samplePet(id: "gone", name: "Gone", updatedAt: "2026-10-26T12:00:00.000Z"),
            updatedBy: "u1"
        )
        _ = try await store.createPet(
            samplePet(id: "kept", name: "Kept", updatedAt: "2026-10-28T12:00:00.000Z"),
            updatedBy: "u1"
        )
        // Drain the create rows first so the tombstone step sees clean rows.
        await runCycle(controller)
        #expect(try await store.outboxRows().isEmpty)

        let goneTS = try await store.getPet(id: "gone")?.updatedAt ?? ""
        let keptTS = try await store.getPet(id: "kept")?.updatedAt ?? ""
        relay.deletions = [
            TombstoneRecord(resource: "pet", recordID: "gone", deletedAt: hourOffset(goneTS, 1)),
            TombstoneRecord(resource: "pet", recordID: "kept", deletedAt: hourOffset(keptTS, -1)),
            TombstoneRecord(resource: "unknown-future", recordID: "x", deletedAt: hourOffset(keptTS, 1)),
        ]
        controller.trigger(userID: "u1")
        await controller.waitForCycleEnd(timeout: 5)

        #expect(try await store.getPet(id: "gone") == nil)
        #expect(try await store.getPet(id: "kept")?.name == "Kept")
    }

    // MARK: - Drain

    @Test("drain pushes creates and drops the rows")
    func drainCreate() async throws {
        let relay = ScriptRelay()
        let (store, controller) = try makeContext(relay: relay)
        _ = try await store.createPet(
            samplePet(id: "new", name: "New", updatedAt: "2026-10-26T12:00:00.000Z"),
            updatedBy: "u1"
        )
        await runCycle(controller)

        #expect(relay.createdPetIDs == ["new"])
        #expect(try await store.outboxRows().isEmpty)
        if case .idle = controller.status {
        } else {
            Issue.record("expected idle, got \(controller.status)")
        }
    }

    @Test("drain rebases once on 409 then adopts the server copy")
    func drainConflictRebase() async throws {
        let relay = ScriptRelay()
        let (store, controller) = try makeContext(relay: relay)
        let created = try await store.createPet(
            samplePet(id: "c", name: "C", updatedAt: "2026-10-26T12:00:00.000Z"),
            updatedBy: "u1"
        )
        var renamed = created
        renamed.name = "C2"
        _ = try await store.updatePet(renamed, baseUpdatedAt: created.updatedAt, updatedBy: "u1")

        var server = created
        server.name = "Server"
        server.updatedAt = "2026-10-29T12:00:00.000Z"
        let serverCopy = server
        relay.pets = []
        relay.updatePetBehavior = { _ in throw ConflictError<PetRecord>(server: serverCopy) }
        // First cycle: create drains, update hits 409, rebase retries (also
        // 409 from the script) → server copy adopted, row dropped.
        await runCycle(controller)

        #expect(relay.updateCalls == 2)
        #expect(try await store.getPet(id: "c")?.name == "Server")
        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("drain resurrects on 404 update and swallows 404 delete")
    func drainResurrectAndDeleteMissing() async throws {
        let relay = ScriptRelay()
        let (store, controller) = try makeContext(relay: relay)
        let created = try await store.createPet(
            samplePet(id: "r", name: "R", updatedAt: "2026-10-26T12:00:00.000Z"),
            updatedBy: "u1"
        )
        var renamed = created
        renamed.name = "R2"
        _ = try await store.updatePet(renamed, baseUpdatedAt: created.updatedAt, updatedBy: "u1")
        relay.updatePetBehavior = { _ in throw APIError.server(code: "not_found", message: "gone") }
        await runCycle(controller)

        #expect(relay.createdPetIDs.contains("r"))
        #expect(try await store.outboxRows().isEmpty)

        // Delete path: 404 is success.
        try await store.deletePet(id: "r", updatedBy: "u1")
        relay.deletePetError = APIError.server(code: "not_found", message: "gone")
        controller.trigger(userID: "u1")
        await controller.waitForCycleEnd(timeout: 5)

        #expect(try await store.outboxRows().isEmpty)
    }

    @Test("drain keeps 422 rows and reports error status")
    func drainValidationErrorKeepsRow() async throws {
        let relay = ScriptRelay()
        let (store, controller) = try makeContext(relay: relay)
        let created = try await store.createPet(
            samplePet(id: "v", name: "V", updatedAt: "2026-10-26T12:00:00.000Z"),
            updatedBy: "u1"
        )
        var renamed = created
        renamed.name = "V2"
        _ = try await store.updatePet(renamed, baseUpdatedAt: created.updatedAt, updatedBy: "u1")
        relay.updatePetBehavior = { _ in throw APIError.server(code: "invalid_body", message: "bad") }
        await runCycle(controller)

        #expect(!(try await store.outboxRows()).isEmpty)
        if case .error = controller.status {
        } else {
            Issue.record("expected error status, got \(controller.status)")
        }
    }

    // MARK: - Buffered deletions

    @Test("buffered deletions push before commit, then drain the delete row")
    func bufferedPushThenCommit() async throws {
        let relay = ScriptRelay()
        let (store, controller) = try makeContext(relay: relay)
        let created = try await store.createPet(
            samplePet(id: "b", name: "B", updatedAt: "2026-10-26T12:00:00.000Z"),
            updatedBy: "u1"
        )
        await runCycle(controller)
        #expect(try await store.outboxRows().isEmpty)

        let buffer = UndoBufferStore(store: store)
        try await buffer.bufferDeletion(of: [(resource: .pet, id: created.id)])
        try await store.removePetLocal(id: created.id)

        controller.trigger(userID: "u1")
        await controller.waitForCycleEnd(timeout: 5)

        #expect(relay.deletedPetIDs.contains("b"))
        #expect(try await store.bufferedDeletions().isEmpty)
        #expect(try await store.outboxRows().isEmpty)
    }
}
