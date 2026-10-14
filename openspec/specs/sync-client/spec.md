# sync-client Specification

## Purpose

The optional background sync layer that, when the user signs in, keeps the local database and the backend relay eventually consistent by draining the outbox and pulling deltas. Activated on sign-in, deactivated on sign-out; the app works fully without it.
## Requirements
### Requirement: Sync is optional and gated on sign-in
The system SHALL activate the sync client only when the user holds an active signed-in session; a valid session is mandatory for every sync operation. When no session is active, the sync client SHALL NOT run: no sync network traffic is sent signed-out, no outbox is drained, and no delta pull runs. Because sign-in precedes tracking (per the app-shell and local-first-store deltas), a signed-out state exists only before the first sign-in or after sign-out with the account's local file dormant, and the outbox drains only after a signed-in session resumes that account's file.

#### Scenario: Unsigned user
- **WHEN** the user has not signed in
- **THEN** the app offers no function without an account — tracking sits behind the sign-in gate — and the sync client performs no operation: no request reaches the backend, the outbox is not drained, and no delta pull runs

#### Scenario: Sign-in activates sync
- **WHEN** the user signs in (OTP or Apple Sign-in) and the account's local file becomes active
- **THEN** the sync client activates for that account, performs a first-sync (pull-then-push), and begins responding to sync triggers

#### Scenario: Sign-out deactivates sync
- **WHEN** the user signs out
- **THEN** the sync client deactivates and stops making requests; the account's local database file and its outbox are preserved intact in the dormant per-user file, so re-signing in as the same account resumes the drain

### Requirement: First-sync is pull-first
On activation, the sync client SHALL pull the relay's current state (via `?modified_since=` with no since, i.e. full pull) and merge it into the local database (server-wins on `updated_at` conflicts) BEFORE draining the local outbox. This avoids cross-device name collisions by letting the relay's ids arrive before local pushes.

#### Scenario: First-sync with empty relay
- **WHEN** the user signs in for the first time (relay has no data for this user)
- **THEN** the pull returns nothing; the outbox drains and pushes all local records; no collisions

#### Scenario: First-sync with existing relay data
- **WHEN** the user previously used sync, signed out, used locally, and re-signs in
- **THEN** the pull brings the relay's current records down and merges them into the local database (server-wins on conflicts); then the outbox drains and pushes any local-only records, which are idempotent on `id` against existing relay records

### Requirement: Delta pull via modified_since
The sync client SHALL pull entries by following relay pagination to exhaustion: starting from `GET /entries` (with `?modified_since=<timestamp>` when a cursor exists, full pull when it does not), the client SHALL keep requesting subsequent pages with the relay's `cursor` parameter until the relay returns no `next_cursor`, and SHALL merge every page with the existing LWW rules. The client SHALL advance the entries sync cursor to the max `updated_at` over ALL pages received in the pull — never to the max of a partial page. A pull is complete only when the relay reports no further page; an empty pull (no records on any page) leaves the cursor unchanged. Cursors recorded before pagination-aware pulls existed are poisoned (a partial-page max that hides older rows from every future delta): the client SHALL discard the persisted `entry` cursor exactly once per account file — guarded by a persisted re-baseline flag — so the next cycle runs a full paged pull and re-converges the complete history through the idempotent LWW merge. `GET /categories` is full-pull by design (catalog small: seeded plus a handful of user rows, so a snapshot merge with newer-owns-the-name is cheap; entries are unbounded and need the cursor): the client SHALL fetch the full category list on every pull and SHALL NOT send a categories cursor.

#### Scenario: Incremental pull
- **WHEN** the sync client runs after a previous successful pull recorded a cursor at time T
- **THEN** it requests `GET /entries?modified_since=T` and follows `next_cursor` pages until exhausted, receiving only records with `updated_at > T` across all pages; it applies them locally with LWW merge and advances the cursor to the max `updated_at` over all pages

#### Scenario: Full-history convergence beyond one page
- **WHEN** the relay holds more entries than one page (e.g. 120 entries at the default page size) and the client runs a full pull with no cursor
- **THEN** every page is fetched and merged, the local database holds the complete set, and no record is skipped regardless of page boundaries

#### Scenario: Cursor advances over all pages
- **WHEN** a pull spans multiple pages whose per-page `updated_at` maxima differ
- **THEN** the recorded entries cursor equals the max `updated_at` across every received page, so a subsequent delta pull returns only records newer than the complete pull

#### Scenario: Delta after a complete paged pull is empty
- **WHEN** a full paged pull converged completely and no record changed since
- **THEN** the next delta pull returns no records, the cursor is unchanged, and no local updates are applied

#### Scenario: Upgrade with a poisoned cursor heals on the next cycle
- **WHEN** the account file holds an `entry` cursor recorded before pagination-aware pulls existed and the re-baseline flag is unset
- **THEN** the next cycle discards that cursor, runs a full paged pull, merges the complete history (LWW-idempotent — no duplicates, no outbox churn), advances the cursor to the global max, and sets the flag; the `deletions` cursor, categories, outbox, undo buffer, and timer state are untouched

#### Scenario: Re-baseline runs exactly once
- **WHEN** the re-baseline flag is already set (or the `entry` cursor is nil, as on fresh installs)
- **THEN** no cursor is discarded and pulls proceed as incremental or full by the normal cursor rules; a second upgrade never triggers another full re-pull

#### Scenario: Mid-pull account swap aborts before further merge
- **WHEN** the authenticated session's `userId` stops matching the cycle's bound account while pages remain unfetched
- **THEN** no further page is fetched or merged and the cycle aborts under the same-account guard, leaving already-merged pages intact and the cursor unadvanced for the incomplete pull

#### Scenario: No changes
- **WHEN** the delta pull returns no records
- **THEN** the cursor is unchanged and no local updates are applied

#### Scenario: Categories always full-pull
- **WHEN** the sync client runs a pull (first sync or delta cycle)
- **THEN** it fetches `GET /categories` with no `modified_since` parameter and merges the full snapshot (newer-owns-the-name), regardless of the entries cursor

### Requirement: Last-write-wins conflict resolution
On pull, the sync client SHALL apply a server record to the local database only if `server.updated_at > local.updated_at` for the same record id; otherwise the local version is kept. On push, a 409 `conflict` response SHALL cause the client to adopt the server's version (keep-latest) and clear the outbox row. There SHALL be no cross-record name-identity remapping: equal or similar texts with different ids are independent records. The relay SHALL compare `updated_at` at millisecond precision for entry and category updates, so two writes within the same second are ordered correctly and only a truly stale `updated_at` conflicts. A stale entry or category update SHALL return 409 `conflict` with the current server version promptly and SHALL never hang or block indefinitely.

#### Scenario: Newer server record overwrites local
- **WHEN** a pulled record has `updated_at` greater than the local record's `updated_at`
- **THEN** the local record is overwritten with the server version

#### Scenario: Newer local record resists server
- **WHEN** a pulled record has `updated_at` less than the local record's `updated_at`
- **THEN** the local record is preserved and the server version is discarded

#### Scenario: Push conflict adopts server version
- **WHEN** the client pushes an outbox row and receives 409 `conflict` with the server's current version in `details`
- **THEN** the client overwrites the local record with the server version, clears the outbox row, and surfaces an informational "Edited on another device" state (non-blocking, keep-latest)

#### Scenario: Pull adopts newer server identity on name collision
- **WHEN** a pulled record's text matches a different local id (name collision under exact-text identity)
- **THEN** no identity remap occurs: equal texts are independent records, the pull applies per-id LWW only, and the cycle continues

#### Scenario: Pull keeps newer local identity on name collision
- **WHEN** a pulled record's text matches a different local id and either side is newer
- **THEN** both records are kept as independent entries or categories; nothing merges, nothing is skipped for collision, and convergence needs no name-freedom step

#### Scenario: Same-second stale entry update conflicts instead of hanging
- **WHEN** a client PATCHes an entry with an `updated_at` equal to the relay's current `updated_at` (same second, same millisecond)
- **THEN** the relay returns 409 `conflict` with the current server version promptly and the request completes (never hangs)

#### Scenario: Same-second stale category update conflicts instead of hanging
- **WHEN** a client PATCHes a category with an `updated_at` equal to the relay's current `updated_at` (same second, same millisecond)
- **THEN** the relay returns 409 `conflict` with the current server version promptly and the request completes (never hangs)

### Requirement: Idempotent outbox drain
The sync client SHALL drain the outbox by issuing one HTTP request per outbox row, in created_at order within a resource. Because POST is idempotent on `id` and PATCH carries `updated_at` (LWW), replaying an outbox row is safe. Entries carry `activity_text`, ordered `category_ids`, and `notes`; a pulled entry referencing a category id absent from the relay snapshot SHALL resolve by dropping the unknown id and keeping the remainder (logged, secret-free), never failing the cycle. A pulled entry referencing a category id present in the relay snapshot but missing locally SHALL NOT be stripped: when a local category with the same name exists the join SHALL be remapped to that local id (local-only rewrite, never enqueued), otherwise the snapshot category row SHALL be merged locally and the id kept.

#### Scenario: Replay after relaunch
- **WHEN** the app was killed mid-drain and relaunched, leaving some outbox rows already pushed and some not
- **THEN** re-pushing the already-pushed rows returns 200 (idempotent) or 409 (already newer) — both treated as success — and the outbox clears cleanly

#### Scenario: Entry with unknown category is pruned
- **WHEN** a pulled entry references a category id absent from the relay snapshot and with no local row
- **THEN** the unknown id is dropped, the entry merges with the remainder, and the cycle completes

#### Scenario: Entry with relay-known but locally-missing category keeps its category
- **WHEN** a pulled entry references a category id present in the relay snapshot but with no local row
- **THEN** the entry keeps a category: the join is remapped to the same-name local category when one exists, otherwise the snapshot category row is merged locally — the entry never silently loses the category

#### Scenario: Entry without provenance defaults to manual
- **WHEN** a pulled entry omits `source` (relays predating entry provenance)
- **THEN** the entry decodes with `source` = "manual" instead of failing the pull

### Requirement: Dependency-ordered outbox drain
The sync client SHALL drain `category` outbox rows before `entry` rows, preserving `created_at, rowid` order within each resource. Because `POST /entries` rejects unknown `category_ids` with 422, pushing categories first ensures referenced categories exist on the relay before entries that carry them. Additionally, before pushing each entry create/update, the drain SHALL ensure every referenced category id exists on the relay: ids missing from the relay snapshot but present locally (and not pending deletion) SHALL be created on the relay first via idempotent create (a `category_exists` 409 remaps local references to the winning id and the entry push uses it); only ids missing locally or pending deletion may reach the push uncreated.

#### Scenario: Entry queued before its category still pushes category first
- **WHEN** the outbox holds an entry create whose `created_at` precedes its category create
- **THEN** the drain pushes the category create before the entry create and the cycle completes

#### Scenario: Entry referencing a relay-unknown category pushes it first
- **WHEN** the drain pushes an entry create/update whose category id exists locally but is absent from the relay
- **THEN** the category is created on the relay first and the entry push carries the full category set — no 422, no prune, and the local entry keeps its categories

#### Scenario: Entry referencing a locally-deleted category still prunes
- **WHEN** the drain pushes an entry whose category id has a pending delete (or no local row at all)
- **THEN** that id is not created on the relay and the existing validation_error prune-and-retry path applies

#### Scenario: Same-tick rows drain in insertion order
- **WHEN** two outbox rows in the same resource share an identical `created_at` tick
- **THEN** the drain pushes the earlier-inserted row first (SQLite `rowid` order), so the sequence is deterministic across runs

### Requirement: Push validation_error recovery for unknown categories
On an entry create/update push receiving `validation_error` with `category_ids` details, the sync client SHALL fetch the relay categories, drop unknown ids from the queued payload keeping the remainder (secret-free log), rewrite the outbox payload, retry the push exactly once, and clear the row on success. If no id is pruned or the retry fails, the cycle SHALL fail loudly with the push error and keep remaining rows queued. The following pull converges the local copy via LWW. This path is a last resort only: the dependency-ordered ensure step above SHALL make it unreachable whenever the missing categories exist locally.

#### Scenario: Entry with unknown category is pruned on push
- **WHEN** the drain pushes an entry create referencing a category id absent from the relay
- **THEN** the payload is pruned to the known remainder, the push retries and succeeds, the outbox clears, and the cycle completes idle

#### Scenario: Unprunable validation still fails
- **WHEN** the entry push fails with `validation_error` but every id is already known (or the retry fails)
- **THEN** the cycle fails with the push error and rows stay queued for retry

### Requirement: Pull heals category-set forks
When a pulled server entry is NOT newer than the local entry (tie or older, so LWW keeps local) but the local category set is a strict superset of the server set via existing clean local rows (none pending deletion), the sync client SHALL enqueue an entry update with a bumped `updated_at` (strictly newer even under second-precision truncation) carrying the full local set, so the complete categories reconverge on the relay on the next drain instead of diverging silently forever.

#### Scenario: Re-assigned categories reconverge after a silent prune
- **WHEN** a previous relay-side prune stored fewer categories than the local entry holds (equal timestamps, clean local rows)
- **THEN** the next pull enqueues a healing update and the following drain pushes the full category set, which other devices then receive

#### Scenario: Healing skips delete-wins ids
- **WHEN** the extra local ids are pending deletion
- **THEN** no healing update is enqueued for them and the queued delete still converges the relay

### Requirement: Sync triggers
The sync client SHALL run on: (1) app enters foreground, (2) connectivity restores (NWPathMonitor `.satisfied`), (3) manual "Sync now" action, (4) History pull-to-refresh. A trigger arriving while a cycle is already in flight SHALL join it (await the in-flight cycle's result) instead of starting a second concurrent cycle. On macOS, a timer-based background sync (every N minutes while running) SHALL be added; on iOS, background task scheduling SHALL NOT be used (unreliable).

#### Scenario: Foreground trigger
- **WHEN** the app enters the foreground
- **THEN** the sync client runs a drain-outbox + delta-pull cycle (if signed in)

#### Scenario: Connectivity restored
- **WHEN** connectivity transitions to `.satisfied` while signed in
- **THEN** the sync client runs a cycle

#### Scenario: Manual sync
- **WHEN** the user taps "Sync now" in Profile
- **THEN** the sync client runs a cycle and updates the displayed "Last synced" timestamp on completion

#### Scenario: History pull trigger
- **WHEN** the user pulls to refresh on the populated History list while signed in and online
- **THEN** the sync client runs a cycle (or joins the in-flight one) and the pull awaits its result

#### Scenario: Join instead of fork
- **WHEN** any trigger (pull, Profile "Sync now", foreground, connectivity) arrives while a cycle is in flight
- **THEN** no second cycle starts; the arriving caller awaits the in-flight cycle's outcome

### Requirement: Manual sync and status visibility
The system SHALL expose a sync action and a sync status ("Synced successfully" with a relative-age subtitle, "Syncing…", or an error state) in Profile, visible only when signed in. The action lives as a trailing icon button on the status row itself (no separate "Sync now" row) and calls the same drain+pull path as the automatic triggers. While a sync is in progress, the trailing button stays in place disabled and the status row SHALL be the single "Syncing…" surface — never two. A failed cycle SHALL surface its captured error message alongside the generic error state (secret-free: codes and server messages only). Status views SHALL subscribe to the sync status directly rather than through a non-publishing intermediary, so the display follows the cycle on its own. The idle status SHALL render a "Synced successfully" title with an age subtitle. The subtitle SHALL be minute-bucketed with no seconds precision: under a minute, whole minutes 1–59, whole hours 1–23, whole days 24 hours and up with no upper cap (never weeks, months, or years); a timestamp in the future SHALL render as under a minute. The row SHALL re-render its subtitle on its own as time passes while Profile is visible, with no user action. The subtitle SHALL be correctly localized in English + Russian with correct plural forms: quantity words MAY be rendered by the system quantity formatter (which owns pluralization in every locale), and all connective words SHALL come from localizable strings — no system relative-time formatter with automatic unit choice and tense.

#### Scenario: Status display
- **WHEN** the user views Profile while signed in
- **THEN** the sync status row is visible with a trailing sync button carrying the same action; while a sync is in progress, the button stays in place disabled and exactly one "Syncing…" indicator is shown

#### Scenario: Status follows the cycle without manual refresh
- **WHEN** a sync cycle completes (or fails) while Profile is visible
- **THEN** the status row and button state update on their own — no navigation or re-render trigger needed

#### Scenario: Status row keeps its height across states
- **WHEN** the user taps the trailing sync button with a previous successful sync on record
- **THEN** the row keeps one stable structure (same view types, button always present, previous age as the subtitle while syncing) into the new idle age — the section below never jumps

#### Scenario: Error state
- **WHEN** a sync cycle fails (network error, 5xx)
- **THEN** the status shows an error with its captured message and the trailing sync button remains to allow retry

#### Scenario: Minute buckets
- **WHEN** the last sync was 30 seconds, 1 minute, 59 minutes, 1 hour, 23 hours, 1 day, or 400 days ago
- **THEN** the subtitle reads under-a-minute, "1 minute ago", "59 minutes ago", "1 hour ago", "23 hours ago", "1 day ago", or "400 days ago" respectively beneath a "Synced successfully" title — seconds and weeks/months/years never appear

#### Scenario: Label ages live
- **WHEN** the user keeps Profile open across a minute boundary with no new sync
- **THEN** the subtitle advances to the next bucket on its own

#### Scenario: Future timestamp never reads as future
- **WHEN** the recorded sync date is ahead of the device clock (clock skew)
- **THEN** the subtitle reads under-a-minute — never a future-tense phrase in any locale

#### Scenario: Label is fully localized
- **WHEN** the app runs in Russian
- **THEN** every subtitle (including 1/2/5-form plurals) reads correctly in Russian with no system-generated tense or unit choice

#### Scenario: Future language cost stays flat
- **WHEN** a new locale is added later
- **THEN** only connective words need new strings — quantity pluralization already works through the system quantity formatter

### Requirement: Same-account guard on sync cycles
Every sync cycle SHALL be bound to the account it serves: the sync client SHALL record the `userId` the cycle's local database file is bound to and SHALL verify it against the authenticated session's `userId` before acting. On account mismatch, the cycle SHALL be refused or skipped — the client SHALL never drain or push one account's outbox, or apply a pull for one account's database, under another account's token. The guard SHALL be checked at cycle start and SHALL remain in effect if the active account changes mid-cycle.

#### Scenario: Cycle is refused on account mismatch
- **WHEN** a sync cycle finds the bound `userId` of the active local database differs from the authenticated session's `userId`
- **THEN** the cycle is skipped with a secret-free log entry and the outbox is left untouched

#### Scenario: Outbox is never pushed under another account's token
- **WHEN** a signed-in session for account B becomes active while account A's outbox still holds rows in a dormant file
- **THEN** account A's outbox rows stay in A's dormant file and are never drained or pushed under B's session token

#### Scenario: Mid-cycle account change aborts the cycle
- **WHEN** the active account changes (sign-out or account swap) while a sync cycle is in flight
- **THEN** the in-flight cycle aborts without draining further rows or applying further pulled records to the swapped-out account's file

### Requirement: Relay wire-format date decoding
The client SHALL decode every relay timestamp as RFC 3339 (`format: date-time`) through dedicated wire shapes, never through the local models' timestamp decoding. Categories and entries each have their own wire decoding for `created_at`/`updated_at`. A decoding failure SHALL surface as a normal cycle error, never a stuck "Syncing…".

#### Scenario: Non-empty pull decodes
- **WHEN** the relay returns categories or entries with RFC 3339 timestamps (with or without fractional seconds)
- **THEN** the pull merges them and the cycle completes; no `typeMismatch` on `created_at`/`updated_at`

### Requirement: Tombstone fetch and apply
Every sync cycle SHALL fetch the relay's deletion tombstones since the `deletions` cursor and apply them locally BEFORE draining the outbox. Applying a tombstone SHALL delete the local row (entries cascade to their joins; categories cascade to entry joins) with no outbox row, drop pending create/update outbox rows for the affected ids, and leave pending DELETE rows to converge via the existing 404-as-success. The cursor SHALL advance to the max `deleted_at` received, and stay unchanged when the list is empty. A tombstone for an unknown id is a no-op that still advances the cursor.

#### Scenario: Entry or category deleted on another device converges
- **WHEN** the relay holds an entry or category tombstone from a device that deleted it
- **THEN** after a sync the entry is gone (or the category and its entry joins are gone with entries surviving untagged), no outbox row exists, and the cursor advanced past the tombstone

#### Scenario: Entry deleted on another device converges
- **WHEN** the relay holds an entry tombstone and this device holds the live entry
- **THEN** after a sync the entry is gone locally with no outbox row and the cycle is idle

#### Scenario: Category deleted on another device converges
- **WHEN** the relay holds a category tombstone and this device holds the live category attached to entries
- **THEN** after a sync the category and its entry joins are gone, the entries survive untagged, and no outbox row exists

#### Scenario: Tombstones apply before the drain
- **WHEN** this device holds a stale pending update for a record the relay tombstoned
- **THEN** the tombstone step drops the update row before the drain runs, so no 404 is ever pushed for it and the cycle stays idle

#### Scenario: Stale tombstone never kills a recreation (R1)
- **WHEN** the local row is clean (no pending create/update) and newer than the tombstone (`updated_at > deleted_at`)
- **THEN** the row is kept and the tombstone is buried by the cursor advance

#### Scenario: Empty deletions keep the cursor
- **WHEN** the deletions fetch returns no tombstones
- **THEN** the cursor is unchanged and no local state is touched

### Requirement: Push-404 resurrection
When an outbox push fails because the relay lacks the record and no tombstone covers it, the sync client SHALL resurrect from the local record and retry exactly once instead of failing the cycle: entry/category update receiving `not_found` SHALL be re-posted as a create (idempotent; `duplicate_import` clears the row via the existing resolver). Rows with no local record left SHALL clear without further pushes. Any further failure SHALL rethrow the original error loudly; nothing is ever silently dropped.

#### Scenario: Stale update re-posts as create
- **WHEN** the drain pushes an entry or category update and the relay answers `not_found` while the full local row exists
- **THEN** the row is re-posted as a create, the outbox clears, and the cycle completes idle with the local record intact

#### Scenario: Remap-leftover update clears without pushing
- **WHEN** a stale update row references a record id with no local row left (no remap flow exists to orphan it)
- **THEN** the row clears with no further push and no other record is touched

#### Scenario: Failed heal surfaces loudly
- **WHEN** the re-post fails
- **THEN** the cycle fails with the original push error and all rows stay queued for retry

### Requirement: Delete-wins for entries and categories
On pull, the sync client SHALL NOT apply a server entry or category the user deleted locally — a deletion sitting in the durable undo buffer or a committed deletion with a pending outbox DELETE row. Such records SHALL be skipped with a secret-free log; the queued DELETE converges the relay on drain. In addition, every sync cycle SHALL push buffered (undoable) deletions to the relay before draining the outbox (push-then-commit): one `DELETE` per snapshotted record; on success the buffer row is dropped and undo ends for that deletion. A 404 on a buffered push is success (already gone); any other push error fails the cycle loudly with the row still buffered and undoable.

#### Scenario: Buffered entry deletion survives a pull
- **WHEN** an entry deletion sits in the undo buffer and a pull returns the relay's copy
- **THEN** the pull skips the record and the buffer row stays restorable

#### Scenario: First-sync with a pending entry delete
- **WHEN** the outbox holds an entry DELETE and the relay still returns that entry
- **THEN** the pull skips the record, the drain pushes the DELETE, and the entry stays deleted locally

#### Scenario: Buffered deletion pushes on the next cycle
- **WHEN** the user deletes an entry (or category) and a sync cycle runs while signed in and online
- **THEN** the cycle pushes the `DELETE` for every snapshotted record before draining the outbox; on success the buffer row is dropped, the relay holds a tombstone, and other devices converge on their next sync — no app restart required

#### Scenario: Failed buffered push stays undoable
- **WHEN** a buffered `DELETE` push fails with a non-404 error (network, 5xx)
- **THEN** the cycle fails loudly, the buffer row is kept, and the deletion can still be undone or retried on the next cycle

#### Scenario: Undo ends at push success
- **WHEN** a buffered deletion's pushes all succeeded and the buffer row was dropped
- **THEN** a later undo finds nothing to restore (same as undo after a restart today)

