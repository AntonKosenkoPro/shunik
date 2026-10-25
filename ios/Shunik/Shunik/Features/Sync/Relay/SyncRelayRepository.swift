import Foundation

/// The sync relay surface: the Go backend's household-scoped CRUD for pets,
/// events, intakes, and documents plus the tombstone + household reads.
/// Implemented by `SyncRelayRepository`; consumed by the sync controller.
/// Every call requires auth.
protocol SyncRelay: Sendable {
    func fetchHousehold() async throws -> HouseholdWithMembers
    func listPets(since: String?) async throws -> PetListResponse
    func createPet(_ pet: PetRecord) async throws -> PetRecord
    func updatePet(id: String, body: PetUpdateBody) async throws -> PetRecord
    func deletePet(id: String) async throws
    func listEvents(since: String?, petID: String?) async throws -> EventListResponse
    func createEvent(_ event: EventRecord) async throws -> EventRecord
    func updateEvent(id: String, body: EventUpdateBody) async throws -> EventRecord
    func deleteEvent(id: String) async throws
    func listIntakes(since: String?, courseID: String?) async throws -> IntakeListResponse
    func createIntake(_ intake: IntakeRecord) async throws -> IntakeRecord
    func updateIntake(id: String, body: IntakeUpdateBody) async throws -> IntakeRecord
    func deleteIntake(id: String) async throws
    func listDocuments(since: String?) async throws -> DocumentListResponse
    func createDocument(_ doc: DocumentRecord) async throws -> DocumentRecord
    func updateDocument(id: String, body: DocumentUpdateBody) async throws -> DocumentRecord
    func deleteDocument(id: String) async throws
    func listDeletions(since: String?) async throws -> DeletionListResponse
}

/// Thrown on HTTP 409: the writer's `base_updated_at` was stale and the
/// server copy is carried here so the caller can resolve last-writer-wins.
struct ConflictError<T: Decodable & Sendable>: Error, Sendable {
    let server: T
}

/// Thrown by `HouseholdService` when the relay is unreachable and no
/// cached household exists for the user.
enum HouseholdResolveError: Error, Equatable, Sendable {
    case offlineNoCache
}

/// `SyncRelay` backed by an `APISending`. Follows `RemoteAuthRepository`
/// conventions: endpoint construction with the `/api/v1` prefix, auth on
/// every call, `APIError.decoding` on malformed bodies.
///
/// Transport choice: every method goes through `sendRaw` (never `send`).
/// `send` throws the parsed `APIError.server` envelope on non-2xx and
/// discards the body, so the 409 server copy under `details.server` would
/// be lost (the shared `DetailsEnvelope` only keeps string values). With
/// `sendRaw` the fake client surfaces `(data, 409)` tuples and this repo
/// decodes `details.server` into `ConflictError`. Note the production
/// caveat: the real `APIClient.sendRaw` ALSO throws the envelope error on
/// non-2xx instead of returning the tuple, so a live 409 arrives as
/// `APIError.server(code: "conflict")` — the update helpers below recover
/// it with a by-id GET refetch and still throw `ConflictError`. If
/// `APIClient` ever returns raw bodies for non-2xx, the tuple path covers
/// production too and the refetch becomes dead code.
final class SyncRelayRepository: SyncRelay {
    private let client: APISending
    private let basePath = "/api/v1"

    init(client: APISending) {
        self.client = client
    }

    // MARK: - Household

    func fetchHousehold() async throws -> HouseholdWithMembers {
        try await get("households/mine")
    }

    // MARK: - Pets

    func listPets(since: String?) async throws -> PetListResponse {
        try await get("pets" + query([("modified_since", since)]))
    }

    func createPet(_ pet: PetRecord) async throws -> PetRecord {
        try await sendForResult(.post, "pets", body: pet)
    }

    func updatePet(id: String, body: PetUpdateBody) async throws -> PetRecord {
        try await patch("pets/\(id)", body: body) {
            let record: PetRecord = try await self.get("pets/\(id)")
            return record
        }
    }

    func deletePet(id: String) async throws {
        try await deleteResource("pets/\(id)")
    }

    // MARK: - Events

    func listEvents(since: String?, petID: String?) async throws -> EventListResponse {
        try await get("events" + query([("modified_since", since), ("pet_id", petID)]))
    }

    func createEvent(_ event: EventRecord) async throws -> EventRecord {
        try await sendForResult(.post, "events", body: event)
    }

    func updateEvent(id: String, body: EventUpdateBody) async throws -> EventRecord {
        try await patch("events/\(id)", body: body) {
            let record: EventRecord = try await self.get("events/\(id)")
            return record
        }
    }

    func deleteEvent(id: String) async throws {
        try await deleteResource("events/\(id)")
    }

    // MARK: - Intakes

    func listIntakes(since: String?, courseID: String?) async throws -> IntakeListResponse {
        try await get("intakes" + query([("modified_since", since), ("course_id", courseID)]))
    }

    func createIntake(_ intake: IntakeRecord) async throws -> IntakeRecord {
        try await sendForResult(.post, "intakes", body: intake)
    }

    func updateIntake(id: String, body: IntakeUpdateBody) async throws -> IntakeRecord {
        try await patch("intakes/\(id)", body: body) {
            let record: IntakeRecord = try await self.get("intakes/\(id)")
            return record
        }
    }

    func deleteIntake(id: String) async throws {
        try await deleteResource("intakes/\(id)")
    }

    // MARK: - Documents

    func listDocuments(since: String?) async throws -> DocumentListResponse {
        try await get("documents" + query([("modified_since", since)]))
    }

    func createDocument(_ doc: DocumentRecord) async throws -> DocumentRecord {
        try await sendForResult(.post, "documents", body: doc)
    }

    func updateDocument(id: String, body: DocumentUpdateBody) async throws -> DocumentRecord {
        try await patch("documents/\(id)", body: body) {
            let record: DocumentRecord = try await self.get("documents/\(id)")
            return record
        }
    }

    func deleteDocument(id: String) async throws {
        try await deleteResource("documents/\(id)")
    }

    // MARK: - Deletions

    func listDeletions(since: String?) async throws -> DeletionListResponse {
        try await get("deletions" + query([("deleted_since", since)]))
    }

    // MARK: - Plumbing

    private func endpoint(_ method: HTTPMethod, _ path: String, body: Encodable? = nil) -> APIEndpoint {
        APIEndpoint(method: method, path: "\(basePath)/\(path)", body: body, requiresAuth: true)
    }

    /// Builds a `?a=b&c=d` suffix. Nil (or empty — an empty cursor would
    /// 400 as a malformed timestamp) values omit the item entirely.
    private func query(_ items: [(String, String?)]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "?&=+")
        let parts = items.compactMap { name, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(name)=\(encoded)"
        }
        return parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(underlying: String(describing: error))
        }
    }

    private func get<T: Decodable & Sendable>(_ path: String) async throws -> T {
        let (data, status) = try await client.sendRaw(endpoint(.get, path))
        guard 200 ... 299 ~= status else { throw APIError.unexpected }
        return try decode(data)
    }

    /// POST create: 201 new and 200 idempotent replay decode identically.
    /// The full record is sent as the body — the backend's create shapes
    /// are flat subsets of the record shapes and Go ignores unknown JSON
    /// fields, so no input mapping is needed.
    private func sendForResult<B: Encodable, T: Decodable & Sendable>(
        _ method: HTTPMethod,
        _ path: String,
        body: B
    ) async throws -> T {
        let (data, status) = try await client.sendRaw(endpoint(method, path, body: body))
        guard 200 ... 299 ~= status else { throw APIError.unexpected }
        return try decode(data)
    }

    /// PATCH guarded update: 200 decodes, 409 decodes `details.server`
    /// into `ConflictError`. The `conflictRefetch` fallback covers the
    /// production `APIClient`, which throws `APIError.server(code:
    /// "conflict")` without the body instead of returning a 409 tuple: the
    /// by-id GET returns the same current server row `details.server`
    /// would have carried.
    private func patch<B: Encodable, T: Decodable & Sendable>(
        _ path: String,
        body: B,
        conflictRefetch: () async throws -> T
    ) async throws -> T {
        let result: (data: Data, statusCode: Int)
        do {
            result = try await client.sendRaw(endpoint(.patch, path, body: body))
        } catch let api as APIError where api.code == "conflict" {
            throw ConflictError(server: try await conflictRefetch())
        }
        switch result.statusCode {
        case 200 ... 299:
            return try decode(result.data)
        case 409:
            throw conflictError(from: result.data, as: T.self)
        default:
            throw APIError.unexpected
        }
    }

    private func conflictError<T: Decodable & Sendable>(from data: Data, as type: T.Type) -> Error {
        do {
            let envelope = try JSONDecoder().decode(ConflictEnvelope<T>.self, from: data)
            return ConflictError(server: envelope.error.details.server)
        } catch {
            return APIError.decoding(underlying: String(describing: error))
        }
    }

    /// DELETE: 204 success; 404 (already gone) is success too. Both the
    /// tuple form (fake client) and the thrown envelope form (production
    /// `APIClient`, code `not_found` / `http_404`) are swallowed.
    private func deleteResource(_ path: String) async throws {
        let result: (data: Data, statusCode: Int)
        do {
            result = try await client.sendRaw(endpoint(.delete, path))
        } catch let api as APIError where api.code == "not_found" || api.code == "http_404" {
            return
        }
        if result.statusCode == 404 { return }
        guard 200 ... 299 ~= result.statusCode else { throw APIError.unexpected }
    }
}

/// The 409 envelope: `{"error": {"code": "conflict", "details": {"server": …}}}`.
private struct ConflictEnvelope<T: Decodable>: Decodable {
    struct Body: Decodable {
        let code: String
        let message: String
        let details: Details
    }
    struct Details: Decodable {
        let server: T
    }
    let error: Body
}

// MARK: - HouseholdService

/// Resolves and caches the caller's household id. Mirrors `SessionCache`'s
/// pattern: suite `UserDefaults` + a sidecar file in the shared container
/// (file-first reliability for extension surfaces), best-effort writes.
@MainActor
final class HouseholdService {
    private let relay: any SyncRelay
    private let defaults: UserDefaults
    private let sidecarURL: URL?

    init(relay: any SyncRelay, defaults: UserDefaults?, sidecarURL: URL?) {
        self.relay = relay
        self.defaults = defaults ?? .standard
        self.sidecarURL = sidecarURL
    }

    /// GETs `/mine`, caches the household id per user id, mirrors the
    /// sidecar + session default, and returns the id. On offline/transport
    /// failure returns the cached value for this user, or throws
    /// `offlineNoCache` when there is none. Other errors propagate.
    @MainActor
    func resolveHousehold(userID: String) async throws -> String {
        do {
            let fetched = try await relay.fetchHousehold()
            let householdID = fetched.household.id
            var cached = (defaults.dictionary(forKey: Keys.householdsByUser) as? [String: String]) ?? [:]
            cached[userID] = householdID
            defaults.set(cached, forKey: Keys.householdsByUser)
            writeSidecar(householdID: householdID)
            defaults.set(householdID, forKey: Keys.sessionHouseholdID)
            return householdID
        } catch {
            if isTransportFailure(error) {
                if let cached = cachedHouseholdID(for: userID) { return cached }
                throw HouseholdResolveError.offlineNoCache
            }
            throw error
        }
    }

    /// Removes the sidecar + session default. The per-user cache is kept
    /// so an offline return still works after sign-out/reinstall.
    @MainActor
    func clearActiveHousehold() {
        if let url = sidecarURL {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                try? "".write(to: url, atomically: true, encoding: .utf8)
            }
        }
        defaults.removeObject(forKey: Keys.sessionHouseholdID)
    }

    private func cachedHouseholdID(for userID: String) -> String? {
        (defaults.dictionary(forKey: Keys.householdsByUser) as? [String: String])?[userID]
    }

    /// Best-effort like `SessionCache`: a failed write must never fail sync.
    private func writeSidecar(householdID: String) {
        guard let url = sidecarURL else { return }
        try? householdID.write(to: url, atomically: true, encoding: .utf8)
        FileManager.default.ensureAccessibleAfterFirstUnlock(url)
    }

    private func isTransportFailure(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        switch api {
        case .offline, .transport:
            return true
        default:
            return false
        }
    }

    private enum Keys {
        static let householdsByUser = "com.shunik.householdsByUser"
        static let sessionHouseholdID = "com.shunik.session.householdID"
    }
}
