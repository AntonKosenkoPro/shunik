## MODIFIED Requirements

### Requirement: Revoked or exhausted session locks, never wipes
The system SHALL, on confirmed session revocation or exhaustion without independently confirmed account deletion, lock the app to the auth gate with all local account files intact. Re-login SHALL resume the existing account file when an authentication slot is free. Interrupted refresh delivery, retryable service failures, and temporary credential-storage failures SHALL NOT be treated as confirmed session revocation. A generic 401, unknown refresh credential, expired session, or Apple consent-revocation event SHALL NOT authorize local erasure. Only account-scoped deletion acknowledgment or valid scoped deletion-status confirmation SHALL authorize the separate cleanup defined by `account-deletion`; inconclusive deletion checks SHALL preserve files.

#### Scenario: Locked to auth gate with files intact
- **WHEN** the backend revokes the active session and the app detects it without account-deletion confirmation
- **THEN** the app locks to the auth gate, all local database files remain untouched, and after re-login the same existing account resumes without data loss

#### Scenario: Lost response does not force sign-in
- **WHEN** refresh rotation commits but its response is lost or truncated, normal networking is restored, and the user retries sync
- **THEN** the app recovers the session, remains signed in, and completes sync without visiting Welcome
- **AND** entries, timer draft, outbox, cursors, and active account binding remain intact

#### Scenario: Confirmed account-deletion exception
- **WHEN** a locked device independently confirms deletion of its original account using valid account-scoped evidence
- **THEN** it schedules cleanup of only that deleted UUID rather than treating the original authentication rejection itself as permission to wipe

### Requirement: Recovery secrets remain protected and bounded
The server SHALL use hashes for Lifio refresh-token authentication lookups and SHALL NOT persist plaintext tokens or raw attempt identifiers. The sole recoverable server-side Lifio session refresh credential SHALL be an authenticated-encrypted pending successor, bound to its account, device, predecessor, attempt, and fixed expiry. It SHALL be removed on consumption, logout, revocation, or expiry; retained non-secret receipt metadata SHALL also have bounded retention. Separately stored Apple revocation credentials SHALL follow the authenticated-encryption and deletion-retention rules in `apple-signin`, and SHALL NOT be usable as Lifio session credentials. Logs SHALL NOT contain tokens, raw attempt identifiers, ciphertext, request bodies, or encryption keys.

#### Scenario: Receipt is modified or its key is unavailable
- **WHEN** a pending receipt cannot be authenticated or decrypted, or its backing storage is unavailable
- **THEN** the service issues no credentials, reports a service failure, and does not claim invalid credentials or revoke the family

#### Scenario: Server restarts during pending recovery
- **WHEN** the backend restarts while a valid pending recovery receipt exists
- **THEN** the same device and attempt can still recover with the configured persistent keys and no process-local cache is required

## ADDED Requirements

### Requirement: Access and recovery enforce current account lifecycle
Protected access SHALL require the account to still exist, in addition to a valid access token. Verified external Apple consent revocation SHALL invalidate Lifio session lineages authorized before that revocation across devices, without deleting the account. Refresh and accepted-response recovery SHALL not bypass this invalidation. A later completed Apple reauthorization SHALL create a new valid lineage for the same existing account that delayed older notifications cannot revoke. Database failure SHALL remain a service failure, not a deleted-account verdict. Ordinary logout/reuse SHALL retain existing per-device scope.

#### Scenario: Old access token after account deletion
- **WHEN** a correctly signed unexpired access token targets an account that has been deleted
- **THEN** it cannot read/write protected data and no valid refresh/recovery session can be created for that account

#### Scenario: External Apple revoke affects all old sessions
- **WHEN** a verified Apple consent-revocation event is processed
- **THEN** the account's pre-event Lifio sessions and their pending recoveries lose access across devices while all account data remains intact

#### Scenario: Delayed old event after reconnect
- **WHEN** the user completes a new Apple authorization and an older revocation notification is delivered or replayed afterwards
- **THEN** the newly authorized lineage stays usable and the existing account UUID is preserved

#### Scenario: Database unavailable
- **WHEN** checking current account or authorization state fails because storage is unavailable
- **THEN** a service error is returned without claiming deletion or erasing local data
