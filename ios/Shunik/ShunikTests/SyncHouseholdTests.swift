import Testing
import Foundation

private func makeServiceHousehold(id: String = "hh-1") -> HouseholdWithMembers {
    let member = HouseholdMemberRecord(householdID: id, userID: "user-1", email: "a@b.com",
                                       addedBy: "user-1", joinedAt: "2026-10-26T10:00:00.100Z")
    let household = HouseholdRecord(id: id, createdAt: "2026-10-26T10:00:00.100Z",
                                    updatedAt: "2026-10-26T10:00:00.100Z", updatedBy: "user-1")
    return HouseholdWithMembers(household: household, members: [member])
}
@testable import Shunik

// MARK: - HouseholdService tests

private final class StubRelay: SyncRelay, @unchecked Sendable {
    var household: HouseholdWithMembers?
    var fetchError: Error?
    func fetchHousehold() async throws -> HouseholdWithMembers {
        if let fetchError { throw fetchError }
        guard let household else { throw APIError.unexpected }
        return household
    }
    func listPets(since: String?) async throws -> PetListResponse { throw APIError.unexpected }
    func createPet(_ pet: PetRecord) async throws -> PetRecord { throw APIError.unexpected }
    func updatePet(id: String, body: PetUpdateBody) async throws -> PetRecord { throw APIError.unexpected }
    func deletePet(id: String) async throws { throw APIError.unexpected }
    func listEvents(since: String?, petID: String?) async throws -> EventListResponse { throw APIError.unexpected }
    func createEvent(_ event: EventRecord) async throws -> EventRecord { throw APIError.unexpected }
    func updateEvent(id: String, body: EventUpdateBody) async throws -> EventRecord { throw APIError.unexpected }
    func deleteEvent(id: String) async throws { throw APIError.unexpected }
    func listIntakes(since: String?, courseID: String?) async throws -> IntakeListResponse { throw APIError.unexpected }
    func createIntake(_ intake: IntakeRecord) async throws -> IntakeRecord { throw APIError.unexpected }
    func updateIntake(id: String, body: IntakeUpdateBody) async throws -> IntakeRecord { throw APIError.unexpected }
    func deleteIntake(id: String) async throws { throw APIError.unexpected }
    func listDocuments(since: String?) async throws -> DocumentListResponse { throw APIError.unexpected }
    func createDocument(_ doc: DocumentRecord) async throws -> DocumentRecord { throw APIError.unexpected }
    func updateDocument(id: String, body: DocumentUpdateBody) async throws -> DocumentRecord { throw APIError.unexpected }
    func deleteDocument(id: String) async throws { throw APIError.unexpected }
    func listDeletions(since: String?) async throws -> DeletionListResponse { throw APIError.unexpected }
}

@Suite("HouseholdService")
struct HouseholdServiceTests {
    @MainActor
    private func makeService(stub: StubRelay) throws -> (HouseholdService, UserDefaults, URL) {
        let defaults = try #require(UserDefaults(suiteName: "HH-\(UUID().uuidString)"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sidecar = dir.appendingPathComponent("active-session-household-id")
        return (HouseholdService(relay: stub, defaults: defaults, sidecarURL: sidecar), defaults, sidecar)
    }

    @MainActor
    @Test("caches household on success across defaults, sidecar, and session key")
    func cachesOnSuccess() async throws {
        let stub = StubRelay()
        stub.household = makeServiceHousehold(id: "hh-9")
        let (service, defaults, sidecar) = try makeService(stub: stub)
        #expect(try await service.resolveHousehold(userID: "user-1") == "hh-9")
        let cached = defaults.dictionary(forKey: "com.shunik.householdsByUser") as? [String: String]
        #expect(cached?["user-1"] == "hh-9")
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "hh-9")
        #expect(defaults.string(forKey: "com.shunik.session.householdID") == "hh-9")
    }

    @MainActor
    @Test("serves the cached household when offline")
    func servesCacheOffline() async throws {
        let stub = StubRelay()
        stub.household = makeServiceHousehold(id: "hh-9")
        let (service, _, _) = try makeService(stub: stub)
        _ = try await service.resolveHousehold(userID: "user-1")
        stub.household = nil
        stub.fetchError = APIError.offline
        #expect(try await service.resolveHousehold(userID: "user-1") == "hh-9")
    }

    @MainActor
    @Test("throws offlineNoCache when offline with an empty cache")
    func throwsOfflineNoCache() async throws {
        let stub = StubRelay()
        stub.fetchError = APIError.transport(underlying: "down")
        let (service, _, _) = try makeService(stub: stub)
        do {
            _ = try await service.resolveHousehold(userID: "user-1")
            Issue.record("Expected offlineNoCache")
        } catch let error as HouseholdResolveError {
            #expect(error == .offlineNoCache)
        }
    }

    @MainActor
    @Test("propagates non-transport errors without serving the cache")
    func propagatesServerErrors() async throws {
        let stub = StubRelay()
        stub.household = makeServiceHousehold(id: "hh-9")
        let (service, _, _) = try makeService(stub: stub)
        _ = try await service.resolveHousehold(userID: "user-1")
        stub.fetchError = APIError.unauthorized
        do {
            _ = try await service.resolveHousehold(userID: "user-1")
            Issue.record("Expected unauthorized to propagate")
        } catch let api as APIError {
            #expect(api == .unauthorized)
        }
    }

    @MainActor
    @Test("clearActiveHousehold removes the sidecar and session key but keeps the cache")
    func clearKeepsCache() async throws {
        let stub = StubRelay()
        stub.household = makeServiceHousehold(id: "hh-9")
        let (service, defaults, sidecar) = try makeService(stub: stub)
        _ = try await service.resolveHousehold(userID: "user-1")
        service.clearActiveHousehold()
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        #expect(defaults.string(forKey: "com.shunik.session.householdID") == nil)
        let cached = defaults.dictionary(forKey: "com.shunik.householdsByUser") as? [String: String]
        #expect(cached?["user-1"] == "hh-9")
        stub.fetchError = APIError.offline
        #expect(try await service.resolveHousehold(userID: "user-1") == "hh-9")
    }
}
