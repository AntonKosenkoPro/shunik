## MODIFIED Requirements

### Requirement: Per-device refresh families
The system SHALL persist a `device_id` on every issued refresh token, so each device's refresh tokens form a distinct family. Rotation SHALL stay within the issuing device's family, and a refresh token SHALL never be issued with an empty device identifier. Consuming a predecessor, creating its successor, and recording any recovery receipt SHALL commit together or not at all.

#### Scenario: Rotation stays within the family
- **WHEN** a device rotates its refresh token
- **THEN** the new token belongs to the same device family, and no other device's tokens are affected

#### Scenario: No anonymous family
- **WHEN** the backend issues any refresh token
- **THEN** it is recorded against a concrete device identifier, never an empty one

#### Scenario: Rotation fails before commit
- **WHEN** storage or token-issuance work fails before a refresh transaction commits
- **THEN** the predecessor remains usable and no partial successor or recovery receipt is committed
- **AND** the response reports a service failure rather than invalid credentials

### Requirement: Reuse detection scoped per-device
The system SHALL distinguish an eligible retry of an accepted refresh attempt from refresh-token reuse. An eligible retry SHALL NOT revoke any family. On genuine reuse, the system SHALL revoke only the offending device's refresh family — never all of the user's sessions across devices. A wrong-device presentation SHALL be rejected without granting recovery or revoking the legitimate device's family.

#### Scenario: Stale token kills only its family
- **WHEN** a replayed, already-rotated refresh token is presented without a matching accepted attempt by its issuing device while a second device holds an active session
- **THEN** only the first device's family is revoked and the second device's session keeps working

#### Scenario: Accepted pending attempt is not theft
- **WHEN** the issuing device repeats the same predecessor and accepted pending `refresh_attempt_id` after losing a response
- **THEN** the request follows the recovery contract and does not trigger `token_reuse`

#### Scenario: Different attempt does not bypass reuse detection
- **WHEN** the issuing device presents a revoked predecessor with a different attempt identifier, or without an identifier
- **THEN** the backend returns `token_reuse` and revokes only that device's family

#### Scenario: Wrong device cannot recover or revoke another device
- **WHEN** a different device presents a refresh token and attempt identifier belonging to the legitimate device
- **THEN** the backend rejects the request with `invalid_refresh`, returns no credentials, and leaves the legitimate family intact

#### Scenario: Genuine revoked replay is checked before expiry
- **WHEN** the issuing device replays a revoked token without a matching accepted attempt after that token's TTL has elapsed
- **THEN** the response remains `token_reuse` and the offending device's live family is revoked

### Requirement: Refresh TTL enforcement
The system SHALL reject new rotations whose presented refresh token has exceeded its TTL. Recovery of an already accepted pending rotation SHALL expire no later than the successor's original refresh-token expiry. Returning a recovery response SHALL NOT extend that expiry. Default access and refresh lifetimes SHALL remain unchanged.

#### Scenario: Expired family is rejected
- **WHEN** a device presents a refresh token after its family's TTL has elapsed and no unexpired accepted pending rotation authorizes recovery
- **THEN** the refresh is rejected with an authentication error and no new tokens are issued

#### Scenario: Long suspension remains recoverable
- **WHEN** a device retries an accepted pending rotation after a 52-minute suspension and the original successor remains within its refresh TTL
- **THEN** recovery succeeds without sign-in, even if the access token from the lost response would already have expired

#### Scenario: Recovery does not renew refresh expiry
- **WHEN** a pending attempt is recovered more than once
- **THEN** every recovery returns the same successor refresh credential with the same refresh expiry and a currently valid access token

#### Scenario: Pending recovery has expired
- **WHEN** the successor's original refresh expiry has elapsed before the accepted pending attempt is retried
- **THEN** the backend returns `refresh_expired` without renewing that session

### Requirement: Revoked or exhausted session locks, never wipes
The system SHALL, on confirmed session revocation or exhaustion, lock the app to the auth gate with all local account files intact. Re-login SHALL resume the existing account file when an authentication slot is free. Interrupted refresh delivery, retryable service failures, and temporary credential-storage failures SHALL NOT be treated as confirmed session revocation.

#### Scenario: Locked to auth gate with files intact
- **WHEN** the backend revokes the active session and the app detects it
- **THEN** the app locks to the auth gate, all local database files remain untouched, and after re-login the same account resumes without data loss

#### Scenario: Lost response does not force sign-in
- **WHEN** refresh rotation commits but the response is lost or truncated, normal networking is restored, and the user retries sync
- **THEN** the app recovers the session, remains signed in, and completes sync without visiting Welcome
- **AND** entries, timer draft, outbox, cursors, and the active account binding remain intact

## ADDED Requirements

### Requirement: Durable refresh attempt identity
The client SHALL durably record an unpredictable attempt identifier bound to its current refresh credential, account, and device before sending a logical refresh. It SHALL reuse that identifier while delivery or durable replacement is uncertain, including after suspension or process restart. Concurrent callers SHALL share one logical attempt. Failure to durably record intent SHALL prevent the request from being sent.

#### Scenario: Restart after lost response
- **WHEN** the app terminates after the server commits a rotation but before the replacement credentials are durably saved
- **THEN** the next launch retries the same predecessor and attempt identifier instead of starting an unrelated rotation

#### Scenario: Intent cannot be stored
- **WHEN** preparing a refresh attempt fails because credential storage is temporarily unavailable
- **THEN** no refresh request is sent, existing credentials are retained, and the cached signed-in account remains available offline

#### Scenario: Concurrent refresh callers
- **WHEN** foreground restoration and sync both require a refresh concurrently
- **THEN** they share the same durable attempt and do not independently rotate the predecessor

### Requirement: Stable recovery result for an accepted attempt
The backend SHALL accept an optional `refresh_attempt_id` on refresh requests; updated clients SHALL always supply it. A valid attempt SHALL be bound to one predecessor, account, and device. Before the successor is consumed or revoked, repeating that accepted pending attempt SHALL return the same successor refresh credential and a fresh valid access token without creating another successor. Requests without the field SHALL retain legacy refresh behavior, without gaining response-loss recovery.

#### Scenario: Duplicate delivery returns one successor
- **WHEN** two matching refresh requests arrive concurrently or their responses arrive out of order
- **THEN** both successful responses contain the same successor refresh credential, and neither invalidates the other's result

#### Scenario: Repeated response loss
- **WHEN** more than one response for the same pending attempt is lost before the client finally receives a complete response
- **THEN** recovery still returns the original successor rather than rotating forward on each retry

#### Scenario: Successor consumption closes recovery
- **WHEN** the successor is successfully used for a subsequent rotation
- **THEN** the predecessor's recovery receipt is closed and can no longer return that successor
- **AND** a delayed exact duplicate of the closed attempt returns `refresh_attempt_completed` as a non-authentication conflict without revoking the family

#### Scenario: Attempt identifier is rebound
- **WHEN** an accepted attempt identifier is submitted for a different predecessor within the same account and device
- **THEN** the request is rejected as a conflict without issuing credentials or overwriting the original receipt

#### Scenario: Logout or revocation ends recovery
- **WHEN** a pending receipt's successor has been revoked by logout or genuine reuse detection
- **THEN** replaying the accepted attempt cannot recreate or unlock that revoked session

### Requirement: Durable credential replacement and session ownership
The client SHALL replace the access credential, refresh credential, and pending-attempt state as one durable credential snapshot. A temporary read error SHALL be distinguishable from an absent credential. A failed replacement SHALL preserve the last usable snapshot and recovery intent. Late responses from an older session generation or superseded attempt SHALL NOT overwrite credentials or change the active account's authentication state.

#### Scenario: Replacement write fails
- **WHEN** the client receives a valid refresh response but cannot save the replacement snapshot
- **THEN** it retains the predecessor and pending attempt, does not publish the replacement as durable success, and can recover on a later retry

#### Scenario: Process terminates during replacement
- **WHEN** the app terminates around a credential replacement
- **THEN** restart observes either the predecessor with its pending attempt or the complete successor snapshot, never a mixed token pair

#### Scenario: Refresh completes after sign-out or account switch
- **WHEN** a refresh from an older session generation completes after explicit sign-out or sign-in to another account
- **THEN** neither its success nor its failure changes the new authentication state or writes credentials into the new account's session

#### Scenario: Closed duplicate arrives after advancement
- **WHEN** a delayed `refresh_attempt_completed` response belongs to an attempt older than the client's durable snapshot
- **THEN** the client ignores that stale result and continues with the current credentials rather than signing out

### Requirement: Recovery secrets remain protected and bounded
The server SHALL use hashes for refresh-token authentication lookups and SHALL NOT persist plaintext tokens or raw attempt identifiers. The sole recoverable server-side refresh credential SHALL be an authenticated-encrypted pending successor, bound to its account, device, predecessor, attempt, and fixed expiry. It SHALL be removed on consumption, logout, revocation, or expiry; retained non-secret receipt metadata SHALL also have bounded retention. Logs SHALL NOT contain tokens, raw attempt identifiers, ciphertext, request bodies, or encryption keys.

#### Scenario: Receipt is modified or its key is unavailable
- **WHEN** a pending receipt cannot be authenticated or decrypted, or its backing storage is unavailable
- **THEN** the service issues no credentials, reports a service failure, and does not claim invalid credentials or revoke the family

#### Scenario: Server restarts during pending recovery
- **WHEN** the backend restarts while a valid pending recovery receipt exists
- **THEN** the same device and attempt can still recover with the configured persistent keys; no process-local cache is required

### Requirement: Transient refresh failures do not masquerade as authentication rejection
The system SHALL distinguish confirmed `invalid_refresh`, `token_reuse`, and `refresh_expired` responses from transport, decoding, storage, and service failures. A failed database lookup caused by a service error SHALL NOT be reported as a token that does not exist. A protected request SHALL have one refresh owner, without a second blind refresh fallback during session restoration.

#### Scenario: Database lookup fails transiently
- **WHEN** refresh-token lookup fails because the database is unavailable rather than because the token is absent
- **THEN** the backend returns a service error, preserves the family, and the app keeps its cached session and retry intent

#### Scenario: Gateway or truncated response is ambiguous
- **WHEN** a refresh response is incomplete or lacks a valid backend authentication-error envelope
- **THEN** the client retains recovery intent and does not infer a conclusive authentication rejection from that ambiguity
