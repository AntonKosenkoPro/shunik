// swiftlint:disable file_length
import Testing
import Foundation
@testable import Shunik

/// Shunik v1 domain persistence in `LocalStore` (pets, events, intakes,
/// documents): CRUD + outbox payloads, base-guarded updates, pull-merge
/// upserts (LWW + normalization + delete-wins), tombstones, undo snapshots,
/// and household file binding.
@Suite("LocalStore domain")
struct LocalStoreDomainTests {

    private func tempStore() throws -> LocalStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("test.db")
        return try LocalStore(url: url)
    }

    private func tempBase() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func samplePet(
        id: String = "pet-1",
        updatedAt: String = "2026-10-26T12:00:00.000Z"
    ) -> PetRecord {
        PetRecord(
            id: id, householdID: "hh-1", name: "Barsik", species: "cat",
            birthdate: "2020-05-01", notes: "notes",
            createdAt: "2026-10-26T11:00:00.000Z",
            updatedAt: updatedAt, updatedBy: "u1"
        )
    }

    private func decodeEvent(_ json: String) -> EventRecord {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(EventRecord.self, from: Data(json.utf8))
    }

    private func vaccEventJSON(id: String, updatedAt: String) -> String {
        "{\"id\":\"\(id)\",\"household_id\":\"hh-1\",\"pet_id\":\"pet-1\"," +
        "\"kind\":\"vaccination\",\"occurred_at\":\"2026-10-26T12:00:00.000Z\"," +
        "\"title\":\"Rabies\"," +
        "\"detail\":{\"vaccination\":{\"vaccine\":\"Rabies\",\"batch\":\"B1\",\"vet\":\"Doc\",\"notes\":\"ok\"}}," +
        "\"created_at\":\"2026-10-26T11:00:00.000Z\",\"updated_at\":\"\(updatedAt)\",\"updated_by\":\"u1\"}"
    }

    private func groomEventJSON(id: String) -> String {
        "{\"id\":\"\(id)\",\"household_id\":\"hh-1\",\"pet_id\":\"pet-1\"," +
        "\"kind\":\"grooming\",\"occurred_at\":\"2026-10-25T12:00:00.000Z\"," +
        "\"title\":\"Haircut\"," +
        "\"detail\":{\"grooming\":{\"service\":\"cut\",\"place\":\"Salon\",\"notes\":\"\"}}," +
        "\"created_at\":\"2026-10-26T11:00:00.000Z\",\"updated_at\":\"2026-10-26T12:00:00.000Z\",\"updated_by\":\"u1\"}"
    }

    private func weightEventJSON(id: String) -> String {
        "{\"id\":\"\(id)\",\"household_id\":\"hh-1\",\"pet_id\":\"pet-1\"," +
        "\"kind\":\"weight\",\"occurred_at\":\"2026-10-24T12:00:00.000Z\"," +
        "\"title\":\"Weigh-in\",\"detail\":{\"weight\":{\"grams\":5200}}," +
        "\"created_at\":\"2026-10-26T11:00:00.000Z\",\"updated_at\":\"2026-10-26T12:00:00.000Z\",\"updated_by\":\"u1\"}"
    }

    private func courseEventJSON(id: String) -> String {
        "{\"id\":\"\(id)\",\"household_id\":\"hh-1\",\"pet_id\":\"pet-1\"," +
        "\"kind\":\"medication\",\"occurred_at\":\"2026-10-23T12:00:00.000Z\"," +
        "\"title\":\"Antibiotics\"," +
        "\"detail\":{\"course\":{\"drug_name\":\"Amox\",\"dose_amount\":\"0.5\",\"dose_unit\":\"tab\"," +
        "\"route\":\"oral\",\"schedule_kind\":\"daily\",\"schedule_times\":\"08:00\",\"schedule_weekdays\":\"\"," +
        "\"duration_days\":7,\"status\":\"active\",\"instructions\":\"with food\",\"info_ref\":\"\"}}," +
        "\"created_at\":\"2026-10-26T11:00:00.000Z\",\"updated_at\":\"2026-10-26T12:00:00.000Z\",\"updated_by\":\"u1\"}"
    }

    private func sampleIntake(
        id: String = "int-1",
        courseID: String = "ev-course-1",
        dueAt: String? = "2026-10-26T08:00:00.000Z",
        updatedAt: String = "2026-10-26T12:00:00.000Z"
    ) -> IntakeRecord {
        IntakeRecord(
            id: id, householdID: "hh-1", courseID: courseID, dueAt: dueAt,
            status: "due", takenAt: nil, doseSnapshot: "0.5 tab", note: "",
            markedBy: "u1",
            createdAt: "2026-10-26T11:00:00.000Z", updatedAt: updatedAt
        )
    }

    private func sampleDocument(
        id: String = "doc-1",
        petIDs: [String] = ["pet-1"],
        updatedAt: String = "2026-10-26T12:00:00.000Z"
    ) -> DocumentRecord {
        DocumentRecord(
            id: id, householdID: "hh-1", title: "Passport",
            mime: "application/pdf", sizeBytes: 42,
            filename: "passport.pdf", blobKey: "blob-1",
            ready: true, extractedText: "", petIDs: petIDs,
            createdAt: "2026-10-26T11:00:00.000Z",
            updatedAt: updatedAt, updatedBy: "u1"
        )
    }

    private func outbox(
        resource: String,
        op: String,
        in store: LocalStore
    ) async throws -> [OutboxRow] {
        try await store.outboxRows().filter { $0.resource == resource && $0.op == op }
    }

    // MARK: - Household binding

    @Test("household file naming")
    func householdFileNaming() {
        #expect(LocalStore.databaseFileName(householdID: "hh-1") == "shunik_hh-1.db")
        #expect(LocalStore.databaseURL(householdID: "hh-1").lastPathComponent == "shunik_hh-1.db")
    }

    @Test("openHousehold binds and serves the household file")
    func openHouseholdBinds() async throws {
        let base = try tempBase()
        let store = LocalStore()
        try await store.openHousehold(householdID: "hh-bind-1", in: base)
        #expect(await store.boundHouseholdID == "hh-bind-1")
        let created = try await store.createPet(samplePet(), updatedBy: "u1")
        let fetched = try #require(await store.getPet(id: created.id))
        #expect(fetched == created)
        #expect(FileManager.default.fileExists(
            atPath: LocalStore.databaseURL(householdID: "hh-bind-1", in: base).path
        ))
    }

    @Test("openHousehold rejects a file bound to another household")
    func openHouseholdRejectsForeignMarker() async throws {
        let base = try tempBase()
        let first = LocalStore()
        try await first.openHousehold(householdID: "hh-a", in: base)
        let urlA = LocalStore.databaseURL(householdID: "hh-a", in: base)
        let urlB = LocalStore.databaseURL(householdID: "hh-b", in: base)
        try FileManager.default.copyItem(at: urlA, to: urlB)
        let second = LocalStore()
        do {
            try await second.openHousehold(householdID: "hh-b", in: base)
            Issue.record("expected accountMismatch")
        } catch let error as LocalStore.LocalStoreError {
            #expect(error == .accountMismatch)
        }
        #expect(await second.boundHouseholdID == nil)
    }

    @Test("openHousehold rejects unsafe ids")
    func openHouseholdRejectsInvalidID() async {
        let store = LocalStore()
        do {
            try await store.openHousehold(householdID: "../escape")
            Issue.record("expected invalidUserID")
        } catch let error as LocalStore.LocalStoreError {
            #expect(error == .invalidUserID)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    // MARK: - Pets

    @Test("createPet stores the row and a parseable create payload")
    func createPet() async throws {
        let store = try tempStore()
        let stored = try await store.createPet(samplePet(), updatedBy: "u1")
        #expect(!stored.id.isEmpty)
        let fetched = try #require(await store.getPet(id: stored.id))
        #expect(fetched == stored)
        #expect(fetched.updatedBy == "u1")
        let rows = try await outbox(resource: "pet", op: "create", in: store)
        #expect(rows.count == 1)
        let payload = try #require(rows.first?.payload)
        let decoded = try JSONDecoder().decode(PetRecord.self, from: Data(payload.utf8))
        #expect(decoded == stored)
    }

    @Test("createPet keeps explicit ids and generates only empty ones")
    func createPetIDs() async throws {
        let store = try tempStore()
        let explicit = try await store.createPet(samplePet(id: "client-uuid-1"), updatedBy: "u1")
        #expect(explicit.id == "client-uuid-1")
        var empty = samplePet()
        empty.id = ""
        let generated = try await store.createPet(empty, updatedBy: "u1")
        #expect(!generated.id.isEmpty)
    }

    @Test("updatePet applies on base match with an update-body payload")
    func updatePetMatch() async throws {
        let store = try tempStore()
        let stored = try await store.createPet(samplePet(), updatedBy: "u1")
        var changed = stored
        changed.name = "Murzik"
        let updated = try await store.updatePet(changed, baseUpdatedAt: stored.updatedAt, updatedBy: "u2")
        #expect(updated.name == "Murzik")
        #expect(updated.updatedBy == "u2")
        let fetched = try #require(await store.getPet(id: stored.id))
        #expect(fetched == updated)
        let rows = try await outbox(resource: "pet", op: "update", in: store)
        #expect(rows.count == 1)
        let payload = try #require(rows.first?.payload)
        let body = try JSONDecoder().decode(PetUpdateBody.self, from: Data(payload.utf8))
        #expect(body.baseUpdatedAt == stored.updatedAt)
        #expect(body.name == "Murzik")
    }

    @Test("updatePet mismatch changes nothing and writes no outbox row")
    func updatePetMismatch() async throws {
        let store = try tempStore()
        let stored = try await store.createPet(samplePet(), updatedBy: "u1")
        let before = try await store.outboxRows()
        var changed = stored
        changed.name = "Murzik"
        do {
            _ = try await store.updatePet(changed, baseUpdatedAt: "2020-01-01T00:00:00.000Z", updatedBy: "u2")
            Issue.record("expected staleBase")
        } catch let error as LocalStore.LocalStoreError {
            #expect(error == .staleBase)
        }
        #expect(try await store.getPet(id: stored.id) == stored)
        #expect(try await store.outboxRows() == before)
    }

    @Test("removePetLocal writes no outbox row, deletePet writes one")
    func removeAndDeletePet() async throws {
        let store = try tempStore()
        let stored = try await store.createPet(samplePet(), updatedBy: "u1")
        try await store.removePetLocal(id: stored.id)
        #expect(try await store.getPet(id: stored.id) == nil)
        #expect(try await outbox(resource: "pet", op: "delete", in: store).isEmpty)

        let second = try await store.createPet(samplePet(id: "pet-2"), updatedBy: "u1")
        try await store.deletePet(id: second.id, updatedBy: "u1")
        #expect(try await store.getPet(id: second.id) == nil)
        let deletes = try await outbox(resource: "pet", op: "delete", in: store)
        #expect(deletes.count == 1)
        #expect(deletes.first?.recordID == second.id)
        #expect(deletes.first?.payload == nil)
    }

    @Test("upsertPet replaces only on newer server updated_at")
    func upsertPetNewerOlder() async throws {
        let store = try tempStore()
        _ = try await store.createPet(samplePet(), updatedBy: "u1")
        var older = samplePet()
        older.name = "Stale"
        older.updatedAt = "2020-01-01T00:00:00.000Z"
        try await store.upsertPet(older)
        #expect(try #require(await store.getPet(id: "pet-1")).name == "Barsik")

        var newer = samplePet()
        newer.name = "Fresh"
        newer.updatedAt = "2030-01-01T00:00:00.000Z"
        try await store.upsertPet(newer)
        let fetched = try #require(await store.getPet(id: "pet-1"))
        #expect(fetched.name == "Fresh")
        #expect(fetched.updatedAt == "2030-01-01T00:00:00.000Z")
        // Upserts never enqueue: only the initial create row remains.
        #expect(try await store.outboxRows().count == 1)
    }

    @Test("upsertPet normalizes nano timestamps and skips equal instants")
    func upsertPetNormalization() async throws {
        let store = try tempStore()
        var nano = samplePet(id: "pet-nano")
        nano.updatedAt = "2026-10-26T12:00:00.123456789Z"
        try await store.upsertPet(nano)
        #expect(try #require(await store.getPet(id: "pet-nano")).updatedAt == "2026-10-26T12:00:00.123Z")

        // Same instant in ms form, different content: equal → no replace.
        var equal = samplePet(id: "pet-nano")
        equal.name = "Changed"
        equal.updatedAt = "2026-10-26T12:00:00.123Z"
        try await store.upsertPet(equal)
        let fetched = try #require(await store.getPet(id: "pet-nano"))
        #expect(fetched.updatedAt == "2026-10-26T12:00:00.123Z")
        #expect(fetched.name == "Barsik")
    }

    @Test("upsertPet skips locally-deleted rows (delete-wins)")
    func upsertPetSkipsLocalDelete() async throws {
        let store = try tempStore()
        _ = try await store.createPet(samplePet(), updatedBy: "u1")
        try await store.deletePet(id: "pet-1", updatedBy: "u1")
        var newer = samplePet()
        newer.name = "Resurrected"
        newer.updatedAt = "2030-01-01T00:00:00.000Z"
        try await store.upsertPet(newer)
        #expect(try await store.getPet(id: "pet-1") == nil)
    }

    // MARK: - Events

    @Test("createEvent stores each kind detail with a parseable payload")
    func createEvents() async throws {
        let store = try tempStore()
        let vacc = try await store.createEvent(decodeEvent(vaccEventJSON(id: "ev-1", updatedAt: "x")), updatedBy: "u1")
        #expect(vacc.vaccination?.vaccine == "Rabies")
        #expect(vacc.grooming == nil)
        let fetched = try #require(await store.getEvent(id: vacc.id))
        #expect(fetched == vacc)
        let payload = try #require(try await outbox(resource: "event", op: "create", in: store).first?.payload)
        #expect(try JSONDecoder().decode(EventRecord.self, from: Data(payload.utf8)) == vacc)

        let groom = try await store.createEvent(decodeEvent(groomEventJSON(id: "ev-2")), updatedBy: "u1")
        #expect(try #require(await store.getEvent(id: groom.id)).grooming?.service == "cut")
        let weight = try await store.createEvent(decodeEvent(weightEventJSON(id: "ev-3")), updatedBy: "u1")
        #expect(try #require(await store.getEvent(id: weight.id)).weight?.grams == 5200)
        let course = try await store.createEvent(decodeEvent(courseEventJSON(id: "ev-4")), updatedBy: "u1")
        #expect(try #require(await store.getEvent(id: course.id)).course?.drugName == "Amox")

        let timeline = try await store.listEvents(petID: "pet-1")
        #expect(timeline.count == 4)
        // Newest first: vaccination (10-26) before grooming (10-25).
        #expect(timeline.first?.id == vacc.id)
    }

    @Test("updateEvent replaces the detail on base match, refuses mismatch")
    func updateEventMatchMismatch() async throws {
        let store = try tempStore()
        let stored = try await store.createEvent(
            decodeEvent(vaccEventJSON(id: "ev-1", updatedAt: "2026-10-26T12:00:00.000Z")),
            updatedBy: "u1"
        )
        var changed = stored
        changed.title = "Rabies booster"
        changed.vaccination = VaccDetail(vaccine: "Rabies", batch: "B2", vet: "Doc", notes: "booster")
        let updated = try await store.updateEvent(changed, baseUpdatedAt: stored.updatedAt, updatedBy: "u2")
        let fetched = try #require(await store.getEvent(id: stored.id))
        #expect(fetched == updated)
        #expect(fetched.vaccination?.batch == "B2")
        let payload = try #require(try await outbox(resource: "event", op: "update", in: store).first?.payload)
        let body = try JSONDecoder().decode(EventUpdateBody.self, from: Data(payload.utf8))
        #expect(body.baseUpdatedAt == stored.updatedAt)
        #expect(body.petID == "pet-1")
        #expect(body.vaccination?.batch == "B2")

        let before = try await store.outboxRows()
        var stale = stored
        stale.title = "Stale"
        do {
            _ = try await store.updateEvent(stale, baseUpdatedAt: "2020-01-01T00:00:00.000Z", updatedBy: "u2")
            Issue.record("expected staleBase")
        } catch let error as LocalStore.LocalStoreError {
            #expect(error == .staleBase)
        }
        #expect(try await store.getEvent(id: stored.id) == updated)
        #expect(try await store.outboxRows() == before)
    }

    @Test("removeEventLocal and deleteEvent mirror the pet paths")
    func removeAndDeleteEvent() async throws {
        let store = try tempStore()
        let first = try await store.createEvent(
            decodeEvent(vaccEventJSON(id: "ev-1", updatedAt: "2026-10-26T12:00:00.000Z")),
            updatedBy: "u1"
        )
        try await store.removeEventLocal(id: first.id)
        #expect(try await store.getEvent(id: first.id) == nil)
        #expect(try await outbox(resource: "event", op: "delete", in: store).isEmpty)

        let second = try await store.createEvent(
            decodeEvent(vaccEventJSON(id: "ev-2", updatedAt: "2026-10-26T12:00:00.000Z")),
            updatedBy: "u1"
        )
        try await store.deleteEvent(id: second.id, updatedBy: "u1")
        let deletes = try await outbox(resource: "event", op: "delete", in: store)
        #expect(deletes.count == 1)
        #expect(deletes.first?.payload == nil)
    }

    @Test("upsertEvent merges newer, ignores older, skips deleted")
    func upsertEvent() async throws {
        let store = try tempStore()
        _ = try await store.createEvent(
            decodeEvent(vaccEventJSON(id: "ev-1", updatedAt: "2026-10-26T12:00:00.000Z")),
            updatedBy: "u1"
        )
        var older = decodeEvent(vaccEventJSON(id: "ev-1", updatedAt: "2020-01-01T00:00:00.000Z"))
        older.title = "Stale"
        try await store.upsertEvent(older)
        #expect(try #require(await store.getEvent(id: "ev-1")).title == "Rabies")

        var newer = decodeEvent(vaccEventJSON(id: "ev-1", updatedAt: "2030-01-01T00:00:00.000Z"))
        newer.title = "Fresh"
        newer.vaccination = VaccDetail(vaccine: "Rabies", batch: "B9", vet: "Doc", notes: "")
        try await store.upsertEvent(newer)
        let fetched = try #require(await store.getEvent(id: "ev-1"))
        #expect(fetched.title == "Fresh")
        #expect(fetched.vaccination?.batch == "B9")

        try await store.deleteEvent(id: "ev-1", updatedBy: "u1")
        try await store.upsertEvent(newer)
        #expect(try await store.getEvent(id: "ev-1") == nil)
        #expect(try await store.outboxRows().count == 2)
    }

    // MARK: - Intakes

    @Test("createIntake and updateIntake round-trip with update-body payload")
    func createAndUpdateIntake() async throws {
        let store = try tempStore()
        let stored = try await store.createIntake(sampleIntake(), markedBy: "u1")
        #expect(stored.markedBy == "u1")
        let fetched = try #require(await store.getIntake(id: stored.id))
        #expect(fetched == stored)
        let payload = try #require(try await outbox(resource: "intake", op: "create", in: store).first?.payload)
        #expect(try JSONDecoder().decode(IntakeRecord.self, from: Data(payload.utf8)) == stored)

        var changed = stored
        changed.status = "taken"
        changed.takenAt = "2026-10-26T08:05:00.000Z"
        changed.note = "with food"
        let updated = try await store.updateIntake(changed, baseUpdatedAt: stored.updatedAt, markedBy: "u2")
        #expect(updated.status == "taken")
        #expect(updated.markedBy == "u2")
        #expect(try #require(await store.getIntake(id: stored.id)) == updated)
        let updatePayload = try #require(
            try await outbox(resource: "intake", op: "update", in: store).first?.payload
        )
        let body = try JSONDecoder().decode(IntakeUpdateBody.self, from: Data(updatePayload.utf8))
        #expect(body.baseUpdatedAt == stored.updatedAt)
        #expect(body.status == "taken")

        let before = try await store.outboxRows()
        do {
            _ = try await store.updateIntake(changed, baseUpdatedAt: "2020-01-01T00:00:00.000Z", markedBy: "u2")
            Issue.record("expected staleBase")
        } catch let error as LocalStore.LocalStoreError {
            #expect(error == .staleBase)
        }
        #expect(try await store.outboxRows() == before)
    }

    @Test("intake updatedBy aliases map to markedBy")
    func intakeAliases() async throws {
        let store = try tempStore()
        let stored = try await store.createIntake(sampleIntake(id: "int-alias"), updatedBy: "u1")
        #expect(stored.markedBy == "u1")
        var changed = stored
        changed.status = "taken"
        let updated = try await store.updateIntake(changed, baseUpdatedAt: stored.updatedAt, updatedBy: "u2")
        #expect(updated.markedBy == "u2")
        try await store.deleteIntake(id: stored.id, updatedBy: "u2")
        #expect(try await store.getIntake(id: stored.id) == nil)
        #expect(try await outbox(resource: "intake", op: "delete", in: store).count == 1)
    }

    @Test("intakes list per course, remove/delete mirror the pet paths")
    func listRemoveDeleteIntake() async throws {
        let store = try tempStore()
        _ = try await store.createIntake(sampleIntake(id: "int-1", courseID: "c-1"), markedBy: "u1")
        var second = sampleIntake(id: "int-2", courseID: "c-1")
        second.dueAt = nil
        _ = try await store.createIntake(second, markedBy: "u1")
        _ = try await store.createIntake(sampleIntake(id: "int-3", courseID: "c-2"), markedBy: "u1")
        let listed = try await store.listIntakes(courseID: "c-1")
        #expect(listed.map(\.id) == ["int-1", "int-2"])

        try await store.removeIntakeLocal(id: "int-1")
        #expect(try await store.getIntake(id: "int-1") == nil)
        #expect(try await outbox(resource: "intake", op: "delete", in: store).isEmpty)
        try await store.deleteIntake(id: "int-2", markedBy: "u1")
        #expect(try await outbox(resource: "intake", op: "delete", in: store).count == 1)
    }

    @Test("upsertIntake merges newer, ignores older, skips deleted")
    func upsertIntake() async throws {
        let store = try tempStore()
        _ = try await store.createIntake(sampleIntake(), markedBy: "u1")
        var older = sampleIntake()
        older.status = "stale"
        older.updatedAt = "2020-01-01T00:00:00.000Z"
        try await store.upsertIntake(older)
        #expect(try #require(await store.getIntake(id: "int-1")).status == "due")

        var newer = sampleIntake()
        newer.status = "taken"
        newer.takenAt = "2026-10-26T08:05:00.000Z"
        newer.updatedAt = "2030-01-01T00:00:00.000Z"
        try await store.upsertIntake(newer)
        #expect(try #require(await store.getIntake(id: "int-1")).status == "taken")

        try await store.deleteIntake(id: "int-1", markedBy: "u1")
        try await store.upsertIntake(newer)
        #expect(try await store.getIntake(id: "int-1") == nil)
    }

    // MARK: - Documents

    @Test("createDocument stores links with a parseable payload")
    func createDocument() async throws {
        let store = try tempStore()
        let stored = try await store.createDocument(
            sampleDocument(petIDs: ["pet-1", "pet-2"]), updatedBy: "u1"
        )
        let fetched = try #require(await store.getDocument(id: stored.id))
        #expect(fetched.petIDs == ["pet-1", "pet-2"])
        #expect(fetched == stored)
        let payload = try #require(
            try await outbox(resource: "document", op: "create", in: store).first?.payload
        )
        #expect(try JSONDecoder().decode(DocumentRecord.self, from: Data(payload.utf8)) == stored)
    }

    @Test("updateDocument replaces the link set wholesale")
    func updateDocument() async throws {
        let store = try tempStore()
        let stored = try await store.createDocument(
            sampleDocument(petIDs: ["pet-1", "pet-2"]), updatedBy: "u1"
        )
        var changed = stored
        changed.title = "Vet report"
        changed.petIDs = ["pet-3"]
        let updated = try await store.updateDocument(
            changed, baseUpdatedAt: stored.updatedAt, updatedBy: "u2"
        )
        let fetched = try #require(await store.getDocument(id: stored.id))
        #expect(fetched == updated)
        #expect(fetched.petIDs == ["pet-3"])
        #expect(fetched.mime == "application/pdf")
        let payload = try #require(
            try await outbox(resource: "document", op: "update", in: store).first?.payload
        )
        let body = try JSONDecoder().decode(DocumentUpdateBody.self, from: Data(payload.utf8))
        #expect(body.baseUpdatedAt == stored.updatedAt)
        #expect(body.title == "Vet report")
        #expect(body.petIDs == ["pet-3"])

        do {
            _ = try await store.updateDocument(changed, baseUpdatedAt: "2020-01-01T00:00:00.000Z", updatedBy: "u2")
            Issue.record("expected staleBase")
        } catch let error as LocalStore.LocalStoreError {
            #expect(error == .staleBase)
        }
        #expect(try await store.getDocument(id: stored.id) == updated)
    }

    @Test("removeDocumentLocal and deleteDocument mirror the pet paths")
    func removeAndDeleteDocument() async throws {
        let store = try tempStore()
        let first = try await store.createDocument(sampleDocument(id: "doc-1"), updatedBy: "u1")
        try await store.removeDocumentLocal(id: first.id)
        #expect(try await store.getDocument(id: first.id) == nil)
        #expect(try await outbox(resource: "document", op: "delete", in: store).isEmpty)
        let second = try await store.createDocument(sampleDocument(id: "doc-2"), updatedBy: "u1")
        try await store.deleteDocument(id: second.id, updatedBy: "u1")
        let deletes = try await outbox(resource: "document", op: "delete", in: store)
        #expect(deletes.count == 1)
        #expect(deletes.first?.payload == nil)
        #expect(try await store.listDocuments().isEmpty)
    }

    @Test("upsertDocument replaces row and links on newer, skips otherwise")
    func upsertDocument() async throws {
        let store = try tempStore()
        _ = try await store.createDocument(sampleDocument(petIDs: ["pet-1"]), updatedBy: "u1")
        var older = sampleDocument(petIDs: ["pet-9"])
        older.updatedAt = "2020-01-01T00:00:00.000Z"
        try await store.upsertDocument(older)
        #expect(try #require(await store.getDocument(id: "doc-1")).petIDs == ["pet-1"])

        var newer = sampleDocument(petIDs: ["pet-2", "pet-3"])
        newer.title = "Fresh"
        newer.updatedAt = "2030-01-01T00:00:00.000Z"
        try await store.upsertDocument(newer)
        let fetched = try #require(await store.getDocument(id: "doc-1"))
        #expect(fetched.title == "Fresh")
        #expect(fetched.petIDs == ["pet-2", "pet-3"])

        try await store.deleteDocument(id: "doc-1", updatedBy: "u1")
        try await store.upsertDocument(newer)
        #expect(try await store.getDocument(id: "doc-1") == nil)
    }

    // MARK: - Tombstones

    @Test("applyDeletions removes each resource without outbox rows")
    func applyDeletions() async throws {
        let store = try tempStore()
        let pet = try await store.createPet(samplePet(), updatedBy: "u1")
        let event = try await store.createEvent(
            decodeEvent(vaccEventJSON(id: "ev-1", updatedAt: "2026-10-26T12:00:00.000Z")),
            updatedBy: "u1"
        )
        let intake = try await store.createIntake(sampleIntake(), markedBy: "u1")
        let document = try await store.createDocument(sampleDocument(), updatedBy: "u1")
        let creates = try await store.outboxRows().count
        #expect(creates == 4)

        try await store.applyDeletions([
            TombstoneRecord(resource: "pet", recordID: pet.id, deletedAt: "2026-10-27T00:00:00.000Z"),
            TombstoneRecord(resource: "event", recordID: event.id, deletedAt: "2026-10-27T00:00:00.000Z"),
            TombstoneRecord(resource: "intake", recordID: intake.id, deletedAt: "2026-10-27T00:00:00.000Z"),
            TombstoneRecord(resource: "document", recordID: document.id, deletedAt: "2026-10-27T00:00:00.000Z"),
            TombstoneRecord(resource: "unicorn", recordID: "nope", deletedAt: "2026-10-27T00:00:00.000Z")
        ])
        #expect(try await store.getPet(id: pet.id) == nil)
        #expect(try await store.getEvent(id: event.id) == nil)
        #expect(try await store.getIntake(id: intake.id) == nil)
        #expect(try await store.getDocument(id: document.id) == nil)
        #expect(try await store.outboxRows().count == creates)
    }

    // MARK: - Snapshots

    @Test("applySnapshot restores a pet exactly")
    func snapshotPet() async throws {
        let store = try tempStore()
        let stored = try await store.createPet(samplePet(), updatedBy: "u1")
        let fetched = try #require(await store.getPet(id: stored.id))
        let snapshot = DeletionSnapshot(records: [
            DeletionSnapshot.Record(
                resource: "pet", recordID: stored.id,
                data: try JSONEncoder().encode(fetched)
            )
        ])
        try await store.removePetLocal(id: stored.id)
        #expect(try await store.getPet(id: stored.id) == nil)
        try await store.applySnapshot(snapshot)
        #expect(try await store.getPet(id: stored.id) == fetched)
        #expect(try await store.outboxRows().count == 1)
    }

    @Test("applySnapshot restores an event with its detail")
    func snapshotEvent() async throws {
        let store = try tempStore()
        let stored = try await store.createEvent(
            decodeEvent(courseEventJSON(id: "ev-course-1")),
            updatedBy: "u1"
        )
        let fetched = try #require(await store.getEvent(id: stored.id))
        let snapshot = DeletionSnapshot(records: [
            DeletionSnapshot.Record(
                resource: "event", recordID: stored.id,
                data: try JSONEncoder().encode(fetched)
            )
        ])
        try await store.removeEventLocal(id: stored.id)
        try await store.applySnapshot(snapshot)
        #expect(try await store.getEvent(id: stored.id) == fetched)
    }

    @Test("applySnapshot restores an intake exactly")
    func snapshotIntake() async throws {
        let store = try tempStore()
        let stored = try await store.createIntake(sampleIntake(), markedBy: "u1")
        let fetched = try #require(await store.getIntake(id: stored.id))
        let snapshot = DeletionSnapshot(records: [
            DeletionSnapshot.Record(
                resource: "intake", recordID: stored.id,
                data: try JSONEncoder().encode(fetched)
            )
        ])
        try await store.removeIntakeLocal(id: stored.id)
        try await store.applySnapshot(snapshot)
        #expect(try await store.getIntake(id: stored.id) == fetched)
    }

    @Test("applySnapshot restores a document with its links, skipping unknown")
    func snapshotDocument() async throws {
        let store = try tempStore()
        let stored = try await store.createDocument(
            sampleDocument(petIDs: ["pet-1", "pet-2"]), updatedBy: "u1"
        )
        let fetched = try #require(await store.getDocument(id: stored.id))
        let snapshot = DeletionSnapshot(records: [
            DeletionSnapshot.Record(resource: "unicorn", recordID: "x", data: Data("{}".utf8)),
            DeletionSnapshot.Record(
                resource: "document", recordID: stored.id,
                data: try JSONEncoder().encode(fetched)
            )
        ])
        try await store.removeDocumentLocal(id: stored.id)
        try await store.applySnapshot(snapshot)
        #expect(try await store.getDocument(id: stored.id) == fetched)
    }
}
