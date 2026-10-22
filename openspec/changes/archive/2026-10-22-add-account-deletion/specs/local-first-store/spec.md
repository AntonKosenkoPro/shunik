## MODIFIED Requirements

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
