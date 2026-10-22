# Account-Bound Store Specification

## Purpose

Per-user database file lifecycle for account-bound local data: naming, single-active-file selection, open/resume on login, dormant retention on logout, per-account erase, and the running timer's survival across account switches.

## Requirements

### Requirement: Per-user database file
The system SHALL store each account's local data in its own database file named `lifio_<userId>.db` inside the App Group shared container. At any moment exactly one file SHALL be active, and the active file SHALL be determined solely by the signed-in account's `user_id`.

#### Scenario: One active file per account
- **WHEN** the device holds dormant files for accounts A and B and the user is signed in as A
- **THEN** exactly one database file is active (A's), B's file remains on disk untouched, and no operation reads or writes B's file

### Requirement: First login adopts or creates the account file
The system SHALL, on the first successful sign-in as an account, open that account's database file — creating it if absent — and seed it with the starter categories exactly once per account file. Pre-existing anonymous/dev-install data SHALL NOT be migrated (discarded pre-release). The sign-in lifecycle SHALL run in bind-then-reveal order: open the account file, commit buffered deletions from the previous process, seed starter categories, and only then reveal the shell; sync activation and the first-sync pull-first cycle start after the reveal and run in the background, never blocking it.

#### Scenario: Fresh account seeds starter categories
- **WHEN** the user signs in for the first time as an account with no database file on disk
- **THEN** the file is created in the App Group container, starter categories are seeded into it once, and no leftover anonymous data from a previous install state appears

#### Scenario: Reinstall after erase re-seeds
- **WHEN** the account's file was erased and the user signs in again as that account
- **THEN** a new file is created and starter categories are seeded again

#### Scenario: Shell never mounts before seed
- **WHEN** a fresh sign-in binds a new account file that still needs starter seeding
- **THEN** no tracker read mounts before the seed completes, so the first Track paint carries the starter categories instead of an empty category map

#### Scenario: First sync stays background
- **WHEN** the shell is revealed after bind, commit, and seed
- **THEN** the pull-first first-sync cycle runs concurrently without delaying the reveal, and tracker screens converge on pulled data via their sync-exit reloads; an offline or failed first sync never holds the splash or the shell

### Requirement: Re-login resumes the dormant file
The system SHALL reopen the existing account file on re-login and resume without a full server re-pull: pending outbox operations drain, incremental sync cursors continue from where they stopped, and the running timer draft resumes.

#### Scenario: Outbox drains and cursors continue
- **WHEN** an account with pending outbox operations and advanced sync cursors logs out and later logs back in
- **THEN** the app opens the same file, drains the pending outbox, continues incremental pulls from the stored cursors, and never performs a full re-pull

### Requirement: Logout keeps all account files
The system SHALL preserve all account database files on logout. Only Keychain session tokens, cached session state, and in-memory session SHALL be cleared; a dirty outbox remains in the dormant file.

#### Scenario: Logout retains dormant dirty outbox
- **WHEN** the user logs out while the active file has uncommitted outbox operations
- **THEN** all files stay on disk, the dirty outbox remains in the now-dormant file, and only Keychain and cached session state are cleared

### Requirement: Running timer survives logout and account switch
The system SHALL keep a running timer's draft state (elapsed time, entry text, ordered categories) in its account's file across logout or account switch, and SHALL resume it when that account becomes active again. There is no activity entity — the resumed state is the timer draft, never an activity.

#### Scenario: Timer resumes after returning to its account
- **WHEN** a timer is running in account A, the user logs out and signs in as B, then later signs back in as A
- **THEN** account A's file still holds the running timer draft, and on return the timer UI resumes with the elapsed time, text, and categories intact; account B never sees A's timer

### Requirement: Explicit per-account erase
The system SHALL delete only the active account's database file and its session artifacts (Keychain/cache entries) when the user performs an explicit per-account erase action. Erase SHALL never occur as a side effect of logout, re-login, or account switch.

#### Scenario: Erase deletes only the active file
- **WHEN** the user confirms erase while signed in as account A, with account B's dormant file present
- **THEN** only A's file and its session artifacts are deleted; B's dormant file remains, and logout alone never deletes any file

### Requirement: Single active session
The system SHALL maintain at most one authenticated account at a time. Opening a second account's file SHALL require fresh authentication as that account; the app SHALL NOT keep a cached second session for switching.

#### Scenario: Switching accounts requires re-authentication
- **WHEN** the user, signed in as A, signs out and signs in as B
- **THEN** B's sign-in requires the full fresh authentication flow, no cached session for B is reused, and only one account is authenticated at any time

### Requirement: Confirmed account deletion cleans only the identified account
Explicitly confirmed server deletion or trustworthy remote confirmation SHALL schedule removal of that exact account UUID's local database, SQLite sidecars, outbox, undo buffer, cursors, timer draft, and account-owned session/cache/status artifacts. The system SHALL keep unrelated accounts' dormant files and the stable device identifier. A cleanup task SHALL remain bound to its original UUID even after sign-out, account switch, delayed response, or restart. Cleanup SHALL prevent the deleted account's file from being reopened or recreated by the app or an extension. This is a narrow deletion exception, not a change to logout preservation.

#### Scenario: Delete A while B is dormant
- **WHEN** A's account deletion is confirmed while B's file is present
- **THEN** A's data and session artifacts are removed, B's file remains intact, and the stable device identifier remains unchanged

#### Scenario: Delayed cleanup after switching accounts
- **WHEN** A's confirmed cleanup resumes after B has become the active account
- **THEN** it removes only A's data and does not clear B's session, erase B's file, reset B's navigation, or end B's Live Activity

#### Scenario: Extension overlaps cleanup
- **WHEN** an extension attempts to mutate a timer while deletion cleanup removes the same account
- **THEN** cleanup and mutation are coordinated so no file or orphan draft is recreated after cleanup finishes

### Requirement: Confirmed deletion ends its timer without saving
Removing a deleted account's local data SHALL end its visible Live Activity immediately, cancel its account-specific background cleanup, and discard its running draft without committing a new entry or displaying a Saved confirmation. Sign-out-only and Apple-consent-disconnection SHALL continue preserving dormant timer drafts for existing accounts.

#### Scenario: Deletion with a running timer
- **WHEN** an account with a running draft is confirmed deleted
- **THEN** its Live Activity disappears without a Saved state and no stop-created entry or outbox mutation is emitted

#### Scenario: Apple disconnect is not deletion
- **WHEN** external Apple consent revocation signs out an account with a running draft
- **THEN** the account file and draft remain available for the same account's later reauthorization
