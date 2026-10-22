# local-first-store Specification

## Purpose

The on-device source of truth for the user's time-tracking data — a SQLite database in the App Group shared container that the app, widgets, extensions, and lock-screen Controls all read and write cross-process.
## Requirements
### Requirement: Device is the source of truth
The system SHALL treat the active signed-in account's local SQLite database in the App Group shared container as the authoritative source of the user's categories, entries, entry-category assignments, and running timer draft. All app features (timer, history, insights) SHALL operate against this active account's database while the user is signed in, and SHALL function fully with no network connectivity. No app feature SHALL operate against any local database while the user is signed out: the auth gate is the only reachable surface, and it SHALL neither read nor write tracker data.

#### Scenario: App launches with no account
- **WHEN** the app is installed and launched for the first time, with no signed-in session
- **THEN** the auth gate precedes all data access: no anonymous timer, categories, or history is available, the app presents only the auth flow, and no tracker feature operates until sign-in completes

#### Scenario: Sync is unavailable
- **WHEN** the user is signed in but offline, or is not signed in
- **THEN** a signed-in user retains full local function (timer, categories, history) against the active account's database with no network connectivity, while a signed-out user has no tracker function and remains at the auth gate

### Requirement: App Group shared container
The system SHALL store the local database in an App Group shared container (`group.com.antonkosenko.timeoflifeapp`) so that the main app, widget extensions, Screen Time extension, and lock-screen Control intents can read and write the same data cross-process.

#### Scenario: Widget reads catalog
- **WHEN** a home-screen widget renders and reads the activities table from the shared container
- **THEN** it sees the same records the main app wrote, without a separate copy or IPC handshake

#### Scenario: Extension writes entry
- **WHEN** the Screen Time extension writes an entry to the shared container database
- **THEN** the main app observes that entry on its next foreground, without an explicit IPC call

### Requirement: Data protection level
The system SHALL store the local database with iOS data protection `.completeUntilFirstUserAuthentication` (the App Group container default), so that the database is accessible to lock-screen Control intents after the device has been unlocked at least once since boot.

#### Scenario: Lock-screen Control after first unlock
- **WHEN** the device was unlocked at least once since boot and is now locked, and a lock-screen Control intent runs with `alwaysAllowed` authentication policy
- **THEN** the intent can open and write to the shared container database successfully

#### Scenario: Database inaccessible after cold boot
- **WHEN** the device was just rebooted and has never been unlocked since boot, and a lock-screen Control intent runs
- **THEN** the intent fails gracefully (catches the database-open error), returns a "please unlock" state to the Control, and does not crash or leave the data in an inconsistent state

### Requirement: Running timer state persistence
The system SHALL persist the running timer's draft state (entry text, ordered category ids, notes, started_at, status) in the local database, not solely in app memory, so that the timer survives app crashes and is readable by widgets and lock-screen Controls. Widgets and Controls SHALL continue to read only text/status/elapsed and SHALL ignore the notes column.

#### Scenario: Timer survives app crash
- **WHEN** a timer is running and the app crashes or is killed by the OS
- **THEN** on next launch the app reads the draft from the database and resumes the running-timer UI (shows the elapsed time, the locked text, the tags as left, and the draft notes as left)

#### Scenario: Control displays running timer
- **WHEN** a lock-screen Control or widget renders while a timer is running
- **THEN** it reads the draft from the shared container database and displays the running status and elapsed time

### Requirement: Transactional outbox
The system SHALL record every local mutation (create, update, delete) as a row in a transactional `outbox` table, written in the same database transaction as the state change. The outbox is the durable queue of operations to propagate to the backend relay when sync is active.

#### Scenario: Create writes state and outbox atomically
- **WHEN** the user creates a new activity
- **THEN** the system writes the activity row and an outbox row (op=create, resource=activity, record_id, payload) in a single transaction; if either write fails, neither is committed

#### Scenario: Delete is first-class in the outbox
- **WHEN** the user deletes an activity and the 30s undo window has elapsed
- **THEN** the system deletes the activity row and inserts an outbox row (op=delete, resource=activity, record_id) in one transaction; the outbox row persists even though the activity row is gone

#### Scenario: Outbox survives relaunch
- **WHEN** the app is killed and relaunched with pending outbox rows
- **THEN** the outbox rows are still present and will be drained by the sync client when it next runs

### Requirement: Durable undo buffer
The system SHALL hold deletions in a durable `undo_buffer` table (not in-memory) with no wall-clock window: a buffered deletion stays restorable until the app restarts. No outbox row is created while a deletion is in the undo buffer. A buffered deletion commits on cold launch (the backstop that inserts the outbox rows) or on the next successful sync push (push-then-commit): the sync client sends one `DELETE` per snapshotted record and drops the buffer row only after all its pushes succeed. While a buffered row's push is in flight, undo of that row is refused (transient guard); otherwise undo restores the records and drops the row with no outbox row ever created, so the backend relay is never notified of the deletion. Only the most recent buffered deletion is restorable (supersession); older rows stay buffered until undone or the app restarts. Entries and categories share this buffer.

#### Scenario: Delete enters buffer atomically
- **WHEN** the user confirms deletion of an entry or category
- **THEN** the system writes an undo_buffer row (containing a full serialized snapshot of the deleted records) and deletes the records in one transaction; no outbox row is created

#### Scenario: Undo within window restores records
- **WHEN** the user triggers undo while the process is still alive (no wall-clock window — restorable until restart)
- **THEN** the system restores the records from the buffer's payload and deletes the buffer row in one transaction; no outbox row is ever created, so the backend relay is never notified of the deletion

#### Scenario: Push commits the buffer
- **WHEN** a sync cycle pushes every snapshotted record's `DELETE` successfully
- **THEN** the system drops the buffer row in the same step; a later undo finds nothing to restore

#### Scenario: Window elapses in background
- **WHEN** the app is backgrounded or foregrounded while the process stays alive (no wall-clock window exists)
- **THEN** no commit occurs on any time boundary; buffered rows remain restorable until restart or a successful push

#### Scenario: Undo after cold launch within window
- **WHEN** the app was killed and relaunched with the buffered row still present (no wall-clock window — commit-on-restart replaces the window)
- **THEN** the system commits the buffered deletion (drops the buffer row and inserts the outbox rows) with no restore path afterwards; no unsolicited UndoToast is shown on cold launch

#### Scenario: Supersession
- **WHEN** the user performs a second undoable deletion while a first is still in the buffer
- **THEN** only the most recent deletion is restorable; the older deletion stays buffered until undone or the app restarts

#### Scenario: In-flight push refuses undo
- **WHEN** the user triggers undo for a buffered row while its `DELETE` push is in flight
- **THEN** the undo is refused with the existing persistence error; the push completes and drops the row, or fails and leaves the row undoable for the next cycle

### Requirement: Sign-out preserves local data
The system SHALL NOT wipe any per-account local database, outbox, or undo buffer when the user signs out. All per-account files, including the dormant file of the signed-out account and its pending dirty outbox, SHALL be kept on disk; re-signing in as the same existing account SHALL reopen its file and resume draining the outbox, continuing sync cursors, and resuming a dormant running timer draft. The user's local data persists across sign-out, including externally revoked Apple consent. An explicit per-account Delete local data action SHALL be available in Profile → Account for shared-device or privacy cases and SHALL delete only the active account's local file with its associated session Keychain/cache entries; it MUST NOT touch other accounts' dormant files, delete the server account, or remove synced server data. Confirming Delete local data SHALL additionally sign out and reset auth navigation to its first step with no previous address. The Account Delete local data row SHALL present with a danger-styled icon/title and destructive semantics. Explicit account deletion and independently confirmed account-deletion cleanup are separate operations defined by `account-deletion`, not sign-out side effects.

#### Scenario: Sign out keeps data
- **WHEN** the user signs out
- **THEN** the signed-out account's local database file is kept with its outbox intact, no other account's data is affected, and re-signing in as that existing account resumes from the dormant file

#### Scenario: Explicit erase
- **WHEN** the user taps Delete local data in Account and confirms
- **THEN** only the active account's local database file and associated outbox/undo/session-cache artifacts are removed; unrelated dormant files and relay account/data remain untouched, and the action is destructive and irreversible locally

#### Scenario: Erase row warns as destructive
- **WHEN** the user views Account's device-only section
- **THEN** Delete local data shows a danger-styled trash icon/title and destructive semantics with helper text explaining that relay data is retained

#### Scenario: Erase resets auth flow
- **WHEN** local-only deletion succeeds
- **THEN** the user is signed out and auth navigation starts at its first step with no previously entered email

#### Scenario: Local erase fails
- **WHEN** removing the account-local file fails before local-only erase completes
- **THEN** the app reports a retryable error instead of claiming success or silently signing out as though cleanup succeeded
### Requirement: Local deletion tombstone reads

The local store SHALL expose read-only tombstone queries over the existing outbox and undo-buffer tables (no schema change): whether `(resource, record_id)` has a pending outbox DELETE, whether it sits in a buffered deletion snapshot (activity snapshots cover their entries' ids), and the combined exclusion used by the sync client.

#### Scenario: Committed delete is a tombstone until drained

- **WHEN** a deletion commits (outbox DELETE row exists) and has not been drained
- **THEN** the tombstone query reports it deleted; after the drain clears the row, it no longer does

#### Scenario: Buffered delete is a tombstone until undone or committed

- **WHEN** a deletion enters the undo buffer
- **THEN** the tombstone query reports every snapshotted `(resource, record_id)` deleted; after undo (row restored, buffer cleared) or cold-launch commit (buffer cleared, outbox DELETEs queued), the buffered tombstone no longer applies (the outbox one does, until drained)

### Requirement: Tombstone application
The local store SHALL apply a relay tombstone `(resource, record_id, deleted_at)` by removing the local row — entry-category joins cascade for entries and categories — in a single write transaction with no outbox row, and by dropping pending create/update outbox rows for every affected id. Pending DELETE rows SHALL be left untouched. A clean local row newer than the tombstone SHALL be kept (stale tombstone after a recreation).

#### Scenario: Activity tombstone cascades without outbox
- **WHEN** an entry tombstone is applied and the entry has category joins (activity tombstones no longer exist)
- **THEN** the joins and row are removed in one transaction, no outbox row is created, and pending create/update rows for the entry are gone

#### Scenario: Pending deletes survive tombstone application
- **WHEN** an outbox DELETE row exists for the tombstoned id
- **THEN** the DELETE row remains queued (it converges via 404-as-success on drain)

### Requirement: Entries own text, categories, and notes
Each entry SHALL own its `activity_text` (trimmed, non-empty, max 60 chars; case-sensitive identity), its ordered `category_ids` (zero or more, position-preserved via `entry_categories`), and its `notes` (max 2000 trimmed runes, default empty). No entry SHALL reference any other record for its display name or classification.

#### Scenario: Entry saved with all fields
- **WHEN** a valid entry is saved with text, two ordered categories, and notes
- **THEN** all three persist on the entry and read back identically

#### Scenario: Per-entry isolation
- **WHEN** one entry's text, categories, or notes change
- **THEN** no other entry changes

#### Scenario: Notes past the bound are rejected
- **WHEN** an entry holds more than 2000 trimmed runes of notes
- **THEN** the relay rejects the create/update with a notes `validation_error` and the local entry is unchanged

### Requirement: Timer draft holds text and live categories
The `timer_state` singleton SHALL hold `(activity_text, ordered category_ids, notes, started_at, status)` for the running draft. Toggles SHALL rewrite the snapshot in the same chokepoint transaction. Notes saves SHALL rewrite only the notes field in the same chokepoint transaction. Stop SHALL create the entry from the draft (text + final categories + final notes) and clear it.

#### Scenario: Crash restores draft tags
- **WHEN** the app restarts with a persisted running draft
- **THEN** the timer resumes with the locked text and the tags as last left

#### Scenario: Crash restores draft notes
- **WHEN** the app restarts with a persisted running draft holding notes
- **THEN** the timer resumes with the draft notes as last left, and Stop saves the entry with those notes unless edited further

#### Scenario: Mid-run notes edit rewrites the snapshot
- **WHEN** the user saves notes while running
- **THEN** only the draft notes field updates in the same chokepoint transaction; text, categories, and `started_at` are untouched

### Requirement: Anonymous data is discarded on first login
Because this change ships pre-release, the system SHALL NOT migrate existing anonymous or prior-dev-install local data into any per-account database file. On the first sign-in under the account-bound model, the system SHALL discard the anonymous local database content and start the signed-in account with its own fresh per-account file. No compatibility branch or legacy-format read path SHALL be kept for anonymous data.

#### Scenario: First login starts fresh
- **WHEN** a user signs in for the first time on a device that holds anonymous pre-release data from a prior install or prior build
- **THEN** the anonymous data is not carried into the account's database; the signed-in account starts with an empty per-account file

#### Scenario: No migration path is retained
- **WHEN** the account-bound model is active
- **THEN** the system performs no anonymous-to-account migration, and no legacy anonymous database branch remains in the store

### Requirement: Starter seeding is per-account-file
The system SHALL seed starter categories into a per-account database file the first time that account's file is opened, and SHALL NOT re-seed it afterward. Each account's file is seeded independently: opening one account's file does not seed, modify, or reset any other account's file.

#### Scenario: New account file is seeded
- **WHEN** an account signs in and its per-account file is opened for the first time
- **THEN** the starter categories are seeded into that account's file and are immediately visible to the signed-in user

#### Scenario: Existing account file is not re-seeded
- **WHEN** the same account re-opens its existing per-account file after sign-out and sign-in
- **THEN** the starter seeding does not run again and the file's existing data is preserved as-is

#### Scenario: Seeding is scoped to the opened account
- **WHEN** an account's file is opened and seeded
- **THEN** no other account's dormant file is created, modified, or seeded as a side effect

