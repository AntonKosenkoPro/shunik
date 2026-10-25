import Testing
import Foundation
@testable import Shunik

// MARK: - Fixtures

private func makePet(id: String = "pet-1", updatedAt: String = "2026-10-26T12:00:00.100Z") -> PetRecord {
    PetRecord(id: id, householdID: "hh-1", name: "Barsik", species: "cat", birthdate: "2020-05-01",
              notes: "notes", createdAt: "2026-10-26T11:00:00.100Z", updatedAt: updatedAt, updatedBy: "user-1")
}

private func makeEventJSON(id: String = "event-1") -> String {
    "{\"id\":\"\(id)\",\"household_id\":\"hh-1\",\"pet_id\":\"pet-1\",\"kind\":\"weight\"," +
    "\"occurred_at\":\"2026-10-26T12:00:00.100Z\",\"title\":\"Weigh-in\"," +
    "\"detail\":{\"weight\":{\"grams\":4200}}," +
    "\"created_at\":\"2026-10-26T12:00:00.100Z\",\"updated_at\":\"2026-10-26T12:00:00.100Z\"," +
    "\"updated_by\":\"user-1\"}"
}

private func makeEvent(id: String = "event-1") throws -> EventRecord {
    try JSONDecoder().decode(EventRecord.self, from: Data(makeEventJSON(id: id).utf8))
}

private func makeIntake(id: String = "intake-1") -> IntakeRecord {
    IntakeRecord(id: id, householdID: "hh-1", courseID: "course-1", dueAt: "2026-10-26T08:00:00.100Z",
                 status: "pending", takenAt: nil, doseSnapshot: "0.5 tablet", note: "",
                 markedBy: "user-1", createdAt: "2026-10-26T07:00:00.100Z",
                 updatedAt: "2026-10-26T07:00:00.100Z")
}

private func makeDocument(id: String = "doc-1") -> DocumentRecord {
    DocumentRecord(id: id, householdID: "hh-1", title: "Lab results", mime: "application/pdf",
                   sizeBytes: 1234, filename: "labs.pdf", blobKey: "hh-1/doc-1",
                   ready: false, extractedText: "", petIDs: ["pet-1"],
                   createdAt: "2026-10-26T07:00:00.100Z", updatedAt: "2026-10-26T07:00:00.100Z",
                   updatedBy: "user-1")
}

private func makeHousehold(id: String = "hh-1") -> HouseholdWithMembers {
    let member = HouseholdMemberRecord(householdID: id, userID: "user-1", email: "a@b.com",
                                       addedBy: "user-1", joinedAt: "2026-10-26T10:00:00.100Z")
    let household = HouseholdRecord(id: id, createdAt: "2026-10-26T10:00:00.100Z",
                                    updatedAt: "2026-10-26T10:00:00.100Z", updatedBy: "user-1")
    return HouseholdWithMembers(household: household, members: [member])
}

private func conflictData<T: Encodable>(server: T) throws -> Data {
    let serverJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(server))
    let envelope: [String: Any] = [
        "error": ["code": "conflict", "message": "stale", "details": ["server": serverJSON]],
    ]
    return try JSONSerialization.data(withJSONObject: envelope)
}

// MARK: - SyncRelay tests

@Suite("SyncRelayRepository")
struct SyncRelayTests {
    private func wired() -> (SyncRelayRepository, MockAPIClient) {
        let mock = MockAPIClient()
        return (SyncRelayRepository(client: mock), mock)
    }

    @Test("listPets omits modified_since when nil, sends it when given")
    func listPetsOmitsQuery() async throws {
        let (repo, mock) = wired()
        mock.sendRawHandler = { _ in (try JSONEncoder().encode(PetListResponse(pets: [makePet()], cursor: "c1")), 200) }
        let result = try await repo.listPets(since: nil)
        #expect(result.pets[0].name == "Barsik")
        #expect(result.cursor == "c1")
        let received = try #require(mock.received.first)
        #expect(received.method == .get && received.path == "/api/v1/pets" && received.requiresAuth)
        _ = try await repo.listPets(since: "2026-10-26T12:00:00.100Z")
        #expect(try #require(mock.received.last).path.contains("modified_since=2026-10-26T12"))
    }

    @Test("createPet posts the record; 201 and 200 both decode")
    func createPetRoundTrip() async throws {
        for status in [201, 200] {
            let (repo, mock) = wired()
            let pet = makePet()
            mock.sendRawHandler = { _ in (try JSONEncoder().encode(pet), status) }
            #expect(try await repo.createPet(pet) == pet)
            let received = try #require(mock.received.first)
            #expect(received.method == .post && received.path == "/api/v1/pets" && received.requiresAuth)
            let sent = try JSONDecoder().decode(PetRecord.self, from: try #require(received.body))
            #expect(sent.id == pet.id)
        }
    }

    @Test("updatePet sends the body and decodes 200")
    func updatePetSuccess() async throws {
        let (repo, mock) = wired()
        mock.sendRawHandler = { _ in
            (try JSONEncoder().encode(makePet(updatedAt: "2026-10-26T13:00:00.100Z")), 200)
        }
        let body = PetUpdateBody(baseUpdatedAt: "2026-10-26T12:00:00.100Z", name: "Barsik",
                                 species: "cat", birthdate: "2020-05-01", notes: "notes")
        #expect(try await repo.updatePet(id: "pet-1", body: body).updatedAt == "2026-10-26T13:00:00.100Z")
        let received = try #require(mock.received.first)
        #expect(received.method == .patch && received.path == "/api/v1/pets/pet-1")
        let sent = try JSONDecoder().decode(PetUpdateBody.self, from: try #require(received.body))
        #expect(sent.baseUpdatedAt == body.baseUpdatedAt)
    }

    @Test("update 409s decode server copies into ConflictError")
    func updateConflicts() async throws {
        let (petRepo, petMock) = wired()
        let petServer = makePet(updatedAt: "2026-10-26T14:00:00.100Z")
        petMock.sendRawHandler = { _ in (try conflictData(server: petServer), 409) }
        do {
            _ = try await petRepo.updatePet(id: "pet-1", body: PetUpdateBody(baseUpdatedAt: "stale", name: "B", species: "cat", birthdate: nil, notes: ""))
            Issue.record("Expected ConflictError")
        } catch let conflict as ConflictError<PetRecord> {
            #expect(conflict.server == petServer)
        }
        let (eventRepo, eventMock) = wired()
        let eventServer = try makeEvent()
        eventMock.sendRawHandler = { _ in (try conflictData(server: eventServer), 409) }
        do {
            _ = try await eventRepo.updateEvent(id: "event-1", body: EventUpdateBody(
                baseUpdatedAt: "stale", petID: "pet-1", kind: "weight",
                occurredAt: "2026-10-26T12:00:00.100Z", nextDueAt: nil, title: "Weigh-in",
                vaccination: nil, grooming: nil, weight: WeightDetail(grams: 4300), course: nil))
            Issue.record("Expected ConflictError")
        } catch let conflict as ConflictError<EventRecord> {
            #expect(conflict.server.weight?.grams == 4200)
        }
        let (intakeRepo, intakeMock) = wired()
        let intakeServer = makeIntake()
        intakeMock.sendRawHandler = { _ in (try conflictData(server: intakeServer), 409) }
        do {
            _ = try await intakeRepo.updateIntake(id: "intake-1", body: IntakeUpdateBody(
                baseUpdatedAt: "stale", status: "taken", takenAt: nil, note: nil, doseSnapshot: nil))
            Issue.record("Expected ConflictError")
        } catch let conflict as ConflictError<IntakeRecord> {
            #expect(conflict.server == intakeServer)
        }
        let (docRepo, docMock) = wired()
        let docServer = makeDocument()
        docMock.sendRawHandler = { _ in (try conflictData(server: docServer), 409) }
        do {
            _ = try await docRepo.updateDocument(id: "doc-1", body: DocumentUpdateBody(
                baseUpdatedAt: "stale", title: "New", petIDs: nil))
            Issue.record("Expected ConflictError")
        } catch let conflict as ConflictError<DocumentRecord> {
            #expect(conflict.server == docServer)
        }
    }

    @Test("updatePet recovers a thrown conflict via by-id refetch")
    func updatePetThrownConflictRefetches() async throws {
        let (repo, mock) = wired()
        let server = makePet(updatedAt: "2026-10-26T14:00:00.100Z")
        mock.sendRawHandler = { endpoint in
            if endpoint.method == .patch { throw APIError.server(code: "conflict", message: "stale", details: [:]) }
            return (try JSONEncoder().encode(server), 200)
        }
        do {
            _ = try await repo.updatePet(id: "pet-1", body: PetUpdateBody(baseUpdatedAt: "stale", name: "B", species: "cat", birthdate: nil, notes: ""))
            Issue.record("Expected ConflictError")
        } catch let conflict as ConflictError<PetRecord> {
            #expect(conflict.server == server)
        }
        #expect(mock.received.contains { $0.method == .get && $0.path == "/api/v1/pets/pet-1" })
    }

    @Test("DELETE swallows 204, tuple 404, and thrown not_found across resources")
    func deletesSwallowMissing() async throws {
        let cases: [(String, (SyncRelayRepository) async throws -> Void)] = [
            ("/api/v1/pets/pet-1", { try await $0.deletePet(id: "pet-1") }),
            ("/api/v1/events/event-1", { try await $0.deleteEvent(id: "event-1") }),
            ("/api/v1/intakes/intake-1", { try await $0.deleteIntake(id: "intake-1") }),
            ("/api/v1/documents/doc-1", { try await $0.deleteDocument(id: "doc-1") }),
        ]
        for (path, action) in cases {
            for status in [204, 404] {
                let (repo, mock) = wired()
                mock.sendRawHandler = { _ in (Data(), status) }
                try await action(repo)
                #expect(mock.received.first?.path == path)
            }
        }
        let (repo, mock) = wired()
        mock.sendRawHandler = { _ in throw APIError.server(code: "not_found", message: "gone", details: [:]) }
        try await repo.deletePet(id: "pet-1")
        #expect(mock.received.first?.requiresAuth == true)
    }

    @Test("listEvents filters by pet and decodes nested details")
    func listEventsNestedDetail() async throws {
        let (repo, mock) = wired()
        mock.sendRawHandler = { _ in
            (try JSONEncoder().encode(EventListResponse(events: [try makeEvent()], cursor: "e1")), 200)
        }
        let result = try await repo.listEvents(since: "2026-10-26T12:00:00.100Z", petID: "pet-1")
        #expect(result.cursor == "e1" && result.events[0].weight?.grams == 4200)
        let received = try #require(mock.received.first)
        #expect(received.path.contains("pet_id=pet-1") && received.path.contains("modified_since="))
        _ = try await repo.listEvents(since: nil, petID: nil)
        #expect(mock.received.last?.path == "/api/v1/events")
    }

    @Test("createEvent sends flat details matching EventInput")
    func createEventFlatBody() async throws {
        let (repo, mock) = wired()
        let event = try makeEvent()
        mock.sendRawHandler = { _ in (try JSONEncoder().encode(event), 201) }
        #expect(try await repo.createEvent(event).weight?.grams == 4200)
        let sent = try JSONSerialization.jsonObject(with: try #require(mock.received.first?.body))
            as? [String: Any]
        #expect(sent?["detail"] == nil)
        #expect((sent?["weight"] as? [String: Any])?["grams"] as? Int == 4200)
    }

    @Test("listIntakes filters by course and decodes")
    func listIntakesCourseFilter() async throws {
        let (repo, mock) = wired()
        mock.sendRawHandler = { _ in
            (try JSONEncoder().encode(IntakeListResponse(intakes: [makeIntake()], cursor: "i1")), 200)
        }
        let result = try await repo.listIntakes(since: "2026-10-26T12:00:00.100Z", courseID: "course-1")
        #expect(result.intakes[0].doseSnapshot == "0.5 tablet")
        let received = try #require(mock.received.first)
        #expect(received.path.contains("course_id=course-1") && received.path.contains("modified_since="))
    }

    @Test("createIntake and updateIntake round-trip")
    func intakeCreateUpdate() async throws {
        let (repo, mock) = wired()
        let intake = makeIntake()
        mock.sendRawHandler = { endpoint in
            (try JSONEncoder().encode(intake), endpoint.method == .post ? 201 : 200)
        }
        #expect(try await repo.createIntake(intake) == intake)
        let updated = try await repo.updateIntake(id: "intake-1", body: IntakeUpdateBody(
            baseUpdatedAt: intake.updatedAt, status: "taken",
            takenAt: "2026-10-26T08:05:00.100Z", note: nil, doseSnapshot: nil))
        #expect(updated == intake)
        #expect(mock.received.map(\.path) == ["/api/v1/intakes", "/api/v1/intakes/intake-1"])
    }

    @Test("createDocument posts and listDocuments decodes")
    func documentsRoundTrip() async throws {
        let (repo, mock) = wired()
        let doc = makeDocument()
        mock.sendRawHandler = { endpoint in
            if endpoint.method == .post { return (try JSONEncoder().encode(doc), 201) }
            return (try JSONEncoder().encode(DocumentListResponse(documents: [doc], cursor: "d1")), 200)
        }
        #expect(try await repo.createDocument(doc) == doc)
        let listed = try await repo.listDocuments(since: nil)
        #expect(listed.documents[0].petIDs == ["pet-1"] && listed.cursor == "d1")
        #expect(mock.received.map(\.path) == ["/api/v1/documents", "/api/v1/documents"])
    }

    @Test("listDeletions uses deleted_since and decodes tombstones")
    func listDeletionsCursor() async throws {
        let (repo, mock) = wired()
        mock.sendRawHandler = { _ in
            let tombstone = TombstoneRecord(resource: "pet", recordID: "pet-9",
                                            deletedAt: "2026-10-26T15:00:00.100Z")
            return (try JSONEncoder().encode(DeletionListResponse(deletions: [tombstone], cursor: "t1")), 200)
        }
        let result = try await repo.listDeletions(since: "2026-10-26T14:00:00.100Z")
        #expect(result.deletions[0].recordID == "pet-9" && result.cursor == "t1")
        let received = try #require(mock.received.first)
        #expect(received.path.contains("deleted_since=") && !received.path.contains("modified_since"))
    }

    @Test("malformed JSON throws a decoding error")
    func invalidJSONThrows() async throws {
        let (repo, mock) = wired()
        mock.sendRawHandler = { _ in (Data("not json".utf8), 200) }
        do {
            _ = try await repo.listPets(since: nil)
            Issue.record("Expected decoding error")
        } catch let api as APIError {
            if case .decoding = api { } else { Issue.record("Wrong error: \(api)") }
        }
    }

    @Test("fetchHousehold hits /mine with auth")
    func fetchHouseholdEndpoint() async throws {
        let (repo, mock) = wired()
        mock.sendRawHandler = { _ in (try JSONEncoder().encode(makeHousehold()), 200) }
        let result = try await repo.fetchHousehold()
        #expect(result.household.id == "hh-1" && result.members.count == 1)
        let received = try #require(mock.received.first)
        #expect(received.method == .get && received.path == "/api/v1/households/mine" && received.requiresAuth)
    }
}
