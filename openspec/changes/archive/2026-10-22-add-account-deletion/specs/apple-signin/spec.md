## MODIFIED Requirements

### Requirement: Apple sign-in endpoint contract
The backend SHALL expose `POST /api/v1/auth/apple` returning the standard auth response with access/refresh credentials and user. Updated clients SHALL send both `identity_token` and `authorization_code`. The backend SHALL verify Apple's RS256 identity-token JWT against Apple's JWKS, validating signature, issuer, configured audience, and expiry, and SHALL validate the authorization code with Apple before securely retaining a revocable refresh credential bound to the same Apple subject/audience. It SHALL upsert the user keyed by Apple's stable subject identifier, treat Apple users as email-verified, and preserve the first-seen email. During API rollout, identity-token-only requests from prior clients SHALL retain their existing sign-in behaviour; missing stored revocable credentials SHALL never be silently treated as completed automatic revocation. Invalid identity tokens SHALL return 401 `invalid_apple_token`; the endpoint SHALL be rate-limited per IP. A temporary Apple exchange/storage failure SHALL NOT be reported as successful credential capture.

#### Scenario: Valid identity token
- **WHEN** a correctly signed unexpired identity token with audience matching `APPLE_CLIENT_ID` and a valid matching authorization code are posted
- **THEN** the server returns 200 with the standard session response and securely retains the revocable Apple credential; repeating sign-in for the same existing subject returns the same user ID and first-seen email

#### Scenario: Invalid identity token
- **WHEN** an identity token fails signature, issuer, audience, or expiry validation
- **THEN** the server returns 401 `invalid_apple_token`

#### Scenario: Rate limited
- **WHEN** the per-IP rate limit for Apple sign-in is exhausted
- **THEN** the server returns 429 `rate_limited`

#### Scenario: Mismatched authorization identity
- **WHEN** the authorization-code exchange resolves to a subject or audience different from the supplied verified identity
- **THEN** the server rejects credential capture and does not attach that token to another account

#### Scenario: Existing identity-token-only user
- **WHEN** an existing Apple account has no securely retained revocable token
- **THEN** its normal identity is preserved and explicit deletion obtains a fresh matching Apple authorization rather than silently skipping automatic revocation

### Requirement: Deployment preconditions
Sign in with Apple SHALL be enabled for distribution by the app entitlement, Release signing with team `7923U48U87` while Debug/CI remains unsigned, the enabled portal App ID, and `APPLE_CLIENT_ID=com.antonkosenko.timeoflifeapp` on the relay. Before shipping automatic account deletion for Apple users, the relay SHALL additionally have valid server-only Apple signing credentials, encrypted Apple-token storage, and verified consent-revocation notification handling. Missing revocation configuration SHALL NOT be treated as successful Apple unlinking. A real-device smoke checklist SHALL cover Apple sign-in, cancellation, private-relay email, Settings revocation/reconnection, and explicit deletion with automatic unlinking; unit tests with fake providers do not replace it.

#### Scenario: Signed build presents the Apple sheet
- **WHEN** the correctly entitled signed app invokes Apple authorization on a real device
- **THEN** Apple's native authorization sheet is presented

#### Scenario: Unsigned CI build still works
- **WHEN** CI builds Debug for the simulator
- **THEN** the build succeeds without signing and fake-provider unit tests run

#### Scenario: Production relay accepts real tokens
- **WHEN** the configured relay receives genuine matching Apple authorization from the signed app
- **THEN** it verifies the identity, exchanges the code, securely retains the revocable credential, and returns the standard Lifio session

#### Scenario: Smoke checklist verified before TestFlight
- **WHEN** the expanded real-device checklist passes against the intended deployment
- **THEN** automatic Apple account deletion can be considered ready for external submission, without implying guaranteed review acceptance

## ADDED Requirements

### Requirement: External Apple consent revocation preserves the account
A verified external `consent-revoked` event SHALL end Lifio sessions authorized before that event across devices and invalidate their recovery paths, but SHALL NOT delete the Lifio account, entries, categories, local files, outbox, cursors, or dormant timer draft. Native revocation/state observation SHALL sign out the applicable current Apple session without erasure. Reauthorizing the same Apple subject SHALL return to the existing account UUID and resume its retained data. Invalid, duplicated, or out-of-order notifications SHALL not delete data or invalidate newer completed reauthorization. Notifications for absent users SHALL NOT create accounts. Other Apple event types SHALL NOT be interpreted as consent to delete a Lifio account in this change.

#### Scenario: Remove Lifio in Apple Settings
- **WHEN** the user revokes Lifio's Apple authorization and the verified event is processed
- **THEN** pre-event Lifio sessions lose access while the account identity and server/local data remain intact

#### Scenario: Reconnect after Settings revocation
- **WHEN** the user later completes Apple authorization for the same subject without having deleted the Lifio account
- **THEN** they receive the original account UUID and return to its existing data rather than a fresh account

#### Scenario: Untrusted or stale notification
- **WHEN** a notification is invalid or an old verified event arrives after a newer successful authorization
- **THEN** it cannot delete the account or end the newer authorized session

### Requirement: Explicit Apple account deletion revokes authorization automatically
Explicitly deleting an Apple-created Lifio account SHALL automatically revoke the associated Apple authorization using a valid Apple access/refresh token. An existing user without a stored revocable token SHALL be able to provide fresh native authorization for the same subject without creating another Lifio account. Required revocable material SHALL be checked before purge; absence SHALL return an explicit credential-required precondition rather than silently skip unlinking. Pending revocation SHALL survive server restart and remain retryable after operational account deletion; it SHALL not be silently skipped, logged-and-forgotten, or represented as complete. Retained revocation secrets SHALL be authenticated-encrypted, excluded from logs, used only for unlinking, and removed upon acknowledged completion. Automatic processing SHALL target completion within 24 hours and alert on permanent/configuration failures or pending work older than 24 hours; failure to meet that target SHALL escalate for repair, not silently discard work. Temporarily retained material and completion limitations SHALL be disclosed accurately. Delayed automatic revocation SHALL not invalidate a newly accepted Apple signup. Native authorization cancellation SHALL send no deletion request.

#### Scenario: Automatic unlink succeeds
- **WHEN** explicit account deletion commits and Apple acknowledges revocation, including an already-invalid token acknowledgment
- **THEN** unlinking completes and retained revocation credentials are removed

#### Scenario: Apple temporarily unavailable
- **WHEN** operational purge commits but Apple revocation fails or its response is lost
- **THEN** minimal encrypted revocation work remains durable, the result does not claim Apple unlinking completed, and automatic retry resumes without restoring Lifio account data

#### Scenario: User cancels required Apple authorization
- **WHEN** an existing user without a stored token cancels the native authorization sheet during explicit deletion
- **THEN** the deletion request is not sent and the Lifio account/data remain intact

#### Scenario: Callback caused by our deletion
- **WHEN** automatic revocation emits a consent-revoked callback for an already-deleted account
- **THEN** handling is an idempotent no-op and neither recreates the user nor touches any new or unrelated account
