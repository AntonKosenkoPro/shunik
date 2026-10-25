import Foundation
import GRDB

/// The durable undo buffer (D3): deletions enter the `undo_buffer` table with
/// a full serialized snapshot of the deleted records; a buffered deletion
/// stays restorable until its relay push succeeds — there is no wall-clock
/// window. No outbox row is created while a deletion is in the buffer — the
/// backend relay is never notified of a deletion that gets undone.
///
/// Buffered rows push on the next sync cycle (push-then-commit) and commit
/// to the outbox on cold launch (`commitAll()`) as the backstop, never
/// while the process is alive otherwise (foreground/background cycles do
/// not expire anything). The buffer survives suspension and backgrounding;
/// a restart finalizes whatever is still buffered.

/// Errors thrown by domain-record buffering (`UndoBufferStore.bufferDeletion`).
enum UndoBufferDomainError: Error, Equatable {
    /// A record named for deletion has no local row. The whole call throws
    /// and nothing enters the buffer — a missing record at delete time is a
    /// logic error the caller must not silently ignore, and a partial
    /// snapshot would restore an incomplete set on undo.
    case recordMissing(resource: String, id: String)
}

actor UndoBufferStore {
    private let store: LocalStore

    init(store: LocalStore) {
        self.store = store
    }

    /// A deletion snapshot held in the buffer.
    struct BufferEntry: Codable, Equatable, Sendable {
        let id: String
        let payload: Data
        let deletedAt: Date
    }

    /// The most recent buffer row (the only one undoable via shake/toast, U7).
    func mostRecent() async throws -> BufferEntry? {
        guard let row = try await store.undoBufferMostRecent() else { return nil }
        return BufferEntry(id: row.id, payload: Data(row.payload.utf8), deletedAt: row.deletedAt)
    }

    /// Enters a pending deletion: inserts the buffer row and deletes the
    /// records in one transaction. No outbox row is created.
    func enter(payload: Data, deletedAt: Date = Date()) async throws {
        try await store.undoBufferEnter(payload: payload, deletedAt: deletedAt)
    }

    /// Undoes a deletion: restores the records from the
    /// payload and deletes the buffer row in one transaction. No outbox row
    /// is ever created, so the relay is never notified of the deletion.
    func undo(id: String) async throws {
        try await store.undoBufferRestore(id: id)
    }

    /// Buffers the deletion of domain records as ONE undoable unit: every
    /// named record's snapshot enters `undo_buffer` in a single row, so one
    /// shake/toast undo restores the whole set together.
    ///
    /// Two-step contract (future UI, §6): call this FIRST, then delete the
    /// rows via `store.remove*Local`. Buffering first means a crash between
    /// the steps leaves the rows present AND restorable — never rows gone
    /// with no undo. No outbox row is created here; the buffered deletion
    /// pushes on the next sync cycle (push-then-commit) and finalizes via
    /// `commitAll()` on cold launch.
    ///
    /// A record with no local row throws `UndoBufferDomainError.recordMissing`
    /// and buffers nothing: partial snapshots never enter the buffer.
    ///
    /// Supersession note: only the most recent buffer row is undoable via
    /// shake/toast (U7). A second buffered deletion supersedes the first for
    /// UI purposes — both rows stay restorable via `undo(id:)` until they
    /// commit, but the toast offers only the newest.
    func bufferDeletion(of records: [(resource: SyncResource, id: String)], deletedAt: Date = Date()) async throws {
        var snapshotRecords: [DeletionSnapshot.Record] = []
        for (resource, id) in records {
            guard let data = try await snapshotData(resource: resource, id: id) else {
                throw UndoBufferDomainError.recordMissing(resource: resource.rawValue, id: id)
            }
            snapshotRecords.append(DeletionSnapshot.Record(resource: resource.rawValue, recordID: id, data: data))
        }
        let payload = try JSONEncoder().encode(DeletionSnapshot(records: snapshotRecords))
        try await store.undoBufferEnter(payload: payload, deletedAt: deletedAt)
    }

    /// JSON snapshot of one local row, or nil when the row does not exist.
    private func snapshotData(resource: SyncResource, id: String) async throws -> Data? {
        switch resource {
        case .pet:
            guard let record = try await store.getPet(id: id) else { return nil }
            return try JSONEncoder().encode(record)
        case .event:
            guard let record = try await store.getEvent(id: id) else { return nil }
            return try JSONEncoder().encode(record)
        case .intake:
            guard let record = try await store.getIntake(id: id) else { return nil }
            return try JSONEncoder().encode(record)
        case .document:
            guard let record = try await store.getDocument(id: id) else { return nil }
            return try JSONEncoder().encode(record)
        }
    }

    /// Commits every buffered row: deletes each buffer row and inserts
    /// the outbox rows for the deletion in one transaction. Called on
    /// cold launch (an app restart finalizes whatever is still buffered),
    /// never while the process is alive.
    func commitAll() async throws {
        try await store.undoBufferCommitAll()
    }
}
