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

    /// Commits every buffered row: deletes each buffer row and inserts
    /// the outbox rows for the deletion in one transaction. Called on
    /// cold launch (an app restart finalizes whatever is still buffered),
    /// never while the process is alive.
    func commitAll() async throws {
        try await store.undoBufferCommitAll()
    }
}
