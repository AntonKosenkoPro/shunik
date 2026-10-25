// swiftlint:disable file_length
import Foundation
import GRDB

/// The on-device source of truth (local-first-store spec): one SQLite
/// database file per signed-in account in the App Group shared container,
/// named `shunik_<userId>.db`, that the app, widgets, extensions, and
/// lock-screen Controls all read and write cross-process
/// (account-bound-store spec). Exactly one file is active at a time — the
/// signed-in account's.
///
/// `LocalStore` is the single chokepoint for all mutations: every state
/// change and its outbox row commit in one transaction, so the tables and the
/// "need to push" queue can never drift. No raw GRDB writes are allowed
/// outside this type.
///
/// Lifecycle (account-bound-store spec): the production store starts UNBOUND
/// and binds on sign-in via `openAccount(userID:)` — which opens (creating if
/// needed) that account's file, migrates it, and verifies its per-file
/// account marker. Sign-out calls `closeAccount()`, which closes the file and
/// keeps it on disk (dormant file: dirty outbox and running-timer draft stay
/// put, ready to resume on re-login). Only `eraseAll()` deletes a file — the
/// active account's, on the explicit per-account Erase action.
///
/// The database is opened with `.completeUntilFirstUserAuthentication` (the
/// App Group container default), so it is accessible to `alwaysAllowed`
/// lock-screen Control intents after the device has been unlocked at least
/// once since boot.
actor LocalStore {
    /// The App Group shared container identifier (local-first-store spec).
    static let appGroupID = "group.com.antonkosenko.shunik"

    /// The local-metadata key holding the user id a database file is bound
    /// to (account-bound-store spec). Written on the first open of a per-user
    /// file and verified on every subsequent open: the file NAME is the
    /// primary selector (derived from the signed-in `user_id`), the marker is
    /// the per-file integrity check — it survives logout/lock inside the
    /// file, exactly where the dormant data it guards lives.
    static let boundUserIDKey = "bound_user_id"

    /// The database file name for one account inside the App Group container
    /// (account-bound-store spec: `shunik_<userId>.db`).
    static func databaseFileName(userID: String) -> String {
        "shunik_\(userID).db"
    }

    /// The database queue. `DatabaseQueue` is sufficient: the app is the only
    /// writer in practice, and cross-process access is serialized by SQLite's
    /// own file locking. Nil while the store is unbound (no signed-in
    /// account) — every operation then fails with `LocalStoreError.notBound`.
    private var dbQueue: DatabaseQueue?

    /// The file the active queue is opened against, or nil when unbound.
    /// Captured at bind time so `eraseAll()` deletes exactly the active
    /// account's file.
    private(set) var boundURL: URL?

    /// The user id the active file is bound to, or nil when unbound.
    private(set) var boundUserID: String?

    /// The most recently bound file's URL, retained across `closeAccount()`
    /// so `eraseAll()` can still delete the account's file when erase runs
    /// right after logout (the Profile erase flow signs out as part of the
    /// same action). Cleared by `eraseAll()` itself.
    private var lastBoundURL: URL?

    /// Generates client record IDs (UUID v7) for new relay resources —
    /// Categories and Entries (category-management D3). One
    /// dependency-injectable generator is shared by every creation path so
    /// tests can inject deterministic ids.
    private let recordIDGenerator: RecordIDGenerating

    /// Errors thrown by account binding and per-account erase
    /// (account-bound-store spec).
    enum LocalStoreError: Error, Equatable {
        /// No account file is open (nothing signed in). Every operation is
        /// refused until `openAccount(userID:)` binds one — the auth gate is
        /// the only reachable surface while signed out, and it neither reads
        /// nor writes tracker data.
        case notBound
        /// The user id contains characters unsafe for a database file name.
        case invalidUserID
        /// The database file on disk is bound to a different account than
        /// the one being opened. The active file is determined solely by
        /// `user_id`, so this is an integrity failure — fail fast.
        case accountMismatch
    }

    /// Production constructor: an UNBOUND store. No database file is opened
    /// until `openAccount(userID:)` binds one on sign-in — the URL depends on
    /// the not-yet-known `userId`, and nothing may touch a tracker file
    /// before an account is bound (account-bound-store spec).
    init(recordIDGenerator: RecordIDGenerating = UUIDv7Generator()) {
        self.recordIDGenerator = recordIDGenerator
    }

    /// Opens a specific database file immediately, binding it to `userID`
    /// when given (tests and previews pin a URL; the composition roots use
    /// the unbound constructor plus `openAccount(userID:)`). With `userID`,
    /// the file's account marker is written on first open and verified on
    /// every subsequent open — opening a file bound to another account throws
    /// `LocalStoreError.accountMismatch`.
    ///
    /// - Parameters:
    ///   - url: The database file location. Tests pass a temporary URL;
    ///     production resolves it via `databaseURL(userID:)`.
    ///   - userID: The account to bind the file to, or nil for an unbound
    ///     file (no marker written).
    ///   - recordIDGenerator: The UUID v7 record-ID generator (injectable for
    ///     tests; defaults to the real time-ordered generator).
    init(
        url: URL,
        userID: String? = nil,
        recordIDGenerator: RecordIDGenerating = UUIDv7Generator()
    ) throws {
        self.recordIDGenerator = recordIDGenerator
        let (queue, boundID) = try Self.openQueue(url: url, userID: userID)
        self.dbQueue = queue
        self.boundURL = url
        self.boundUserID = boundID
        self.lastBoundURL = url
    }

    /// Binds the store to an account: opens (creating if needed) that
    /// account's `shunik_<userId>.db` file in the App Group container and
    /// migrates it. Re-login as the same account reopens the existing file
    /// and resumes it (dirty outbox, sync cursors, running-timer draft) with
    /// no re-pull; switching accounts closes the previous file (kept on disk,
    /// dormant) and opens the new one. A file already bound to this account
    /// is left as-is.
    ///
    /// Failure atomicity (unbound-on-failure): ANY failure — invalidUserID,
    /// accountMismatch, migration or disk error — releases the previous
    /// binding FIRST (dbQueue, boundURL, boundUserID, and lastBoundURL all go
    /// to nil) and rethrows. The store after a failed open is cleanly UNBOUND:
    /// every subsequent operation throws `notBound` (an explicit signal, never
    /// silent wrong-file access), and `eraseAll()` cannot retarget the previous
    /// account's file. The previous account's file itself is untouched on disk
    /// (dormant, resumable on its next open). Erase-after-close keeps working
    /// because `closeAccount()` — the clean path — explicitly retains
    /// `lastBoundURL`; a failed open is never a clean close, so it retains
    /// nothing. No stale boundURL may ever point at a file the store doesn't
    /// hold, in either direction.
    func openAccount(userID: String) throws {
        do {
            let sanitized = try Self.sanitizedUserID(userID)
            if boundUserID == sanitized, dbQueue != nil { return }
            let url = Self.databaseURL(userID: sanitized)
            let (queue, boundID) = try Self.openQueue(url: url, userID: sanitized)
            self.dbQueue = queue
            self.boundURL = url
            self.boundUserID = boundID
            self.lastBoundURL = url
            undoPushInFlight = false
        } catch {
            dbQueue = nil
            boundURL = nil
            boundUserID = nil
            lastBoundURL = nil
            undoPushInFlight = false
            throw error
        }
    }

    /// Closes the active account file WITHOUT deleting it (account-bound-
    /// store spec: logout keeps all files). The dirty outbox and the running
    /// timer draft stay in the now-dormant file; a later `openAccount` for
    /// the same user resumes them.
    func closeAccount() {
        dbQueue = nil
        boundURL = nil
        boundUserID = nil
        undoPushInFlight = false
    }

    /// The production database URL for one account inside the App Group
    /// shared container. `baseURL` overrides the App Group container (tests).
    static func databaseURL(userID: String, in baseURL: URL? = nil) -> URL {
        (baseURL ?? appGroupBase()).appendingPathComponent(databaseFileName(userID: userID))
    }

    /// The App Group shared container, falling back to Application Support
    /// and then the temporary directory (sandboxed previews/tests).
    private static func appGroupBase() -> URL {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        return container ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// Rejects user ids that would escape the container path (path
    /// separators, dots). Server user ids are opaque tokens; anything that
    /// does not survive sanitization verbatim is rejected.
    private static func sanitizedUserID(_ userID: String) throws -> String {
        let sanitized = userID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !sanitized.isEmpty, sanitized == userID else {
            throw LocalStoreError.invalidUserID
        }
        return sanitized
    }

    /// Opens (creating if needed) a database file, verifies — when `userID`
    /// is given — its per-file account marker, migrates it to the latest
    /// schema, then re-verifies and writes the marker. Returns the open queue
    /// and the effective bound user id (nil when `userID` is nil).
    ///
    /// The marker check runs BEFORE migrations whenever the file already
    /// carries a schema (a `local_metadata` table exists): the v2 migration
    /// is not additive-only (it renames, backfills, and drops tables), so a
    /// cross-account open must throw `accountMismatch` without mutating the
    /// dormant file. Brand-new files migrate first; the marker is then
    /// checked (mismatch still throws) and written on adoption.
    private static func openQueue(
        url: URL,
        userID: String?
    ) throws -> (DatabaseQueue, String?) {
        let queue = try makeDatabaseQueue(at: url)
        guard let userID else {
            try migrator().migrate(queue)
            return (queue, nil)
        }
        let sanitized = try sanitizedUserID(userID)
        if try schemaHasMarkerTable(in: queue),
           let existing = try boundUserMarker(in: queue),
           existing != sanitized {
            throw LocalStoreError.accountMismatch
        }
        try migrator().migrate(queue)
        if let existing = try boundUserMarker(in: queue), existing != sanitized {
            throw LocalStoreError.accountMismatch
        }
        try writeBoundUserMarker(sanitized, in: queue)
        return (queue, sanitized)
    }

    /// Whether the database file already carries a schema holding the
    /// per-file account marker (a `local_metadata` table). Read-only:
    /// opening the queue never mutates the file, so this gate lets
    /// `openQueue` reject a cross-account file before migrations run.
    private static func schemaHasMarkerTable(in queue: DatabaseQueue) throws -> Bool {
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name = 'local_metadata'
                """) ?? 0
            return count > 0
        }
    }

    /// Creates the database queue for one file. `DatabaseQueue` is
    /// sufficient: concurrent writers (app sync drain, widget Stop intent)
    /// are serialized by SQLite's own file locking, and every multi-step
    /// flow is fail-closed per step (a `BUSY`/IO throw aborts that step
    /// without partial commits leaking past the chokepoint). Multi-step
    /// flows are deliberately NOT single transactions across steps — a
    /// crash between entry-save and draft-clear is reconciled on next
    /// contact (draft present → run resumes; entry-recency heuristic),
    /// identically in-app and in the intent.
    private static func makeDatabaseQueue(at url: URL) throws -> DatabaseQueue {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // Foreign keys are enforced so a delete of a category or entry
            // cascades to its join rows, mirroring the backend relay.
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        // Lock-screen surfaces (Stop intent) run with a locked keybag: the
        // db must stay readable/writable after first unlock (device finding:
        // locked Stop no-op'd with "store or draft unavailable"). Journals
        // created later inherit the db file's class on iOS; re-applied on
        // every open so pre-existing files heal on next unlocked launch.
        FileManager.default.ensureAccessibleAfterFirstUnlock(url)
        return queue
    }

    /// Reads the per-file account marker, or nil when absent.
    private static func boundUserMarker(in queue: DatabaseQueue) throws -> String? {
        try queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT value FROM local_metadata WHERE key = ?
                """, arguments: [boundUserIDKey])
        }
    }

    /// Writes the per-file account marker (idempotent).
    private static func writeBoundUserMarker(_ userID: String, in queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO local_metadata (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [boundUserIDKey, userID]
            )
        }
    }

    /// The active account's database queue, or `notBound` before any account
    /// file is opened. This is the single guard point: an unbound store
    /// (signed out) can never touch a database file.
    private var queue: DatabaseQueue {
        get throws {
            guard let dbQueue else { throw LocalStoreError.notBound }
            return dbQueue
        }
    }

    // MARK: - Schema

    // swiftlint:disable:next todo
    // SHUNIK-TODO: scaffold schema — outbox, undo buffer, sync cursors, and
    // per-file metadata only. The pet-care domain will add its own tables here.
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "local_metadata") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
            try db.create(table: "outbox") { t in
                t.column("id", .text).primaryKey()
                t.column("resource", .text).notNull()
                t.column("record_id", .text).notNull()
                t.column("op", .text).notNull()
                t.column("payload", .text)
                t.column("created_at", .datetime).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "undo_buffer") { t in
                t.column("id", .text).primaryKey()
                t.column("payload", .text).notNull()
                t.column("deleted_at", .datetime).notNull()
            }
            try db.create(table: "sync_state") { t in
                t.column("resource", .text).primaryKey()
                t.column("last_synced_at", .datetime)
            }
        }
        return migrator
    }

    // MARK: - Record IDs (UUID v7, D3)

    /// A new UUID v7 record id from the shared injectable generator, used for
    /// new Category and Entry relay resources.
    func newRecordID() -> String {
        recordIDGenerator.newID()
    }

    // swiftlint:disable:next todo
    // SHUNIK-TODO: pet-care domain tables and typed helpers go here.

    // MARK: - Outbox

    /// All pending outbox rows, oldest first (insertion order within a
    /// resource: created_at with a rowid tiebreak, per the sync-client spec).
    func outboxRows() throws -> [OutboxRow] {
        try queue.read { db in
            try OutboxRow.fetchAll(db, sql: """
                SELECT * FROM outbox ORDER BY created_at, rowid
            """)
        }
    }

    /// Reads one pending outbox row by id. A drain re-reads rows after each
    /// operation because conflict recovery may rewrite a later payload in the
    /// same in-memory drain pass.
    func outboxRow(id: String) throws -> OutboxRow? {
        try queue.read { db in
            try OutboxRow.fetchOne(db, key: id)
        }
    }

    /// Removes an outbox row after it has been pushed (or resolved).
    func removeOutboxRow(id: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Local deletion tombstones (delete-wins on pull)

    /// Whether `(resource, recordID)` has a pending outbox DELETE: a
    /// committed local deletion that has not reached the relay yet. A pull
    /// that runs before the drain pushes it (first-sync is pull-first) still
    /// sees the record on the relay and must not merge it back.
    func hasPendingDelete(resource: String, recordID: String) throws -> Bool {
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM outbox
                WHERE resource = ? AND record_id = ? AND op = 'delete'
                """, arguments: [resource, recordID]) ?? 0
            return count > 0
        }
    }

    /// Whether `(resource, recordID)` sits in the durable undo buffer: a
    /// deletion the user can still undo, with no outbox row yet. The relay
    /// still holds the record, so an unguarded pull would resurrect it and
    /// the later commit would leave a permanent zombie behind.
    func isBufferedForDeletion(resource: String, recordID: String) throws -> Bool {
        try queue.read { db in
            let rows = try UndoBufferRow.fetchAll(db, sql: "SELECT * FROM undo_buffer")
            for row in rows {
                guard let data = row.payload.data(using: .utf8),
                      let snapshot = try? JSONDecoder().decode(DeletionSnapshot.self, from: data),
                      snapshot.records.contains(where: { $0.resource == resource && $0.recordID == recordID })
                else { continue }
                return true
            }
            return false
        }
    }

    /// Whether a pull-merge must skip this record: the user deleted it
    /// locally (buffered undoable deletion or committed outbox delete) and
    /// the relay has not converged yet. Undo restores the row and clears the
    /// buffer, and a successful drain clears the outbox row — both lift the
    /// guard, so newer server versions merge normally afterwards.
    func isLocallyDeleted(resource: String, recordID: String) throws -> Bool {
        try hasPendingDelete(resource: resource, recordID: recordID)
            || isBufferedForDeletion(resource: resource, recordID: recordID)
    }

    /// Whether `(resource, record_id)` has a pending create or update outbox
    /// row (an unpushed local mutation that the relay does not know yet).
    private static func hasPendingCreateOrUpdate(
        _ db: Database,
        resource: String,
        recordID: String
    ) throws -> Bool {
        let count = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM outbox
            WHERE resource = ? AND record_id = ? AND op IN ('create', 'update')
            """, arguments: [resource, recordID]) ?? 0
        return count > 0
    }

    /// Removes every pending create/update outbox row for
    /// `(resource, record_id)`. Pending DELETE rows are left alone: the drain
    /// converges them via the existing 404-as-success rule.
    private static func dropPendingCreateOrUpdate(
        _ db: Database,
        resource: String,
        recordID: String
    ) throws {
        try db.execute(
            sql: "DELETE FROM outbox WHERE resource = ? AND record_id = ? AND op IN ('create', 'update')",
            arguments: [resource, recordID]
        )
    }

    /// Rewrites the payload of every pending outbox row for (resource,
    /// record_id) — used after a name-collision remap so a later drain pushes
    /// the corrected reference instead of the stale one.
    func rewriteOutboxPayload(resource: String, recordID: String, payload: (any Encodable)?) throws {
        try queue.write { db in
            let payloadData: String?
            if let payload {
                payloadData = try String(data: JSONEncoder().encode(AnyEncodable(payload)), encoding: .utf8)
            } else {
                payloadData = nil
            }
            try db.execute(
                sql: "UPDATE outbox SET payload = ? WHERE resource = ? AND record_id = ?",
                arguments: [payloadData, resource, recordID]
            )
        }
    }

    // MARK: - Sync state (per-resource cursors)

    /// The last-synced cursor for a resource, or nil on first sync.
    func lastSyncedAt(resource: String) throws -> Date? {
        try queue.read { db in
            try Date.fetchOne(db, sql: """
                SELECT last_synced_at FROM sync_state WHERE resource = ?
                """, arguments: [resource])
        }
    }

    /// Advances the per-resource cursor to `date`.
    func setLastSyncedAt(resource: String, date: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sync_state (resource, last_synced_at) VALUES (?, ?)
                    ON CONFLICT(resource) DO UPDATE SET last_synced_at = ?
                    """,
                arguments: [resource, date, date]
            )
        }
    }

    // MARK: - Undo buffer (durable, D3)

    /// Set while a buffered deletion's relay push is in flight
    /// (propagate-buffered-deletes D3): undo of that row is refused for the
    /// ~100ms the push takes, closing the restore-vs-DELETE race where the
    /// relay deletes a record the user just restored with no outbox row left
    /// to repair the divergence. `LocalStore` is an actor, so plain stored
    /// state is already serialized — no extra lock needed.
    private var undoPushInFlight = false

    /// Marks the start/end of a buffered-deletion push loop. While set,
    /// `undoBufferRestore`, `undoEntryDeletion`, and `undoCategoryDeletion`
    /// refuse with `UndoError.pushInFlight`.
    func setUndoPushInFlight(_ inFlight: Bool) {
        undoPushInFlight = inFlight
    }

    /// One snapshotted record awaiting push-then-commit.
    struct BufferedDeletion: Equatable, Sendable {
        /// The `undo_buffer` row holding the snapshot.
        let bufferID: String
        let resource: String
        let recordID: String
    }

    // swiftlint:disable:next todo
    // SHUNIK-TODO: scaffold — every snapshotted record in the buffer,
    // flattened across rows (entry order preserved per row).
    func bufferedDeletions() throws -> [BufferedDeletion] {
        try queue.read { db in
            let rows = try UndoBufferRow.fetchAll(db, sql: """
                SELECT * FROM undo_buffer ORDER BY deleted_at ASC, id ASC
                """)
            var result: [BufferedDeletion] = []
            for row in rows {
                let snapshot = try JSONDecoder().decode(DeletionSnapshot.self, from: Data(row.payload.utf8))
                for record in snapshot.records {
                    result.append(BufferedDeletion(bufferID: row.id, resource: record.resource, recordID: record.recordID))
                }
            }
            return result
        }
    }

    /// Drops one buffer row after all its records pushed successfully
    /// (push-then-commit). A partial failure keeps the whole row buffered —
    /// never half-committed.
    func undoBufferRemove(id: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM undo_buffer WHERE id = ?", arguments: [id])
        }
    }

    /// The most recent buffer row (the only one undoable via shake/toast, U7).
    func undoBufferMostRecent() throws -> UndoBufferRow? {
        try queue.read { db in
            try UndoBufferRow.fetchOne(db, sql: """
                SELECT * FROM undo_buffer ORDER BY deleted_at DESC, id DESC LIMIT 1
                """)
        }
    }

    /// Enters a pending deletion: inserts the buffer row in one transaction.
    /// The caller has already deleted the records (or does so in the same
    /// logical operation); no outbox row is created.
    func undoBufferEnter(payload: Data, deletedAt: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO undo_buffer (id, payload, deleted_at) VALUES (?, ?, ?)
                    """,
                arguments: [UUID().uuidString, String(data: payload, encoding: .utf8), deletedAt]
            )
        }
    }

    /// Restores the records from a buffer row's payload and deletes the
    /// buffer row in one transaction. No outbox row is ever created.
    /// Refuses with `UndoError.pushInFlight` while a buffered-deletion push
    /// is in flight (propagate-buffered-deletes D3).
    func undoBufferRestore(id: String) throws {
        guard !undoPushInFlight else { throw UndoError.pushInFlight }
        try queue.write { db in
            guard let row = try UndoBufferRow.fetchOne(db, key: id) else { return }
            let snapshot = try JSONDecoder().decode(DeletionSnapshot.self, from: Data(row.payload.utf8))
            try Self.applySnapshot(db, snapshot)
            try db.execute(sql: "DELETE FROM undo_buffer WHERE id = ?", arguments: [id])
        }
    }

    /// Commits every buffered row: deletes each buffer row and inserts
    /// the outbox rows for the deletion in one transaction. Called on
    /// cold launch (an app restart finalizes whatever is still buffered),
    /// never while the process is alive.
    func undoBufferCommitAll() throws {
        try queue.write { db in
            let buffered = try UndoBufferRow.fetchAll(db, sql: """
                SELECT * FROM undo_buffer
                """)
            for row in buffered {
                let snapshot = try JSONDecoder().decode(DeletionSnapshot.self, from: Data(row.payload.utf8))
                for record in snapshot.records {
                    try Self.enqueueOutbox(db: db, resource: record.resource, recordID: record.recordID,
                                           op: "delete", payload: nil)
                }
                try db.execute(sql: "DELETE FROM undo_buffer WHERE id = ?", arguments: [row.id])
            }
        }
    }

    // swiftlint:disable:next todo
    // SHUNIK-TODO: scaffold — snapshot restore is a no-op until the pet-care
    // domain defines its tables. Buffer rows still commit to tombstone outbox
    // rows via `undoBufferCommitAll`.
    private static func applySnapshot(_ db: Database, _ snapshot: DeletionSnapshot) throws {
    }

    // MARK: - Erase local data (destructive, per-account Settings action)

    /// Deletes the ACTIVE account's database file — state, outbox, undo
    /// buffer, sync_state, and the per-file account marker all go with it —
    /// and leaves the store unbound (account-bound-store spec). Releasing the
    /// queue closes the underlying SQLite connection; GRDB removes the file
    /// only when no connection holds it, so unbinding happens before the
    /// remove. Other accounts' dormant files are untouched; logout alone
    /// never deletes any file. Session artifacts (Keychain tokens, cached
    /// session) are cleared by the caller, not here. The next sign-in as
    /// this account creates a fresh file that is seeded again.
    ///
    /// Throwing: a failed `removeItem` (disk error, permissions) propagates
    /// to the caller instead of reporting success — the store is already
    /// unbound (the connection was released first), the target URL is kept
    /// for a retry, and the data stays on disk until the next sign-in
    /// reopens it. A missing file is success (nothing left to delete).
    /// After a FAILED open there is nothing to erase (the failure cleared
    /// `lastBoundURL` too): this returns without touching any dormant file.
    func eraseAll() throws {
        // Unbind first: the queued connection holds the file open, and
        // removing an open file would leave the descriptor dangling on
        // a path that no longer matches the store's state.
        let url = boundURL ?? lastBoundURL
        dbQueue = nil
        boundURL = nil
        boundUserID = nil
        undoPushInFlight = false
        guard let url else {
            lastBoundURL = nil
            return
        }
        do {
            try Self.removeDatabaseFiles(at: url)
            lastBoundURL = nil
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // Already gone: the erase goal is met.
            lastBoundURL = nil
        } catch {
            // Keep the URL so the caller can retry the same file.
            lastBoundURL = url
            throw error
        }
    }

    /// Deletes the database file of the EXPLICITLY identified account —
    /// active or dormant — with its SQLite sidecars, and never touches any
    /// other account's file or the stable device identity
    /// (account-deletion spec: confirmed cleanup of exactly one UUID).
    ///
    /// When the target is the ACTIVE account, the queue is released first
    /// (the caller's own shared handle must be gone before the exclusive
    /// cross-process erase) and the store ends unbound — the file must not
    /// be reopened or recreated afterwards. When the target is dormant, the
    /// active store is left completely alone. A missing file (and missing
    /// sidecars) is success. Failures propagate for a caller-side retry;
    /// the active retry slot is recorded only when the target was active —
    /// a dormant-erase failure never disturbs it.
    ///
    /// - Parameter baseURL: overrides the App Group container (tests pin a
    ///   throwaway directory; production uses the shared container).
    func eraseAccount(userID: String, in baseURL: URL? = nil) throws {
        let sanitized = try Self.sanitizedUserID(userID)
        let url = Self.databaseURL(userID: sanitized, in: baseURL)
        // Capture whether the target is active BEFORE releasing anything: a
        // dormant-erase failure must leave the active retry slot untouched,
        // while an active-erase failure records this URL for retry.
        let wasActive = (boundUserID == sanitized)
        if wasActive {
            // Active target: release our own handle before the erase.
            dbQueue = nil
            boundURL = nil
            boundUserID = nil
            undoPushInFlight = false
        }
        do {
            try Self.removeDatabaseFiles(at: url)
            if lastBoundURL == url { lastBoundURL = nil }
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // Already gone: the erase goal is met.
            if lastBoundURL == url { lastBoundURL = nil }
        } catch {
            // Active target: the store is already unbound (a retry still
            // never erases under a live writer), so record the URL for
            // retry. Dormant target: leave the active retry slot alone.
            if wasActive { lastBoundURL = url }
            throw error
        }
    }

    /// Removes a database file with its SQLite sidecars (`-wal`, `-shm`,
    /// `-journal`). The main file may be absent while sidecars linger (or
    /// vice versa) after a crash — every missing piece is success, and only
    /// a genuine removal failure throws.
    private static func removeDatabaseFiles(at url: URL) throws {
        let fileManager = FileManager.default
        // SQLite sidecars use dash-style names ("shunik_X.db-wal"), not
        // dot extensions — build them explicitly from the full path.
        let sidecars = ["-wal", "-shm", "-journal"].map { suffix in
            URL(fileURLWithPath: url.path + suffix)
        }
        var firstError: Error?
        for candidate in [url] + sidecars {
            do {
                try fileManager.removeItem(at: candidate)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                continue
            } catch {
                // Keep the first genuine failure but continue with the
                // remaining pieces so a retry has less left to do.
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    // MARK: - Internals

    /// The transactional outbox chokepoint: every mutation writes its outbox
    /// row in the same transaction as the state change (D2).
    private static func enqueueOutbox(
        db: Database,
        resource: String,
        recordID: String,
        op: String,
        payload: (any Encodable)?
    ) throws {
        let payloadData: String?
        if let payload {
            payloadData = try String(data: JSONEncoder().encode(AnyEncodable(payload)), encoding: .utf8)
        } else {
            payloadData = nil
        }
        try db.execute(
            sql: """
                INSERT INTO outbox (id, resource, record_id, op, payload, created_at, attempts)
                VALUES (?, ?, ?, ?, ?, ?, 0)
                """,
            arguments: [UUID().uuidString, resource, recordID, op, payloadData, Date()]
        )
    }
}

// MARK: - GRDB records

/// GRDB record for the transactional outbox (D2).
struct OutboxRow: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "outbox"

    let id: String
    let resource: String
    let recordID: String
    let op: String
    let payload: String?
    let createdAt: Date
    let attempts: Int

    enum CodingKeys: String, CodingKey {
        case id, resource, op, payload, attempts
        case recordID = "record_id"
        case createdAt = "created_at"
    }
}

/// GRDB record for the durable undo buffer (D3).
/// Errors thrown when an undo is refused (never a persistence failure).
enum UndoError: Error, Equatable {
    /// A buffered-deletion relay push is in flight; the row may be committed
    /// at any moment, so restoring it now could diverge from the relay
    /// (propagate-buffered-deletes D3). Transient — retry after the sync
    /// cycle finishes.
    case pushInFlight
}

struct UndoBufferRow: Codable, Equatable, FetchableRecord, PersistableRecord {    static let databaseTableName = "undo_buffer"

    let id: String
    let payload: String
    let deletedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, payload
        case deletedAt = "deleted_at"
    }
}

/// A full serialized snapshot of the records deleted by one undoable deletion.
/// Held in the undo buffer so an undo can restore them exactly.
struct DeletionSnapshot: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        let resource: String
        let recordID: String
        let data: Data
    }

    let records: [Record]
}

extension FileManager {
    /// Marks `url` (plus SQLite `-wal`/`-shm`/`-journal` siblings when
    /// present) readable/writable after first unlock, so lock-screen
    /// extension surfaces (Stop intent) keep working with a locked keybag.
    /// Best-effort and never throwing: a failed stamp must not fail the
    /// open/write it follows (and cannot heal anything while locked — files
    /// heal on the next unlocked open instead).
    func ensureAccessibleAfterFirstUnlock(_ url: URL) {
        var candidates = [url]
        for suffix in ["-wal", "-shm", "-journal"] {
            candidates.append(URL(fileURLWithPath: url.path + suffix))
        }
        for candidate in candidates where fileExists(atPath: candidate.path) {
            try? setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: candidate.path
            )
        }
    }
}
