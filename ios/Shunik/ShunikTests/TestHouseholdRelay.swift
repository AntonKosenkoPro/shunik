import Foundation
@testable import Shunik

/// Shared test relay: offline by default (throws `APIError.offline` on
/// household fetch), scriptable per test for household resolution.
final class TestHouseholdRelay: SyncRelay, @unchecked Sendable {
    var household: HouseholdWithMembers?
    var fetchError: Error?
    var pets: [PetRecord] = []
    var events: [EventRecord] = []
    var intakes: [IntakeRecord] = []
    var documents: [DocumentRecord] = []
    var deletions: [TombstoneRecord] = []

    func fetchHousehold() async throws -> HouseholdWithMembers {
        if let fetchError { throw fetchError }
        guard let household else { throw APIError.offline }
        return household
    }

    func listPets(since: String?) async throws -> PetListResponse {
        PetListResponse(pets: pets, cursor: "")
    }

    func createPet(_ pet: PetRecord) async throws -> PetRecord { pet }

    func updatePet(id: String, body: PetUpdateBody) async throws -> PetRecord {
        throw APIError.offline
    }

    func deletePet(id: String) async throws {}

    func listEvents(since: String?, petID: String?) async throws -> EventListResponse {
        EventListResponse(events: events, cursor: "")
    }

    func createEvent(_ event: EventRecord) async throws -> EventRecord { event }

    func updateEvent(id: String, body: EventUpdateBody) async throws -> EventRecord {
        throw APIError.offline
    }

    func deleteEvent(id: String) async throws {}

    func listIntakes(since: String?, courseID: String?) async throws -> IntakeListResponse {
        IntakeListResponse(intakes: intakes, cursor: "")
    }

    func createIntake(_ intake: IntakeRecord) async throws -> IntakeRecord { intake }

    func updateIntake(id: String, body: IntakeUpdateBody) async throws -> IntakeRecord {
        throw APIError.offline
    }

    func deleteIntake(id: String) async throws {}

    func listDocuments(since: String?) async throws -> DocumentListResponse {
        DocumentListResponse(documents: documents, cursor: "")
    }

    func createDocument(_ doc: DocumentRecord) async throws -> DocumentRecord { doc }

    func updateDocument(id: String, body: DocumentUpdateBody) async throws -> DocumentRecord {
        throw APIError.offline
    }

    func deleteDocument(id: String) async throws {}

    func listDeletions(since: String?) async throws -> DeletionListResponse {
        DeletionListResponse(deletions: deletions, cursor: "")
    }
}

/// Builds an offline `HouseholdService` for containers that never resolve
/// a household (bind-lifecycle and view-model tests).
@MainActor
func makeOfflineHouseholdService() -> HouseholdService {
    HouseholdService(relay: TestHouseholdRelay(), defaults: nil, sidecarURL: nil)
}
