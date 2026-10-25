import Testing
import Foundation
@testable import Shunik

/// Undo-buffer support for Shunik domain records: snapshot payloads carry
/// one JSON-encoded record struct per `DeletionSnapshot.Record`, one
/// buffered deletion enters `undo_buffer` as a single row, and restore /
/// commit move the row without notifying the relay.
///
/// Pre-merge scope: the domain getters (`getPet`/`getEvent`/`getIntake`/
/// `getDocument`), domain tables, and snapshot restore (`applySnapshot`) land
/// in a sibling change, so `bufferDeletion` currently reports every record
/// missing loudly and restore round-trips cover the buffer-row lifecycle
/// only (row enters, row clears) — not domain-row reappearance. The payload
/// shape asserted here is exactly what the sibling's restore path consumes.
@Suite("Undo buffer domain records")
struct UndoBufferDomainTests {

    private func makeStore() throws -> LocalStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = LocalStore.databaseURL(householdID: "undo-domain-u1", in: dir)
        return try LocalStore(url: url, householdID: "undo-domain-u1")
    }

    private func makePet(id: String = "pet-1") -> PetRecord {
        PetRecord(
            id: id, householdID: "hh-1", name: "Shunik", species: "cat",
            birthdate: nil, notes: "", createdAt: "2026-10-25T12:00:00.000Z",
            updatedAt: "2026-10-25T12:00:00.000Z", updatedBy: "u1"
        )
    }

    private func makeIntake(id: String = "intake-1") -> IntakeRecord {
        IntakeRecord(
            id: id, householdID: "hh-1", courseID: "event-1", dueAt: nil,
            status: "due", takenAt: nil, doseSnapshot: "0.5", note: "",
            markedBy: "u1", createdAt: "2026-10-25T12:00:00.000Z",
            updatedAt: "2026-10-25T12:00:00.000Z"
        )
    }

    private func makeDocument(id: String = "doc-1") -> DocumentRecord {
        DocumentRecord(
            id: id, householdID: "hh-1", title: "Vet report", mime: "application/pdf",
            sizeBytes: 42, filename: "report.pdf", blobKey: "k1", ready: true,
            extractedText: "", petIDs: ["pet-1"],
            createdAt: "2026-10-25T12:00:00.000Z", updatedAt: "2026-10-25T12:00:00.000Z",
            updatedBy: "u1"
        )
    }

    private func makeEventJSON(id: String = "event-1") -> Data {
        let json = "{\"id\":\"\(id)\",\"household_id\":\"hh-1\"," +
            "\"pet_id\":\"pet-1\",\"kind\":\"weight\"," +
            "\"occurred_at\":\"2026-10-25T12:00:00.000Z\"," +
            "\"title\":\"Weigh-in\",\"weight\":{\"grams\":4200}," +
            "\"updated_at\":\"2026-10-25T12:00:00.000Z\"}"
        return Data(json.utf8)
    }

    @Test("snapshot payload decodes back to equal structs per resource")
    func snapshotPayloadRoundTripsPerResource() throws {
        let event = try JSONDecoder().decode(EventRecord.self, from: makeEventJSON())
        #expect(event.weight == WeightDetail(grams: 4200))
        let snapshotRecords = try [
            DeletionSnapshot.Record(
                resource: SyncResource.pet.rawValue, recordID: "pet-1",
                data: JSONEncoder().encode(makePet())),
            DeletionSnapshot.Record(
                resource: SyncResource.event.rawValue, recordID: "event-1",
                data: JSONEncoder().encode(event)),
            DeletionSnapshot.Record(
                resource: SyncResource.intake.rawValue, recordID: "intake-1",
                data: JSONEncoder().encode(makeIntake())),
            DeletionSnapshot.Record(
                resource: SyncResource.document.rawValue, recordID: "doc-1",
                data: JSONEncoder().encode(makeDocument())),
        ]
        let payload = try JSONEncoder().encode(DeletionSnapshot(records: snapshotRecords))
        let decoded = try JSONDecoder().decode(DeletionSnapshot.self, from: payload)
        #expect(decoded == DeletionSnapshot(records: snapshotRecords))
        #expect(try JSONDecoder().decode(PetRecord.self, from: decoded.records[0].data) == makePet())
        #expect(try JSONDecoder().decode(EventRecord.self, from: decoded.records[1].data) == event)
        #expect(try JSONDecoder().decode(IntakeRecord.self, from: decoded.records[2].data) == makeIntake())
        #expect(try JSONDecoder().decode(DocumentRecord.self, from: decoded.records[3].data) == makeDocument())
    }

    @Test("bufferDeletion throws recordMissing and buffers nothing")
    func bufferDeletionRejectsMissingRecord() async throws {
        let store = try makeStore()
        let buffer = UndoBufferStore(store: store)
        do {
            try await buffer.bufferDeletion(of: [(resource: .pet, id: "no-such-pet")])
            Issue.record("expected recordMissing")
        } catch let error as UndoBufferDomainError {
            #expect(error == .recordMissing(resource: "pet", id: "no-such-pet"))
        }
        #expect(try await store.isBufferedForDeletion(resource: "pet", recordID: "no-such-pet") == false)
        #expect(try await store.undoBufferMostRecent() == nil)
    }

    @Test("bufferDeletion with several records buffers nothing when one is missing")
    func bufferDeletionBuffersNothingPartially() async throws {
        let store = try makeStore()
        let buffer = UndoBufferStore(store: store)
        do {
            try await buffer.bufferDeletion(of: [
                (resource: .pet, id: "pet-1"),
                (resource: .event, id: "event-1"),
            ])
            Issue.record("expected recordMissing")
        } catch let error as UndoBufferDomainError {
            #expect(error == .recordMissing(resource: "pet", id: "pet-1"))
        }
        #expect(try await store.isBufferedForDeletion(resource: "pet", recordID: "pet-1") == false)
        #expect(try await store.isBufferedForDeletion(resource: "event", recordID: "event-1") == false)
    }

    @Test("multiple snapshot records share one buffer row")
    func multipleRecordsShareOneBufferRow() async throws {
        let store = try makeStore()
        let buffer = UndoBufferStore(store: store)
        let snapshot = DeletionSnapshot(records: [
            DeletionSnapshot.Record(
                resource: SyncResource.pet.rawValue, recordID: "pet-1",
                data: try JSONEncoder().encode(makePet())),
            DeletionSnapshot.Record(
                resource: SyncResource.intake.rawValue, recordID: "intake-1",
                data: try JSONEncoder().encode(makeIntake())),
        ])
        try await buffer.enter(payload: JSONEncoder().encode(snapshot))
        let row = try await store.undoBufferMostRecent()
        #expect(row != nil)
        #expect(try await store.bufferedDeletions().count == 2)
        #expect(try JSONDecoder().decode(
            DeletionSnapshot.self, from: Data(row!.payload.utf8)) == snapshot)
    }

    @Test("buffered deletion fences pulls until commit, then enqueues a delete")
    func bufferedDeletionFencesUntilCommit() async throws {
        let store = try makeStore()
        let buffer = UndoBufferStore(store: store)
        let snapshot = DeletionSnapshot(records: [
            DeletionSnapshot.Record(
                resource: SyncResource.document.rawValue, recordID: "doc-1",
                data: try JSONEncoder().encode(makeDocument())),
        ])
        try await buffer.enter(payload: JSONEncoder().encode(snapshot))
        #expect(try await store.isBufferedForDeletion(resource: "document", recordID: "doc-1") == true)
        try await buffer.commitAll()
        #expect(try await store.isBufferedForDeletion(resource: "document", recordID: "doc-1") == false)
        let deletions = try await store.outboxRows().filter { $0.op == "delete" }
        #expect(deletions.count == 1)
        #expect(deletions[0].resource == "document")
        #expect(deletions[0].recordID == "doc-1")
    }

    @Test("restore clears the buffer row; domain-row reappearance awaits sibling tables")
    func restoreClearsBufferRow() async throws {
        let store = try makeStore()
        let buffer = UndoBufferStore(store: store)
        let snapshot = DeletionSnapshot(records: [
            DeletionSnapshot.Record(
                resource: SyncResource.pet.rawValue, recordID: "pet-1",
                data: try JSONEncoder().encode(makePet())),
        ])
        try await buffer.enter(payload: JSONEncoder().encode(snapshot))
        let row = try await buffer.mostRecent()
        #expect(row != nil)
        // Domain-row reappearance on undo awaits the sibling change (domain
        // tables + applySnapshot); the buffer-row lifecycle is verifiable now.
        try await buffer.undo(id: row!.id)
        #expect(try await buffer.mostRecent() == nil)
        #expect(try await store.isBufferedForDeletion(resource: "pet", recordID: "pet-1") == false)
    }

    @Test("restore refuses while a buffered-deletion push is in flight")
    func restoreRefusesWhilePushInFlight() async throws {
        let store = try makeStore()
        let buffer = UndoBufferStore(store: store)
        let snapshot = DeletionSnapshot(records: [
            DeletionSnapshot.Record(
                resource: SyncResource.pet.rawValue, recordID: "pet-1",
                data: try JSONEncoder().encode(makePet())),
        ])
        try await buffer.enter(payload: JSONEncoder().encode(snapshot))
        let row = try await buffer.mostRecent()
        await store.setUndoPushInFlight(true)
        defer {
            Task { await store.setUndoPushInFlight(false) }
        }
        do {
            try await buffer.undo(id: row!.id)
            Issue.record("expected pushInFlight")
        } catch let error as UndoError {
            #expect(error == .pushInFlight)
        }
        await store.setUndoPushInFlight(false)
        try await buffer.undo(id: row!.id)
        #expect(try await buffer.mostRecent() == nil)
    }
}
