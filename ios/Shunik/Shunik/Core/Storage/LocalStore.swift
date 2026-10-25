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
/// and binds on sign-in via `openHousehold(householdID:)` — which opens (creating if
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

    /// The local-metadata key holding the household id a database file is
    /// bound to (Shunik v1: one file per household, `shunik_<householdId>.db`,
    /// shared by its owners). Written on the first open and verified on every
    /// subsequent open: the file NAME is the primary selector (derived from
    /// the resolved household id), the marker is the per-file integrity
    /// check — it survives logout/lock inside the file, exactly where the
    /// dormant data it guards lives.
    static let boundHouseholdIDKey = "bound_household_id"

    /// The database queue. `DatabaseQueue` is sufficient: the app is the only
    /// writer in practice, and cross-process access is serialized by SQLite's
    /// own file locking. Nil while the store is unbound (no signed-in
    /// account) — every operation then fails with `LocalStoreError.notBound`.
    private var dbQueue: DatabaseQueue?

    /// The file the active queue is opened against, or nil when unbound.
    /// Captured at bind time so `eraseAll()` deletes exactly the active
    /// account's file.
    private(set) var boundURL: URL?

    /// The database file name for one household inside the App Group container
    /// (Shunik v1: `shunik_<householdId>.db`).
    static func databaseFileName(householdID: String) -> String {
        "shunik_\(householdID).db"
    }

    /// The household id the active file is bound to, or nil when unbound.
    private(set) var boundHouseholdID: String?

    /// The production database URL for one household inside the App Group
    /// shared container. `baseURL` overrides the App Group container (tests).
    static func databaseURL(householdID: String, in baseURL: URL? = nil) -> URL {
        (baseURL ?? appGroupBase()).appendingPathComponent(databaseFileName(householdID: householdID))
    }

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
        /// refused until `openHousehold(householdID:)` binds one — the auth gate is
        /// the only reachable surface while signed out, and it neither reads
        /// nor writes tracker data.
        case notBound
        /// The user id contains characters unsafe for a database file name.
        case invalidUserID
        /// The database file on disk is bound to a different account than
        /// the one being opened. The active file is determined solely by
        /// `user_id`, so this is an integrity failure — fail fast.
        case accountMismatch
        /// The update base does not match the stored row (or the row is
        /// gone): the writer's view is stale. Nothing was changed and no
        /// outbox row was written — re-read the row and retry. The relay
        /// enforces the same guard server-side via `base_updated_at` (409).
        case staleBase
    }

    /// Production constructor: an UNBOUND store. No database file is opened
    /// until `openHousehold(householdID:)` binds one on sign-in — the URL depends on
    /// the not-yet-known `userId`, and nothing may touch a tracker file
    /// before an account is bound (account-bound-store spec).
    init(recordIDGenerator: RecordIDGenerating = UUIDv7Generator()) {
        self.recordIDGenerator = recordIDGenerator
    }

    /// Opens a specific database file immediately, binding it to `householdID`
    /// when given (tests and previews pin a URL). With `householdID`, the
    /// file's household marker is written on first open and verified on
    /// every subsequent open — opening a file bound to another household
    /// throws `LocalStoreError.accountMismatch`.
    ///
    /// - Parameters:
    ///   - url: The database file location. Tests pass a temporary URL;
    ///     production resolves it via `databaseURL(householdID:)`.
    ///   - householdID: The household to bind the file to, or nil for an
    ///     unbound file (no marker written).
    ///   - recordIDGenerator: The UUID v7 record-ID generator (injectable for
    ///     tests; defaults to the real time-ordered generator).
    init(
        url: URL,
        householdID: String? = nil,
        recordIDGenerator: RecordIDGenerating = UUIDv7Generator()
    ) throws {
        self.recordIDGenerator = recordIDGenerator
        let (queue, boundID): (DatabaseQueue, String?)
        if let householdID {
            let sanitized = try Self.sanitizedFileID(householdID)
            (queue, boundID) = try Self.openHouseholdQueue(url: url, householdID: sanitized)
        } else {
            let q = try Self.makeDatabaseQueue(at: url)
            try Self.migrator().migrate(q)
            queue = q
            boundID = nil
        }
        self.dbQueue = queue
        self.boundURL = url
        self.boundHouseholdID = boundID
        self.lastBoundURL = url
    }

    /// Closes the active household file WITHOUT deleting it (logout keeps
    /// all files). The dirty outbox stays in the now-dormant file; a later
    /// `openHousehold` for the same household resumes it.
    func closeAccount() {
        dbQueue = nil
        boundURL = nil
        boundHouseholdID = nil
        undoPushInFlight = false
    }

    /// Binds the store to a household: opens (creating if needed) that
    /// household's `shunik_<householdId>.db` file in the App Group container
    /// and migrates it. Re-opening the bound household is a no-op, failure
    /// unbinds cleanly, and a file whose `bound_household_id` marker names
    /// a different household throws `LocalStoreError.accountMismatch`
    /// without mutating the file.
    /// `baseURL` overrides the App Group container (tests pin a throwaway
    /// directory; production passes nil).
    func openHousehold(householdID: String, in baseURL: URL? = nil) throws {
        do {
            let sanitized = try Self.sanitizedFileID(householdID)
            if boundHouseholdID == sanitized, dbQueue != nil { return }
            let url = Self.databaseURL(householdID: sanitized, in: baseURL)
            let (queue, boundID) = try Self.openHouseholdQueue(url: url, householdID: sanitized)
            self.dbQueue = queue
            self.boundURL = url
            self.boundHouseholdID = boundID
            self.lastBoundURL = url
            undoPushInFlight = false
        } catch {
            dbQueue = nil
            boundURL = nil
            boundHouseholdID = nil
            lastBoundURL = nil
            undoPushInFlight = false
            throw error
        }
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

    /// Rejects ids that would escape the container path (path separators,
    /// dots). Server household ids are opaque tokens; anything that does not
    /// survive sanitization verbatim is rejected.
    private static func sanitizedFileID(_ userID: String) throws -> String {
        let sanitized = userID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !sanitized.isEmpty, sanitized == userID else {
            throw LocalStoreError.invalidUserID
        }
        return sanitized
    }

    /// Whether the database file already carries a schema holding the
    /// per-file household marker (a `local_metadata` table). Read-only:
    /// opening the queue never mutates the file, so this gate lets
    /// `openHouseholdQueue` reject a cross-household file before migrations run.
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

    /// Opens (creating if needed) a household database file, verifying its
    /// per-file household marker before and after migration, then writing it.
    /// Only the `bound_household_id` key is consulted: legacy `bound_user_id`
    /// markers are ignored (household files are fresh files in practice).
    private static func openHouseholdQueue(
        url: URL,
        householdID: String
    ) throws -> (DatabaseQueue, String) {
        let queue = try makeDatabaseQueue(at: url)
        let sanitized = try sanitizedFileID(householdID)
        if try schemaHasMarkerTable(in: queue),
           let existing = try boundHouseholdMarker(in: queue),
           existing != sanitized {
            throw LocalStoreError.accountMismatch
        }
        try migrator().migrate(queue)
        if let existing = try boundHouseholdMarker(in: queue), existing != sanitized {
            throw LocalStoreError.accountMismatch
        }
        try writeBoundHouseholdMarker(sanitized, in: queue)
        return (queue, sanitized)
    }

    /// Reads the per-file household marker, or nil when absent.
    private static func boundHouseholdMarker(in queue: DatabaseQueue) throws -> String? {
        try queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT value FROM local_metadata WHERE key = ?
                """, arguments: [boundHouseholdIDKey])
        }
    }

    /// Writes the per-file household marker (idempotent).
    private static func writeBoundHouseholdMarker(_ householdID: String, in queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO local_metadata (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [boundHouseholdIDKey, householdID]
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

    /// v1 carries the account-bound scaffold: outbox, undo buffer, sync
    /// cursors, and per-file metadata. v2 adds the Shunik v1 pet-care domain
    /// (pets, event base + kind-detail tables, medication intakes, documents +
    /// pet links). v2 is additive-only on top of v1.
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
        // v2: Shunik v1 domain tables. No FOREIGN KEY clauses by decision:
        // every delete is explicit and ordered in this file (row + detail +
        // link rows), and FK enforcement would complicate cross-process undo
        // restores and pull-merge replaces, which re-insert rows out of
        // parent/child order. Join-table orphans are impossible because the
        // only writers of these tables are the helpers below.
        migrator.registerMigration("v2") { db in
            try Self.migrateToV2(db)
        }
        return migrator
    }

    /// The v2 migration body, factored out so `migrator()` stays small.
    private static func migrateToV2(_ db: Database) throws {
        try migrateToV2PetsAndEvents(db)
        try migrateToV2Details(db)
        try migrateToV2Documents(db)
    }

    private static func migrateToV2PetsAndEvents(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE pets (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL,
                name TEXT NOT NULL,
                species TEXT NOT NULL,
                birthdate TEXT,
                notes TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                updated_by TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE event_base (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL,
                pet_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                occurred_at TEXT NOT NULL,
                next_due_at TEXT,
                title TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                updated_by TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE med_intakes (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL,
                course_id TEXT NOT NULL,
                due_at TEXT,
                status TEXT NOT NULL,
                taken_at TEXT,
                dose_snapshot TEXT NOT NULL,
                note TEXT NOT NULL,
                marked_by TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_event_base_pet ON event_base (pet_id)")
        try db.execute(sql: "CREATE INDEX idx_med_intakes_course ON med_intakes (course_id)")
    }

    private static func migrateToV2Details(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE vacc_details (
                event_id TEXT PRIMARY KEY,
                vaccine TEXT NOT NULL,
                batch TEXT NOT NULL,
                vet TEXT NOT NULL,
                notes TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE grooming_details (
                event_id TEXT PRIMARY KEY,
                service TEXT NOT NULL,
                place TEXT NOT NULL,
                notes TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE weight_details (
                event_id TEXT PRIMARY KEY,
                grams INTEGER NOT NULL CHECK (grams > 0)
            )
            """)
        try db.execute(sql: """
            CREATE TABLE med_courses (
                event_id TEXT PRIMARY KEY,
                drug_name TEXT NOT NULL,
                dose_amount TEXT NOT NULL,
                dose_unit TEXT NOT NULL,
                route TEXT NOT NULL,
                schedule_kind TEXT NOT NULL,
                schedule_times TEXT NOT NULL,
                schedule_weekdays TEXT NOT NULL,
                duration_days INTEGER NOT NULL DEFAULT 0,
                ends_on TEXT,
                status TEXT NOT NULL,
                instructions TEXT NOT NULL,
                info_ref TEXT NOT NULL
            )
            """)
    }

    private static func migrateToV2Documents(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE documents (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL,
                title TEXT NOT NULL,
                mime TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                filename TEXT NOT NULL,
                blob_key TEXT NOT NULL,
                ready INTEGER NOT NULL,
                extracted_text TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                updated_by TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE document_pets (
                document_id TEXT NOT NULL,
                pet_id TEXT NOT NULL,
                PRIMARY KEY (document_id, pet_id)
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_document_pets_pet ON document_pets (pet_id)")
    }

    // MARK: - Record IDs (UUID v7, D3)

    /// A new UUID v7 record id from the shared injectable generator, used for
    /// new Category and Entry relay resources.
    func newRecordID() -> String {
        recordIDGenerator.newID()
    }

    // MARK: - Shunik v1 domain (pets, events, intakes, documents)

    /// Every local mutation stamps `RFC3339Milli.nowString()`; every
    /// comparison is string equality/ordering on normalized values
    /// (fixed-width UTC lexicographic order IS chronological order).
    /// Pull-merge upserts normalize EVERY ingested timestamp and replace the
    /// full row only when the server `updated_at` is newer; rows under a
    /// local delete (pending outbox delete or buffered undoable deletion)
    /// are skipped — delete-wins.
    ///
    /// Every mutation writes state + outbox row in ONE db.write transaction.
    /// Create payloads are the record JSON; update payloads are the wire
    /// UpdateBody JSON including `base_updated_at`. Updates enforce the base
    /// guard locally (`staleBase` on mismatch, row untouched) mirroring the
    /// relay's 409; the drain detects relay-side staleness via the same base.

    /// Resolves the record id for a create: caller-supplied client UUIDs win;
    /// the shared generator fills in only an empty id.
    private func createID(_ id: String) -> String {
        id.isEmpty ? newRecordID() : id
    }

    // MARK: Pets

    /// Inserts a pet row (plain INSERT: a duplicate id fails loudly) + a
    /// `pet`/`create` outbox row carrying the record JSON.
    func createPet(_ record: PetRecord, updatedBy: String) throws -> PetRecord {
        let now = RFC3339Milli.nowString()
        var stored = record
        stored.id = createID(record.id)
        stored.createdAt = now
        stored.updatedAt = now
        stored.updatedBy = updatedBy
        let payload = stored
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO pets
                    (id, household_id, name, species, birthdate, notes,
                     created_at, updated_at, updated_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    stored.id, stored.householdID, stored.name, stored.species,
                    stored.birthdate, stored.notes,
                    stored.createdAt, stored.updatedAt, stored.updatedBy
                ])
            try Self.enqueueOutbox(
                db: db, resource: SyncResource.pet.rawValue,
                recordID: stored.id, op: "create", payload: payload
            )
        }
        return stored
    }

    /// Full-replace update guarded by `baseUpdatedAt` (normalized before
    /// compare): mismatch — or a missing row — throws `staleBase` with the
    /// row and outbox untouched. `id`/`household_id`/`created_at` are echoed
    /// from the stored row; everything else comes from `record`.
    func updatePet(_ record: PetRecord, baseUpdatedAt: String, updatedBy: String) throws -> PetRecord {
        let base = RFC3339Milli.normalize(baseUpdatedAt)
        return try queue.write { db -> PetRecord in
            guard let current = try Self.fetchPet(db: db, id: record.id),
                  current.updatedAt == base
            else { throw LocalStoreError.staleBase }
            var stored = record
            stored.id = current.id
            stored.householdID = current.householdID
            stored.createdAt = current.createdAt
            stored.updatedAt = RFC3339Milli.nowString()
            stored.updatedBy = updatedBy
            try db.execute(sql: """
                UPDATE pets
                SET name = ?, species = ?, birthdate = ?, notes = ?,
                    updated_at = ?, updated_by = ?
                WHERE id = ?
                """, arguments: [
                    stored.name, stored.species, stored.birthdate, stored.notes,
                    stored.updatedAt, stored.updatedBy, stored.id
                ])
            let body = PetUpdateBody(
                baseUpdatedAt: base, name: stored.name, species: stored.species,
                birthdate: stored.birthdate, notes: stored.notes
            )
            try Self.enqueueOutbox(
                db: db, resource: SyncResource.pet.rawValue,
                recordID: stored.id, op: "update", payload: body
            )
            return stored
        }
    }

    /// Deletes the pet row + its document links, with NO outbox row
    /// (tombstone application and undo-buffer capture paths).
    func removePetLocal(id: String) throws {
        try queue.write { db in
            try Self.deletePetRow(db: db, id: id)
        }
    }

    /// Deletes the pet row + its document links and enqueues a `pet`/`delete`
    /// outbox row (nil payload, like buffered commits). `updatedBy` is
    /// accepted for call-site symmetry and is otherwise unused.
    func deletePet(id: String, updatedBy _: String) throws {
        try queue.write { db in
            try Self.deletePetRow(db: db, id: id)
            try Self.enqueueOutbox(
                db: db, resource: SyncResource.pet.rawValue,
                recordID: id, op: "delete", payload: nil
            )
        }
    }

    func getPet(id: String) throws -> PetRecord? {
        try queue.read { db in try Self.fetchPet(db: db, id: id) }
    }

    func listPets() throws -> [PetRecord] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pets ORDER BY name ASC, id ASC")
                .map(Self.pet(from:))
        }
    }

    /// Pull-merge upsert: normalizes timestamps, inserts when missing,
    /// replaces the full row only when the server `updated_at` is newer
    /// (equal or older is a no-op), and skips locally-deleted rows.
    func upsertPet(_ record: PetRecord) throws {
        guard !record.id.isEmpty else { return }
        var incoming = record
        incoming.createdAt = RFC3339Milli.normalize(record.createdAt)
        incoming.updatedAt = RFC3339Milli.normalize(record.updatedAt)
        try queue.write { db in
            if try Self.locallyDeleted(db: db, resource: SyncResource.pet.rawValue, recordID: incoming.id) {
                return
            }
            if let current = try Self.fetchPet(db: db, id: incoming.id),
               current.updatedAt >= incoming.updatedAt {
                return
            }
            try Self.replacePetRow(db: db, incoming)
        }
    }

    // MARK: Events

    /// Inserts an event base row + its kind-detail row + a `event`/`create`
    /// outbox row carrying the record JSON. The detail table is chosen by the
    /// non-nil detail member (robust to future kind strings), not by `kind`.
    func createEvent(_ record: EventRecord, updatedBy: String) throws -> EventRecord {
        let now = RFC3339Milli.nowString()
        var stored = record
        stored.id = createID(record.id)
        stored.createdAt = now
        stored.updatedAt = now
        stored.updatedBy = updatedBy
        stored.occurredAt = RFC3339Milli.normalize(record.occurredAt)
        stored.nextDueAt = Self.normalizedTimestamp(record.nextDueAt)
        let payload = stored
        try queue.write { db in
            try Self.insertEventRow(db: db, stored)
            try Self.enqueueOutbox(
                db: db, resource: SyncResource.event.rawValue,
                recordID: stored.id, op: "create", payload: payload
            )
        }
        return stored
    }

    /// Full-replace update guarded by `baseUpdatedAt` (mismatch or missing
    /// row throws `staleBase`, row untouched). `id`/`household_id`/`pet_id`/
    /// `kind`/`created_at` echo the stored row (`pet_id`/`kind` are immutable
    /// on the relay); `occurred_at`/`next_due_at`/`title`/detail come from
    /// `record`, and the detail table is deleted + re-inserted.
    func updateEvent(_ record: EventRecord, baseUpdatedAt: String, updatedBy: String) throws -> EventRecord {
        let base = RFC3339Milli.normalize(baseUpdatedAt)
        return try queue.write { db -> EventRecord in
            guard let current = try Self.fetchEvent(db: db, id: record.id),
                  current.updatedAt == base
            else { throw LocalStoreError.staleBase }
            var stored = record
            stored.id = current.id
            stored.householdID = current.householdID
            stored.petID = current.petID
            stored.kind = current.kind
            stored.createdAt = current.createdAt
            stored.updatedAt = RFC3339Milli.nowString()
            stored.updatedBy = updatedBy
            stored.occurredAt = RFC3339Milli.normalize(record.occurredAt)
            stored.nextDueAt = Self.normalizedTimestamp(record.nextDueAt)
            try Self.replaceEventRow(db: db, stored)
            let body = EventUpdateBody(
                baseUpdatedAt: base, petID: stored.petID, kind: stored.kind,
                occurredAt: stored.occurredAt, nextDueAt: stored.nextDueAt,
                title: stored.title, vaccination: stored.vaccination,
                grooming: stored.grooming, weight: stored.weight, course: stored.course
            )
            try Self.enqueueOutbox(
                db: db, resource: SyncResource.event.rawValue,
                recordID: stored.id, op: "update", payload: body
            )
            return stored
        }
    }

    /// Deletes the event base row + its detail row, with NO outbox row.
    func removeEventLocal(id: String) throws {
        try queue.write { db in
            try Self.deleteEventRow(db: db, id: id)
        }
    }

    /// Deletes the event base row + its detail row and enqueues an
    /// `event`/`delete` outbox row. `updatedBy` is accepted for call-site
    /// symmetry and is otherwise unused.
    func deleteEvent(id: String, updatedBy _: String) throws {
        try queue.write { db in
            try Self.deleteEventRow(db: db, id: id)
            try Self.enqueueOutbox(
                db: db, resource: SyncResource.event.rawValue,
                recordID: id, op: "delete", payload: nil
            )
        }
    }

    func getEvent(id: String) throws -> EventRecord? {
        try queue.read { db in try Self.fetchEvent(db: db, id: id) }
    }

    /// One pet's timeline, newest first.
    func listEvents(petID: String) throws -> [EventRecord] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM event_base WHERE pet_id = ?
                ORDER BY occurred_at DESC, id ASC
                """, arguments: [petID])
            return try rows.map { try Self.event(from: $0, db: db) }
        }
    }

    /// Every pet's events, newest first (the All-pets timeline). Detail rows
    /// join exactly like `listEvents(petID:)` via the shared row mapping.
    func listAllEvents() throws -> [EventRecord] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM event_base
                ORDER BY occurred_at DESC, id ASC
                """)
            return try rows.map { try Self.event(from: $0, db: db) }
        }
    }

    /// Pull-merge upsert: normalizes timestamps, replaces base + detail
    /// atomically only when the server `updated_at` is newer, and skips
    /// locally-deleted rows.
    func upsertEvent(_ record: EventRecord) throws {
        guard !record.id.isEmpty else { return }
        var incoming = record
        incoming.occurredAt = RFC3339Milli.normalize(record.occurredAt)
        incoming.nextDueAt = Self.normalizedTimestamp(record.nextDueAt)
        incoming.createdAt = RFC3339Milli.normalize(record.createdAt)
        incoming.updatedAt = RFC3339Milli.normalize(record.updatedAt)
        try queue.write { db in
            if try Self.locallyDeleted(db: db, resource: SyncResource.event.rawValue, recordID: incoming.id) {
                return
            }
            if let current = try Self.fetchEvent(db: db, id: incoming.id),
               current.updatedAt >= incoming.updatedAt {
                return
            }
            try Self.replaceEventRow(db: db, incoming)
        }
    }

    // MARK: Intakes

    /// Inserts an intake row + an `intake`/`create` outbox row carrying the
    /// record JSON. `markedBy` stamps the actor (IntakeRecord's `markedBy`).
    func createIntake(_ record: IntakeRecord, markedBy: String) throws -> IntakeRecord {
        let now = RFC3339Milli.nowString()
        var stored = record
        stored.id = createID(record.id)
        stored.markedBy = markedBy
        stored.createdAt = now
        stored.updatedAt = now
        stored.dueAt = Self.normalizedTimestamp(record.dueAt)
        stored.takenAt = Self.normalizedTimestamp(record.takenAt)
        let payload = stored
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO med_intakes
                    (id, household_id, course_id, due_at, status, taken_at,
                     dose_snapshot, note, marked_by, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    stored.id, stored.householdID, stored.courseID, stored.dueAt,
                    stored.status, stored.takenAt, stored.doseSnapshot,
                    stored.note, stored.markedBy, stored.createdAt, stored.updatedAt
                ])
            try Self.enqueueOutbox(
                db: db, resource: SyncResource.intake.rawValue,
                recordID: stored.id, op: "create", payload: payload
            )
        }
        return stored
    }

    /// Alias using the uniform `updatedBy` label (maps to `markedBy`).
    func createIntake(_ record: IntakeRecord, updatedBy: String) throws -> IntakeRecord {
        try createIntake(record, markedBy: updatedBy)
    }

    /// Full-replace update guarded by `baseUpdatedAt` (mismatch or missing
    /// row throws `staleBase`, row untouched). The wire body carries only
    /// `status`/`taken_at`/`note`/`dose_snapshot`, so `due_at`/`course_id`/
    /// `household_id`/`created_at` echo the stored row; everything else comes
    /// from `record` with `markedBy` restamped.
    func updateIntake(
        _ record: IntakeRecord,
        baseUpdatedAt: String,
        markedBy: String
    ) throws -> IntakeRecord {
        let base = RFC3339Milli.normalize(baseUpdatedAt)
        return try queue.write { db -> IntakeRecord in
            guard let current = try Self.fetchIntake(db: db, id: record.id),
                  current.updatedAt == base
            else { throw LocalStoreError.staleBase }
            var stored = record
            stored.id = current.id
            stored.householdID = current.householdID
            stored.courseID = current.courseID
            stored.dueAt = current.dueAt
            stored.createdAt = current.createdAt
            stored.updatedAt = RFC3339Milli.nowString()
            stored.markedBy = markedBy
            stored.takenAt = Self.normalizedTimestamp(record.takenAt)
            try db.execute(sql: """
                UPDATE med_intakes
                SET status = ?, taken_at = ?, dose_snapshot = ?, note = ?,
                    marked_by = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [
                    stored.status, stored.takenAt, stored.doseSnapshot,
                    stored.note, stored.markedBy, stored.updatedAt, stored.id
                ])
            let body = IntakeUpdateBody(
                baseUpdatedAt: base, status: stored.status,
                takenAt: stored.takenAt, note: stored.note,
                doseSnapshot: stored.doseSnapshot
            )
            try Self.enqueueOutbox(
                db: db, resource: SyncResource.intake.rawValue,
                recordID: stored.id, op: "update", payload: body
            )
            return stored
        }
    }

    /// Alias using the uniform `updatedBy` label (maps to `markedBy`).
    func updateIntake(
        _ record: IntakeRecord,
        baseUpdatedAt: String,
        updatedBy: String
    ) throws -> IntakeRecord {
        try updateIntake(record, baseUpdatedAt: baseUpdatedAt, markedBy: updatedBy)
    }

    /// Deletes the intake row, with NO outbox row.
    func removeIntakeLocal(id: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM med_intakes WHERE id = ?", arguments: [id])
        }
    }

    /// Deletes the intake row and enqueues an `intake`/`delete` outbox row.
    /// `markedBy` is accepted for call-site symmetry and is otherwise unused.
    func deleteIntake(id: String, markedBy _: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM med_intakes WHERE id = ?", arguments: [id])
            try Self.enqueueOutbox(
                db: db, resource: SyncResource.intake.rawValue,
                recordID: id, op: "delete", payload: nil
            )
        }
    }

    /// Alias using the uniform `updatedBy` label.
    func deleteIntake(id: String, updatedBy: String) throws {
        try deleteIntake(id: id, markedBy: updatedBy)
    }

    func getIntake(id: String) throws -> IntakeRecord? {
        try queue.read { db in try Self.fetchIntake(db: db, id: id) }
    }

    /// One course's intakes, earliest due first (undated last).
    func listIntakes(courseID: String) throws -> [IntakeRecord] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM med_intakes WHERE course_id = ?
                ORDER BY due_at IS NULL, due_at ASC, id ASC
                """, arguments: [courseID])
                .map(Self.intake(from:))
        }
    }

    /// Pull-merge upsert: normalizes timestamps, replaces the full row only
    /// when the server `updated_at` is newer, and skips locally-deleted rows.
    func upsertIntake(_ record: IntakeRecord) throws {
        guard !record.id.isEmpty else { return }
        var incoming = record
        incoming.dueAt = Self.normalizedTimestamp(record.dueAt)
        incoming.takenAt = Self.normalizedTimestamp(record.takenAt)
        incoming.createdAt = RFC3339Milli.normalize(record.createdAt)
        incoming.updatedAt = RFC3339Milli.normalize(record.updatedAt)
        try queue.write { db in
            if try Self.locallyDeleted(db: db, resource: SyncResource.intake.rawValue, recordID: incoming.id) {
                return
            }
            if let current = try Self.fetchIntake(db: db, id: incoming.id),
               current.updatedAt >= incoming.updatedAt {
                return
            }
            try Self.replaceIntakeRow(db: db, incoming)
        }
    }

    // MARK: Documents

    /// Inserts a document row + its pet-link set (replaced wholesale) + a
    /// `document`/`create` outbox row carrying the record JSON.
    func createDocument(_ record: DocumentRecord, updatedBy: String) throws -> DocumentRecord {
        let now = RFC3339Milli.nowString()
        var stored = record
        stored.id = createID(record.id)
        stored.createdAt = now
        stored.updatedAt = now
        stored.updatedBy = updatedBy
        let payload = stored
        try queue.write { db in
            try Self.insertDocumentRow(db: db, stored)
            try Self.enqueueOutbox(
                db: db, resource: SyncResource.document.rawValue,
                recordID: stored.id, op: "create", payload: payload
            )
        }
        return stored
    }

    /// Full-replace update guarded by `baseUpdatedAt` (mismatch or missing
    /// row throws `staleBase`, row untouched). The wire body carries only
    /// `title`/`pet_ids`, so metadata (`mime`, `size_bytes`, `filename`,
    /// `blob_key`, `ready`, `extracted_text`) echoes the stored row; `title`/
    /// links come from `record` (link set replaced wholesale).
    func updateDocument(
        _ record: DocumentRecord,
        baseUpdatedAt: String,
        updatedBy: String
    ) throws -> DocumentRecord {
        let base = RFC3339Milli.normalize(baseUpdatedAt)
        return try queue.write { db -> DocumentRecord in
            guard let current = try Self.fetchDocument(db: db, id: record.id),
                  current.updatedAt == base
            else { throw LocalStoreError.staleBase }
            var stored = current
            stored.title = record.title
            stored.petIDs = record.petIDs
            stored.updatedAt = RFC3339Milli.nowString()
            stored.updatedBy = updatedBy
            try Self.replaceDocumentRow(db: db, stored)
            let body = DocumentUpdateBody(
                baseUpdatedAt: base, title: stored.title, petIDs: stored.petIDs
            )
            try Self.enqueueOutbox(
                db: db, resource: SyncResource.document.rawValue,
                recordID: stored.id, op: "update", payload: body
            )
            return stored
        }
    }

    /// Deletes the document row + its pet links, with NO outbox row.
    func removeDocumentLocal(id: String) throws {
        try queue.write { db in
            try Self.deleteDocumentRow(db: db, id: id)
        }
    }

    /// Deletes the document row + its pet links and enqueues a
    /// `document`/`delete` outbox row. `updatedBy` is accepted for call-site
    /// symmetry and is otherwise unused.
    func deleteDocument(id: String, updatedBy _: String) throws {
        try queue.write { db in
            try Self.deleteDocumentRow(db: db, id: id)
            try Self.enqueueOutbox(
                db: db, resource: SyncResource.document.rawValue,
                recordID: id, op: "delete", payload: nil
            )
        }
    }

    func getDocument(id: String) throws -> DocumentRecord? {
        try queue.read { db in try Self.fetchDocument(db: db, id: id) }
    }

    /// The household library, newest first.
    func listDocuments() throws -> [DocumentRecord] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM documents ORDER BY created_at DESC, id ASC
                """)
            return try rows.map { try Self.document(from: $0, db: db) }
        }
    }

    /// Pull-merge upsert: normalizes timestamps, replaces the row + link set
    /// only when the server `updated_at` is newer, and skips locally-deleted
    /// rows.
    func upsertDocument(_ record: DocumentRecord) throws {
        guard !record.id.isEmpty else { return }
        var incoming = record
        incoming.createdAt = RFC3339Milli.normalize(record.createdAt)
        incoming.updatedAt = RFC3339Milli.normalize(record.updatedAt)
        try queue.write { db in
            if try Self.locallyDeleted(db: db, resource: SyncResource.document.rawValue, recordID: incoming.id) {
                return
            }
            if let current = try Self.fetchDocument(db: db, id: incoming.id),
               current.updatedAt >= incoming.updatedAt {
                return
            }
            try Self.replaceDocumentRow(db: db, incoming)
        }
    }

    // MARK: Tombstones + snapshots

    /// Applies relay tombstones: per resource calls the `remove*Local` path
    /// (no outbox rows). Unknown resources are ignored (forward-compat).
    func applyDeletions(_ tombstones: [TombstoneRecord]) throws {
        for tombstone in tombstones {
            switch tombstone.resource {
            case SyncResource.pet.rawValue:
                try removePetLocal(id: tombstone.recordID)
            case SyncResource.event.rawValue:
                try removeEventLocal(id: tombstone.recordID)
            case SyncResource.intake.rawValue:
                try removeIntakeLocal(id: tombstone.recordID)
            case SyncResource.document.rawValue:
                try removeDocumentLocal(id: tombstone.recordID)
            default:
                continue
            }
        }
    }

    /// Restores every record in an undo snapshot (full row + detail/links),
    /// with no outbox rows. Unknown resources are skipped, not failed.
    func applySnapshot(_ snapshot: DeletionSnapshot) throws {
        try queue.write { db in
            try Self.applySnapshot(db, snapshot)
        }
    }

    // MARK: Domain row helpers (Database-handle level)

    /// Normalizes an optional RFC3339 timestamp, preserving nil.
    /// Unparseable values pass through unchanged (RFC3339Milli contract).
    private static func normalizedTimestamp(_ value: String?) -> String? {
        value.map(RFC3339Milli.normalize)
    }

    private static func pet(from row: Row) -> PetRecord {
        let id: String = row["id"]
        let householdID: String = row["household_id"]
        let name: String = row["name"]
        let species: String = row["species"]
        let birthdate: String? = row["birthdate"]
        let notes: String = row["notes"]
        let createdAt: String = row["created_at"]
        let updatedAt: String = row["updated_at"]
        let updatedBy: String = row["updated_by"]
        return PetRecord(
            id: id, householdID: householdID, name: name, species: species,
            birthdate: birthdate, notes: notes,
            createdAt: createdAt, updatedAt: updatedAt, updatedBy: updatedBy
        )
    }

    private static func fetchPet(db: Database, id: String) throws -> PetRecord? {
        try Row.fetchOne(db, sql: "SELECT * FROM pets WHERE id = ?", arguments: [id])
            .map(pet(from:))
    }

    private static func replacePetRow(db: Database, _ pet: PetRecord) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO pets
                (id, household_id, name, species, birthdate, notes,
                 created_at, updated_at, updated_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                pet.id, pet.householdID, pet.name, pet.species,
                pet.birthdate, pet.notes,
                pet.createdAt, pet.updatedAt, pet.updatedBy
            ])
    }

    private static func deletePetRow(db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM document_pets WHERE pet_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM pets WHERE id = ?", arguments: [id])
    }

    /// Decodes an EventRecord from its flat JSON shape (the shape `create`
    /// persists). EventRecord has no memberwise init (custom Decodable), so
    /// rows are round-tripped through this form.
    private static func decodeEvent(_ dict: [String: Any]) throws -> EventRecord {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(EventRecord.self, from: data)
    }

    /// Encodes one detail member for `decodeEvent`'s flat JSON shape.
    private static func detailJSON(_ value: (any Encodable)?) throws -> Any? {
        guard let value else { return nil }
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(AnyEncodable(value)))
    }

    private static func fetchVaccDetail(db: Database, eventID: String) throws -> VaccDetail? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT * FROM vacc_details WHERE event_id = ?", arguments: [eventID]
        ) else { return nil }
        let vaccine: String = row["vaccine"]
        let batch: String = row["batch"]
        let vet: String = row["vet"]
        let notes: String = row["notes"]
        return VaccDetail(vaccine: vaccine, batch: batch, vet: vet, notes: notes)
    }

    private static func fetchGroomDetail(db: Database, eventID: String) throws -> GroomDetail? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT * FROM grooming_details WHERE event_id = ?", arguments: [eventID]
        ) else { return nil }
        let service: String = row["service"]
        let place: String = row["place"]
        let notes: String = row["notes"]
        return GroomDetail(service: service, place: place, notes: notes)
    }

    private static func fetchWeightDetail(db: Database, eventID: String) throws -> WeightDetail? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT * FROM weight_details WHERE event_id = ?", arguments: [eventID]
        ) else { return nil }
        let grams: Int64 = row["grams"]
        return WeightDetail(grams: grams)
    }

    private static func fetchCourseDetail(db: Database, eventID: String) throws -> MedCourseRecord? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT * FROM med_courses WHERE event_id = ?", arguments: [eventID]
        ) else { return nil }
        let drugName: String = row["drug_name"]
        let doseAmount: String = row["dose_amount"]
        let doseUnit: String = row["dose_unit"]
        let route: String = row["route"]
        let scheduleKind: String = row["schedule_kind"]
        let scheduleTimes: String = row["schedule_times"]
        let scheduleWeekdays: String = row["schedule_weekdays"]
        let durationDays: Int = row["duration_days"]
        let endsOn: String? = row["ends_on"]
        let status: String = row["status"]
        let instructions: String = row["instructions"]
        let infoRef: String = row["info_ref"]
        return MedCourseRecord(
            drugName: drugName, doseAmount: doseAmount, doseUnit: doseUnit,
            route: route, scheduleKind: scheduleKind, scheduleTimes: scheduleTimes,
            scheduleWeekdays: scheduleWeekdays, durationDays: durationDays,
            endsOn: endsOn, status: status, instructions: instructions, infoRef: infoRef
        )
    }

    private static func event(from row: Row, db: Database) throws -> EventRecord {
        let id: String = row["id"]
        let householdID: String = row["household_id"]
        let petID: String = row["pet_id"]
        let kind: String = row["kind"]
        let occurredAt: String = row["occurred_at"]
        let nextDueAt: String? = row["next_due_at"]
        let title: String = row["title"]
        let createdAt: String = row["created_at"]
        let updatedAt: String = row["updated_at"]
        let updatedBy: String = row["updated_by"]
        var dict: [String: Any] = [
            "id": id, "household_id": householdID, "pet_id": petID, "kind": kind,
            "occurred_at": occurredAt, "title": title,
            "created_at": createdAt, "updated_at": updatedAt, "updated_by": updatedBy
        ]
        if let nextDueAt { dict["next_due_at"] = nextDueAt }
        if let json = try detailJSON(fetchVaccDetail(db: db, eventID: id)) {
            dict["vaccination"] = json
        }
        if let json = try detailJSON(fetchGroomDetail(db: db, eventID: id)) {
            dict["grooming"] = json
        }
        if let json = try detailJSON(fetchWeightDetail(db: db, eventID: id)) {
            dict["weight"] = json
        }
        if let json = try detailJSON(fetchCourseDetail(db: db, eventID: id)) {
            dict["course"] = json
        }
        return try decodeEvent(dict)
    }

    private static func fetchEvent(db: Database, id: String) throws -> EventRecord? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT * FROM event_base WHERE id = ?", arguments: [id]
        ) else { return nil }
        return try event(from: row, db: db)
    }

    private static func insertEventRow(db: Database, _ event: EventRecord) throws {
        try db.execute(sql: """
            INSERT INTO event_base
                (id, household_id, pet_id, kind, occurred_at, next_due_at, title,
                 created_at, updated_at, updated_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                event.id, event.householdID, event.petID, event.kind,
                event.occurredAt, event.nextDueAt, event.title,
                event.createdAt, event.updatedAt, event.updatedBy
            ])
        try insertEventDetail(db: db, event)
    }

    private static func insertEventDetail(db: Database, _ event: EventRecord) throws {
        if let detail = event.vaccination {
            try db.execute(sql: """
                INSERT INTO vacc_details (event_id, vaccine, batch, vet, notes)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [event.id, detail.vaccine, detail.batch, detail.vet, detail.notes])
        }
        if let detail = event.grooming {
            try db.execute(sql: """
                INSERT INTO grooming_details (event_id, service, place, notes)
                VALUES (?, ?, ?, ?)
                """, arguments: [event.id, detail.service, detail.place, detail.notes])
        }
        if let detail = event.weight {
            try db.execute(sql: """
                INSERT INTO weight_details (event_id, grams) VALUES (?, ?)
                """, arguments: [event.id, detail.grams])
        }
        if let detail = event.course {
            try db.execute(sql: """
                INSERT INTO med_courses
                    (event_id, drug_name, dose_amount, dose_unit, route,
                     schedule_kind, schedule_times, schedule_weekdays,
                     duration_days, ends_on, status, instructions, info_ref)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    event.id, detail.drugName, detail.doseAmount, detail.doseUnit,
                    detail.route, detail.scheduleKind, detail.scheduleTimes,
                    detail.scheduleWeekdays, detail.durationDays, detail.endsOn,
                    detail.status, detail.instructions, detail.infoRef
                ])
        }
    }

    private static func replaceEventRow(db: Database, _ event: EventRecord) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO event_base
                (id, household_id, pet_id, kind, occurred_at, next_due_at, title,
                 created_at, updated_at, updated_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                event.id, event.householdID, event.petID, event.kind,
                event.occurredAt, event.nextDueAt, event.title,
                event.createdAt, event.updatedAt, event.updatedBy
            ])
        try db.execute(sql: "DELETE FROM vacc_details WHERE event_id = ?", arguments: [event.id])
        try db.execute(sql: "DELETE FROM grooming_details WHERE event_id = ?", arguments: [event.id])
        try db.execute(sql: "DELETE FROM weight_details WHERE event_id = ?", arguments: [event.id])
        try db.execute(sql: "DELETE FROM med_courses WHERE event_id = ?", arguments: [event.id])
        try insertEventDetail(db: db, event)
    }

    private static func deleteEventRow(db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM vacc_details WHERE event_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM grooming_details WHERE event_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM weight_details WHERE event_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM med_courses WHERE event_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM event_base WHERE id = ?", arguments: [id])
    }

    private static func intake(from row: Row) -> IntakeRecord {
        let id: String = row["id"]
        let householdID: String = row["household_id"]
        let courseID: String = row["course_id"]
        let dueAt: String? = row["due_at"]
        let status: String = row["status"]
        let takenAt: String? = row["taken_at"]
        let doseSnapshot: String = row["dose_snapshot"]
        let note: String = row["note"]
        let markedBy: String = row["marked_by"]
        let createdAt: String = row["created_at"]
        let updatedAt: String = row["updated_at"]
        return IntakeRecord(
            id: id, householdID: householdID, courseID: courseID, dueAt: dueAt,
            status: status, takenAt: takenAt, doseSnapshot: doseSnapshot,
            note: note, markedBy: markedBy, createdAt: createdAt, updatedAt: updatedAt
        )
    }

    private static func fetchIntake(db: Database, id: String) throws -> IntakeRecord? {
        try Row.fetchOne(db, sql: "SELECT * FROM med_intakes WHERE id = ?", arguments: [id])
            .map(intake(from:))
    }

    private static func replaceIntakeRow(db: Database, _ intake: IntakeRecord) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO med_intakes
                (id, household_id, course_id, due_at, status, taken_at,
                 dose_snapshot, note, marked_by, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                intake.id, intake.householdID, intake.courseID, intake.dueAt,
                intake.status, intake.takenAt, intake.doseSnapshot,
                intake.note, intake.markedBy, intake.createdAt, intake.updatedAt
            ])
    }

    private static func documentLinks(db: Database, documentID: String) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT pet_id FROM document_pets WHERE document_id = ? ORDER BY rowid
            """, arguments: [documentID])
    }

    private static func document(from row: Row, db: Database) throws -> DocumentRecord {
        let id: String = row["id"]
        let householdID: String = row["household_id"]
        let title: String = row["title"]
        let mime: String = row["mime"]
        let sizeBytes: Int64 = row["size_bytes"]
        let filename: String = row["filename"]
        let blobKey: String = row["blob_key"]
        let readyInt: Int64 = row["ready"]
        let extractedText: String = row["extracted_text"]
        let createdAt: String = row["created_at"]
        let updatedAt: String = row["updated_at"]
        let updatedBy: String = row["updated_by"]
        return DocumentRecord(
            id: id, householdID: householdID, title: title, mime: mime,
            sizeBytes: sizeBytes, filename: filename, blobKey: blobKey,
            ready: readyInt != 0, extractedText: extractedText,
            petIDs: try documentLinks(db: db, documentID: id),
            createdAt: createdAt, updatedAt: updatedAt, updatedBy: updatedBy
        )
    }

    private static func fetchDocument(db: Database, id: String) throws -> DocumentRecord? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT * FROM documents WHERE id = ?", arguments: [id]
        ) else { return nil }
        return try document(from: row, db: db)
    }

    private static func insertDocumentLinks(db: Database, _ document: DocumentRecord) throws {
        for petID in document.petIDs {
            try db.execute(sql: """
                INSERT OR IGNORE INTO document_pets (document_id, pet_id) VALUES (?, ?)
                """, arguments: [document.id, petID])
        }
    }

    private static func insertDocumentRow(db: Database, _ document: DocumentRecord) throws {
        try db.execute(sql: """
            INSERT INTO documents
                (id, household_id, title, mime, size_bytes, filename, blob_key,
                 ready, extracted_text, created_at, updated_at, updated_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                document.id, document.householdID, document.title, document.mime,
                document.sizeBytes, document.filename, document.blobKey,
                document.ready ? 1 : 0, document.extractedText,
                document.createdAt, document.updatedAt, document.updatedBy
            ])
        try insertDocumentLinks(db: db, document)
    }

    private static func replaceDocumentRow(db: Database, _ document: DocumentRecord) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO documents
                (id, household_id, title, mime, size_bytes, filename, blob_key,
                 ready, extracted_text, created_at, updated_at, updated_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                document.id, document.householdID, document.title, document.mime,
                document.sizeBytes, document.filename, document.blobKey,
                document.ready ? 1 : 0, document.extractedText,
                document.createdAt, document.updatedAt, document.updatedBy
            ])
        try db.execute(
            sql: "DELETE FROM document_pets WHERE document_id = ?",
            arguments: [document.id]
        )
        try insertDocumentLinks(db: db, document)
    }

    private static func deleteDocumentRow(db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM document_pets WHERE document_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [id])
    }

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
            try Self.pendingDelete(db: db, resource: resource, recordID: recordID)
        }
    }

    /// Whether `(resource, recordID)` sits in the durable undo buffer: a
    /// deletion the user can still undo, with no outbox row yet. The relay
    /// still holds the record, so an unguarded pull would resurrect it and
    /// the later commit would leave a permanent zombie behind.
    func isBufferedForDeletion(resource: String, recordID: String) throws -> Bool {
        try queue.read { db in
            try Self.bufferedForDeletion(db: db, resource: resource, recordID: recordID)
        }
    }

    /// Whether a pull-merge must skip this record: the user deleted it
    /// locally (buffered undoable deletion or committed outbox delete) and
    /// the relay has not converged yet. Undo restores the row and clears the
    /// buffer, and a successful drain clears the outbox row — both lift the
    /// guard, so newer server versions merge normally afterwards.
    func isLocallyDeleted(resource: String, recordID: String) throws -> Bool {
        try queue.read { db in
            try Self.locallyDeleted(db: db, resource: resource, recordID: recordID)
        }
    }

    /// Database-handle variants of the delete guards above, for use inside a
    /// write transaction (upserts check delete-wins atomically with the
    /// replace). Semantics are identical to the queue-level versions.
    private static func pendingDelete(
        db: Database,
        resource: String,
        recordID: String
    ) throws -> Bool {
        let count = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM outbox
            WHERE resource = ? AND record_id = ? AND op = 'delete'
            """, arguments: [resource, recordID]) ?? 0
        return count > 0
    }

    private static func bufferedForDeletion(
        db: Database,
        resource: String,
        recordID: String
    ) throws -> Bool {
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

    private static func locallyDeleted(
        db: Database,
        resource: String,
        recordID: String
    ) throws -> Bool {
        try pendingDelete(db: db, resource: resource, recordID: recordID)
            || bufferedForDeletion(db: db, resource: resource, recordID: recordID)
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

    /// Re-inserts every snapshot record (full row + detail/links), with no
    /// outbox rows. Called from `undoBufferRestore` (which runs inside its own
    /// write) and from the public `applySnapshot(_:)`. Unknown resources are
    /// skipped (forward-compat), not failed; corrupt data for a KNOWN
    /// resource throws.
    private static func applySnapshot(_ db: Database, _ snapshot: DeletionSnapshot) throws {
        for record in snapshot.records {
            switch record.resource {
            case SyncResource.pet.rawValue:
                let pet = try JSONDecoder().decode(PetRecord.self, from: record.data)
                try replacePetRow(db: db, pet)
            case SyncResource.event.rawValue:
                let event = try JSONDecoder().decode(EventRecord.self, from: record.data)
                try replaceEventRow(db: db, event)
            case SyncResource.intake.rawValue:
                let intake = try JSONDecoder().decode(IntakeRecord.self, from: record.data)
                try replaceIntakeRow(db: db, intake)
            case SyncResource.document.rawValue:
                let document = try JSONDecoder().decode(DocumentRecord.self, from: record.data)
                try replaceDocumentRow(db: db, document)
            default:
                continue
            }
        }
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
        boundHouseholdID = nil
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

    /// Deletes the ACTIVE household's database file with its SQLite
    /// sidecars and unbinds the store. Used by account deletion when the
    /// target is the active account: the queue is released first (the
    /// caller's own shared handle must be gone before the exclusive
    /// cross-process erase) and the store ends unbound — the file must not
    /// be reopened or recreated afterwards. A missing file (and missing
    /// sidecars) is success. Failures propagate for a caller-side retry and
    /// the URL is kept for retry.
    func eraseActiveHousehold() throws {
        try eraseAll()
    }

    /// Deletes the database file of the EXPLICITLY identified household —
    /// active or dormant — with its SQLite sidecars, and never touches any
    /// other household's file. When the target is ACTIVE, the queue is
    /// released first and the store ends unbound. When the target is dormant,
    /// the active store is left completely alone.
    ///
    /// - Parameter baseURL: overrides the App Group container (tests pin a
    ///   throwaway directory; production uses the shared container).
    func eraseHousehold(householdID: String, in baseURL: URL? = nil) throws {
        let sanitized = try Self.sanitizedFileID(householdID)
        let url = Self.databaseURL(householdID: sanitized, in: baseURL)
        let wasActive = (boundHouseholdID == sanitized)
        if wasActive {
            dbQueue = nil
            boundURL = nil
            boundHouseholdID = nil
            undoPushInFlight = false
        }
        do {
            try Self.removeDatabaseFiles(at: url)
            if lastBoundURL == url { lastBoundURL = nil }
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            if lastBoundURL == url { lastBoundURL = nil }
        } catch {
            if wasActive { lastBoundURL = url }
            throw error
        }
    }

    /// Legacy account-deletion entry point. The coordinator calls this with
    /// the deleted user's id; v1 files are household-scoped, so the user id
    /// cannot name the file. Behavior: when the store is BOUND (active
    /// household file open), erase the active file — the coordinator only
    /// calls this for the active target. When UNBOUND (dormant target),
    /// best-effort remove the legacy per-account file `shunik_<userID>.db`
    /// if migration debris exists; household files of dormant households are
    /// left for their next active session. Never touches a bound file that
    /// is not the target: coordinators must use `eraseHousehold` with the
    /// resolved id, or `eraseActiveHousehold` for the active target.
    func eraseAccount(userID: String, in baseURL: URL? = nil) throws {
        if boundURL != nil || boundHouseholdID != nil {
            try eraseActiveHousehold()
            return
        }
        let sanitized = try Self.sanitizedFileID(userID)
        let container = baseURL ?? Self.appGroupBase()
        let legacyURL = container.appendingPathComponent("shunik_\(sanitized).db")
        try Self.removeDatabaseFiles(at: legacyURL)
        if lastBoundURL == legacyURL { lastBoundURL = nil }
    }

    /// Deletes an EXPLICIT database file URL with its SQLite sidecars. When
    /// the URL is the bound (or last-bound) file, the store unbinds first
    /// (the queue holds the file open) and clears the slot — the same
    /// release-before-erase discipline as `eraseAll`. Used by account
    /// deletion with the exact file the household resolver selected, so a
    /// dormant household's file can never be retargeted.
    func eraseFile(at url: URL) throws {
        if boundURL == url || lastBoundURL == url {
            dbQueue = nil
            boundURL = nil
            boundHouseholdID = nil
            undoPushInFlight = false
        }
        do {
            try Self.removeDatabaseFiles(at: url)
            if lastBoundURL == url { lastBoundURL = nil }
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            if lastBoundURL == url { lastBoundURL = nil }
        } catch {
            if boundURL == url || lastBoundURL == url { lastBoundURL = url }
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
