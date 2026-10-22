## ADDED Requirements

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
