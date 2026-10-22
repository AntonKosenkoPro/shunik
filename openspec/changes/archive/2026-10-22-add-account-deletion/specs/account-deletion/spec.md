## Purpose

Defines explicit in-app deletion of a Lifio account and its associated operational data, safe account-local cleanup across devices, trustworthy completion evidence, and recovery from interrupted delivery without confusing deletion with sign-out.

## ADDED Requirements

### Requirement: Explicit authenticated account deletion
The system SHALL let a signed-in user initiate permanent deletion of their own account from Account. The request SHALL target the authenticated account, not an arbitrary supplied account identifier. A completed operational purge SHALL remove the account identity and its OTPs, all-device session credentials and refresh-recovery records, entries, entry-category associations, categories, record-deletion tombstones, and account-owned Apple-vault data atomically. A failure before commit SHALL leave the operational account and its data intact. Minimal encrypted Apple-revocation work pending completion and time-limited backups SHALL be separately disclosed rather than represented as already erased.

#### Scenario: Email account deleted
- **WHEN** an authenticated email-created account confirms deletion and the purge commits
- **THEN** its operational account and all associated operational records are absent, all devices' old credentials can no longer access it, and no Apple authorization operation is required

#### Scenario: Purge rolls back
- **WHEN** deleting any required operational record fails before the transaction commits
- **THEN** the entire purge rolls back and no partial deletion is reported as success

#### Scenario: Cannot delete another account
- **WHEN** a request attempts to select an account other than its authenticated subject
- **THEN** it cannot delete or disclose that other account

### Requirement: Account deletion completion is unambiguous
The system SHALL distinguish confirmed account deletion from authentication rejection, missing routes, transport failure, or malformed responses. A deletion acknowledgment SHALL be sent only after operational purge commits. For Apple accounts, the result SHALL distinguish completed Apple revocation from durable pending automatic revocation. The authoritative OpenAPI contract SHALL define 204 for completed purge with revocation complete/not applicable and 202 with explicit `account_deleted: true` and `apple_revocation_pending: true` for committed purge with pending automatic revocation. Missing/expired credentials, generic 401/404 responses, and a database/service failure SHALL NOT independently authorize local erasure or a success announcement.

#### Scenario: Normal completion
- **WHEN** the operational account is purged and required Apple revocation is complete or not applicable
- **THEN** the deletion response confirms completion and local cleanup can proceed

#### Scenario: Apple unlink remains pending
- **WHEN** operational purge and durable Apple-revocation work commit but Apple's revocation cannot yet be confirmed
- **THEN** the result explicitly confirms account deletion with Apple unlink pending and does not claim that Apple revocation has completed

#### Scenario: Generic rejection is not deletion
- **WHEN** a protected request returns a generic authentication failure or an unknown route returns 404
- **THEN** the client does not infer account deletion and does not erase local data from that response alone

### Requirement: Narrow account-status evidence
The system SHALL provide an account-scoped credential with a fixed 30-day expiry whose only authority is checking whether the original immutable account UUID still exists. It SHALL be obtained while authenticated and stored securely before a deletion request is sent, separately from login/refresh credentials. Validation SHALL enforce a dedicated signing key, pinned algorithm/issuer/audience/purpose, immutable UUID binding, and expiry. The credential SHALL contain no email and SHALL NOT appear in URLs or logs. A valid status request SHALL disclose only its verified subject's account state and SHALL distinguish an existing account from a deleted one, with no-store and rate-limited responses. Status credentials SHALL NOT authorize login, refresh, logout, sync, deletion, or another account's status; status requests SHALL NOT renew their own lifetime. The client SHALL match the verdict's UUID to its original intent/monitor. Invalid, expired, unavailable, or mismatched evidence SHALL preserve local files; invalid credentials SHALL reveal no account state. An operational database error SHALL NOT be reported as a deleted account.

#### Scenario: Existing but revoked account
- **WHEN** a valid status credential checks an account whose sessions were revoked but whose identity remains
- **THEN** the verdict is active and no account-local data is erased

#### Scenario: Other device confirms deletion
- **WHEN** a device receives a successful status response scoped to its original account UUID confirming that the account no longer exists
- **THEN** it schedules cleanup only for that UUID and prevents that account's stale data from syncing

#### Scenario: Evidence expired or unavailable
- **WHEN** a device lacks valid evidence, its status request fails, or the response does not match the checked UUID
- **THEN** it keeps its local account files and follows normal lock-not-wipe behaviour until deletion can be reliably confirmed or the user explicitly erases local data

#### Scenario: Read-only credential is misused
- **WHEN** an account-status credential is presented to any normal authenticated or destructive operation
- **THEN** the operation rejects it without issuing credentials or changing data

### Requirement: Interrupted deletion and cleanup are recoverable
Before sending deletion the client SHALL durably retain account-scoped intent and status evidence. An ambiguous deletion response SHALL retain recoverable state without claiming success or erasing data on assumption. Confirmed deletion SHALL durably schedule account-scoped cleanup that survives restart and credential removal. A local cleanup failure after server purge SHALL not restore the account or make it appear still signed in; the auth gate SHALL offer cleanup retry. Conflicting sync work SHALL remain fenced while a deletion outcome is unresolved.

#### Scenario: Response lost after commit
- **WHEN** the server commits deletion but its acknowledgment is lost and the client later obtains a scoped deleted status
- **THEN** the client finishes local cleanup without requiring another login or another deletion confirmation

#### Scenario: Restart during deletion
- **WHEN** the process terminates after sending deletion or during confirmed local cleanup
- **THEN** the next launch resumes the original UUID's status resolution or cleanup without applying it to another account

#### Scenario: Local removal fails after purge
- **WHEN** server deletion is confirmed but removing the local file or account session artifacts fails
- **THEN** the app returns to an unauthenticated state, preserves a minimal durable cleanup marker, and offers retry without claiming the failed cleanup succeeded

#### Scenario: Offline before submission
- **WHEN** the user requests permanent deletion while offline
- **THEN** no local-only deletion is substituted, the app explains that a connection is required, and the account's recoverable data remains intact

### Requirement: Deleted accounts cannot resurrect through stale work
After purge, old access tokens, refresh tokens, pending recovery attempts, and in-flight catalog mutations SHALL NOT authorize access, issue a valid successor session, or recreate the deleted UUID's data. Service failure SHALL remain distinct from missing-account authentication rejection. Account deletion SHALL NOT use record-level undo or resurrection recovery.

#### Scenario: In-flight sync races purge
- **WHEN** a catalog write or refresh overlaps account deletion
- **THEN** it linearizes before the purge or is rejected without committing new records for the deleted account after purge

#### Scenario: Recovery receipt replay after purge
- **WHEN** another device retries a previously accepted refresh attempt after account deletion
- **THEN** no valid session for the deleted account is returned and no recovery record recreates it

### Requirement: Registration after deletion creates a fresh identity
After explicit account deletion the user SHALL be allowed to register again with the same email or Apple identity, receiving a new account UUID and a fresh local file without old content. Apple signup SHALL not be accepted while old pending revocation could invalidate the new authorization. Reconnecting after external Apple consent revocation without account deletion SHALL instead return to the existing account as defined by `apple-signin`.

#### Scenario: Same email after deletion
- **WHEN** the user completes email signup after their old account was deleted
- **THEN** a new account UUID is created and old entries, notes, outbox, cursors, and running drafts are not restored into it

#### Scenario: Same Apple identity after deletion
- **WHEN** the old Apple revocation has completed and the user completes a new Apple authorization
- **THEN** registration creates a fresh UUID rather than restoring the deleted account

#### Scenario: Old Apple revocation still pending
- **WHEN** Apple signup is attempted while a pending old revocation could revoke the new grant
- **THEN** the system completes that revocation first or returns a retryable service outcome without accepting a new authorization

### Requirement: Deletion claims match actual retention
The privacy page and account-action explanations SHALL distinguish sign-out, local-only deletion, explicit account deletion, Settings-only Apple disconnection, conditional cleanup of other devices, pending encrypted Apple-revocation material, and actual backup expiry. They SHALL NOT promise immediate erasure of offline devices or retained backups. The policy SHALL describe the shipped in-app deletion path rather than require email support to complete it. Email-requested deletion is outside this capability.

#### Scenario: Shipped policy reviewed
- **WHEN** the deletion-enabled build is submitted for external review
- **THEN** the published privacy page describes its actual Account navigation, server/local effects, automatic Apple handling, and verified retention limitations

#### Scenario: Offline second phone
- **WHEN** an account is deleted while a second phone remains offline
- **THEN** no claim is made that its local file was immediately erased, and that phone erases it only after reliable account-specific deletion confirmation
