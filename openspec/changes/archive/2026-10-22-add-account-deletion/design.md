## Context

See `proposal.md` for motivation and approved scope. Planning base is fresh `origin/main` at `cc20ca6` (2026-10-21), not the older feature checkout used at the start of exploration.

Current constraints:
- Profile directly hosts Sign out and local erasure. `CachedSession.email` already supplies the account email offline.
- Access-token middleware verifies signature/expiry only. Removing a user currently does not invalidate an unexpired JWT. `/me` maps a missing user to 500.
- User-owned foreign keys have no user-level cascade. `008_refresh_recovery.sql` adds receipts that must be included in deletion; both Postgres and SQLite implementations matter.
- Apple sign-in submits only an identity token. No authorization-code exchange, Apple-token vault, revocation client, or notification handler exists.
- Recent refresh-recovery work persists one atomic credential snapshot and uses session-generation guards. Generic session failure clears credentials/cache but deliberately keeps account files.
- Deletions of individual entries/categories use tombstones and undo; account deletion must not use that resurrection/undo machinery.

## Goals / Non-Goals

**Goals:**
- Make explicit deletion irreversible and safely distinguishable from disconnect/sign-out, including after lost responses and on another device.
- Use existing auth, local-store, navigation, HTTP, logging, and encryption patterns instead of a new identity service or queue infrastructure.
- Automatically unlink Apple authorization without making a successful operational account purge depend on Apple's availability.
- Preserve account isolation and single-writer constraints, including extension access and late refresh/sync responses.

**Non-Goals:**
- No email-requested deletion, Apple/email identity merging, account switching UI, device quota, email editing, subscriptions, or scheduled deletion product.
- No remote wipe guarantee for offline devices or for devices that lack valid account-status evidence.
- No automatic account deletion on external Apple consent revocation. Permanently deleting an entire Apple Account is a separate Apple event, not added to this change.
- No backward-compatible local on-disk decoding branches; edit current shapes in place and update fixtures. Existing server-side Apple identities without a stored Apple token are real operational state, not a reason for legacy local decoders.

## Decisions

### D1 — Profile is the hub; Account is one more normal push

```text
Profile                           Account
  Account >                         ACCOUNT
  Sync status / Sync now              Email (read-only, full wrapping)
  Categories >                        Sign out
  Version                           THIS DEVICE
                                      Delete local data
                                    PERMANENT DELETION
                                      Delete account and local data
```

Push from Profile on the originating tab's existing navigation stack, as Manage Categories already does. Keep the tab bar hidden until returning to the root, system Back, interactive back, and no Done/sheet. Prefer the existing nested-navigation pattern over a parallel navigation owner. Keep existing sign-out/local-erase accessibility IDs where useful; add stable IDs for the Account link, email, permanent action, and progress state.

Reuse `ListRow`, native grouped sections, `Theme` semantic colors, existing type/spacing tokens, and destructive button semantics. The email is the server-stored account email, not a contact-edit field. Apple Hide My Email can therefore display a relay address. No additional network request or inference about a person's real email is needed. At large Dynamic Type, email, helper copy, and action labels wrap rather than truncate.

Footer meanings: sign-out keeps local data; Delete local data removes only this account's local file and signs out while retaining relay data; permanent deletion removes this account and synced data plus this phone's account-local copy. Other dormant accounts are never targets.

Alternative rejected: placing permanent deletion beside local erase on Profile; it crowds the settings hub and increases ambiguity between similarly named actions.

### D2 — Exactly one destructive confirmation alert

English source copy:
- Row and destructive confirmation button: **Delete account and local data**.
- Alert title: **Delete account and local data?**
- Message: **This permanently deletes your Lifio account and all synced entries, categories, and notes, and removes this account's local data from this iPhone. Your other devices will be signed out.**
- Secondary action: **Cancel**.

Provide equivalent Russian strings through both localization bundles and `L10n`, including accessibility and error/progress copy. One alert confirms the irreversible action. A native Apple authorization sheet, when needed to obtain a revocable token for the same identity, is authentication, not a second confirmation alert. Cancelling that sheet sends no deletion request. Ordinary sign-out still has no alert; local-only erase keeps its own single existing confirmation.

Prevent duplicate submissions and conflicting account actions while the deletion operation is in flight. An error/result notice is not a second deletion confirmation. Do not report completion merely because an alert was accepted.

### D3 — A read-only status capability supplies deletion evidence

Use a narrowly scoped, server-signed **account-status credential**, not a public UUID lookup, generic 401, expired access token, or permanent account tombstone. Include it in successful sign-in/refresh responses and `/me`; store it status-checked in Keychain with its exact account ID before enabling permanent deletion. Its only power is reading existence of that immutable account UUID.

The credential uses HS256 with a dedicated signing key (`ACCOUNT_STATUS_SECRET`, at least 32 random bytes, distinct from `JWT_SECRET`), `iss=lifio`, `aud=account-status`, `purpose=account-status`, `sub=<immutable account UUID>`, `iat`, and `exp=iat+30 days`. Both validators pin their own signing key and permitted token purpose; a status credential must never pass normal access-token validation. It cannot authenticate sync, refresh, logout, deletion, or another account's status. Only the dedicated status endpoint accepts it. Refreshing authenticated sessions renews the capability; replaying a status request does not renew it. Never include email in it or place it in URLs/logs. Use existing TLS API trust; there is no offline client-verifiable receipt or new asymmetric key distribution. Key replacement can invalidate outstanding status evidence, which safely preserves files rather than relaxing checks. A leaked status bearer discloses existence of one UUID until expiry: accept this limited risk with Keychain-only storage, TLS, and strict log redaction, not a claim of zero disclosure.

`POST /api/v1/auth/account/status`, with the capability as its dedicated Bearer credential, returns the scoped `{ account_id, state: active | deleted }`; derive the UUID only from verified `sub`, never an identifier in a request body or URL. The client must compare the returned UUID with the original intent/monitor UUID. A successful, correctly scoped response confirming absence of the original UUID is deletion evidence: deletion removes the user, and user UUIDs are never reassigned. An active-but-revoked account returns `active`. Database failure returns 5xx, never `deleted`. Invalid/expired credentials return generic 401 `unauthorized` with no existence disclosure, not an account-deleted error. Set no-store and rate-limit the endpoint.

Keep the capability in a separate account-keyed Keychain item, not as an access/refresh credential or a second `CredentialSnapshot`. Retain it after generic session lock so another launch can resolve a pending check; it is not a cached second login and cannot unlock anything. Explicit sign-out/local erase and completed confirmed cleanup clear that account's monitoring state; cancelling an active-account deletion intent removes that intent, not the still-authenticated account's normal status capability. Expired/missing capability, retired signing key, old client, offline request, malformed response, and every generic authentication error preserve files. Devices offline beyond the evidence lifetime may stay locked with their old dormant file until device-local app data is explicitly removed; do not promise unconditional eventual remote erasure or an account picker/erase-all screen that does not exist.

Alternatives rejected: treating 401/404 as deletion (unsafe), a public existence oracle (unnecessary disclosure), storing perpetual deletion tombstones (extra retained identifiers), and baking a new proof-verification public key into iOS (unnecessary for an online-only status check).

### D4 — Define APIs in OpenAPI together with implementations

Planned operations, with final schemas/error enums owned solely by `backend/api/openapi.yaml` at apply time:

| Operation | Authentication | Meaning |
| --- | --- | --- |
| `DELETE /api/v1/auth/account` | Normal Bearer + device ID | Delete the authenticated account, never an arbitrary requested user ID. |
| `POST /api/v1/auth/account/status` | Status-only capability | Confirm existence of the credential's account even after normal session loss. |
| `POST /api/v1/auth/apple/deletion-credential` | Normal Bearer + device ID + Apple identity token/code | For an existing Apple account without a stored token, verify the same Apple subject and save its revocable credential; do not create a user or a new Lifio session. |
| `POST /api/v1/auth/apple/notifications` | Verified Apple-signed payload | Process `consent-revoked` without invoking account deletion. |

`DELETE` returns 204 when account purge and Apple revocation (if applicable) have completed. It returns 202 with explicit `account_deleted: true, apple_revocation_pending: true` only after the account purge and durable revocation work commit together. Both are reliable account-deletion acknowledgments; 202 must not be described as complete Apple unlinking. Email-only deletion needs no Apple work.

Before sending DELETE, the client durably stores intent `{ accountID, statusCredential, phase }`. If delivery is ambiguous, query the status operation. `deleted` resumes cleanup without needing a login or another confirmation. `active` does not authorize automatic replay: offer an explicit retry through the same single-alert interaction. Invalid refresh, not-found routes, arbitrary 404s, and bare 401s never count as acknowledgments. A pending intent blocks sync until resolved or explicitly cancelled following an `active` verdict. An in-flight server deletion may linearize after a status read; subsequent authenticated calls are fenced and another status check resolves it.

### D5 — Atomic operational purge, explicit child deletes, and concurrency fences

Implement one Store operation with the same guarantees in both databases. Lock the account row and, in a single transaction, capture encrypted Apple revocation work where applicable; remove refresh-recovery receipts, refresh tokens, OTPs, entry-category joins, entries, categories, tombstones, Apple-vault rows, and finally the user. Do not enqueue record deletes, retain a user tombstone, or revoke in a separate transaction and call that deletion. Verify rollback leaves the complete pre-delete state.

Use explicit ordered child deletion rather than changing all foreign keys to cascades. This is auditable against the current schema and does not depend on SQLite's foreign-key pragma. Validate actual row counts and Postgres foreign-key parity, not only handler status codes.

Coordinate user-associated writes/session issuance with the account lifecycle lock so they linearize before or after deletion, never recreate children after purge or turn a routine race into partial deletion. On Postgres, take the user row lock first, consistently, in purge and affected refresh/catalog write transactions; an already missing account is an authentication failure. SQLite's transaction serialization must provide equivalent results. Handle deadlock/serialization retries and missing-account FK races with typed errors, not arbitrary 500-as-authentication failures. Fresh signup uses a new UUID and is not a stale-write retry.

Protected-request middleware checks the user's current existence in addition to JWT validity. A missing user cannot read, write, refresh, or recover a successor. Missing refresh rows remain `invalid_refresh`; do not invent a deleted-user verdict from an opaque unknown token. In-flight operations that started earlier must still recheck/fence before committing mutations. Service failures preserve the normal 5xx distinction.

After a valid access signature, a missing user returns generic 401 `unauthorized`, never a local-wipe instruction; a database error returns 5xx. Only D3's independently scoped successful verdict can establish deletion for another device.

### D6 — Apple tokens are obtained and encrypted, not inferred from identity JWTs

Extend normal Apple sign-in to send `identity_token` plus `authorization_code`. Exchange the single-use code with Apple's `/auth/token`; verify the returned identity and bind the token response to the same configured audience and Apple subject before storing a revocable refresh token. Continue verifying signature, issuer, audience, expiry, and strict existing claim parsing. Do not consume an authorization code twice after response loss without a recovery-aware outcome: a retry can reuse an already stored matching credential or request a fresh native authorization; it must not silently create another identity or erase data.

Use server-only `APPLE_TEAM_ID`, `APPLE_KEY_ID`, and `.p8` private-key material (`APPLE_PRIVATE_KEY`) to generate Apple's client secret. Recoverable Apple refresh tokens require authenticated encryption at rest with their own domain-bound associated data and keyring (`APPLE_TOKEN_KEYS`); adapt the existing recovery keyring pattern without sharing its receipt-specific data format or claiming Apple tokens are hashes. Private keys, client secrets, codes, tokens, and ciphertext never enter logs or the app bundle. Keep only what token revocation needs; do not persist raw authorization codes.

Authenticated user metadata states whether an Apple identity exists and whether fresh deletion authorization is required; the client must not guess either from an email suffix. Preserve the native Apple user identifier securely for credential-state observation of Apple-authenticated sessions. An Apple user already present from the identity-token-only implementation uses a native authorization sheet during explicit deletion if no revocable credential is stored. The dedicated authenticated credential endpoint verifies the same Apple subject, rejects email-only accounts, and stores the credential before DELETE; wrong identity/cancel fails safely without deletion. DELETE rechecks under its account lock and returns explicit 409 `apple_credential_required` with no purge if required token material is missing. A manual Settings-only unlink flow or silent successful skip is not the implementation for this change.

Email-only accounts bypass Apple work. Missing/invalid Apple server configuration is a deployment blocker for shipping automatic Apple deletion, not a silent successful no-op. Keep the OTP path usable when Apple sign-in is entirely disabled.

### D7 — Purge first with a tiny durable Apple-revocation outbox

Do not hold a database transaction open across Apple's network call. In the purge transaction, move the necessary encrypted token into a minimal revocation job (random operation ID, subject correlation digest for concurrency fencing, sealed credential/client configuration reference, created time, retry state). This is the only temporarily retained deletion-related secret; it is not a user account, does not retain entries/email, has no FK requiring the user to remain, and cannot authenticate Lifio.

After commit, attempt `/auth/revoke` immediately. Apple's documented 200 with empty body includes already-invalid tokens and completes/removes the job. On network/service/key failures, keep durable retry work and return the explicit 202 result if possible; on a lost response, status still proves the account is absent. A small in-process, database-backed worker resumes after restart with bounded backoff and exclusive job claims; no Kafka/new service. Alert on permanent/configuration failures and jobs older than 24 hours; target completion within 24 hours, escalate for operator repair rather than silently drop work or claim Apple revocation succeeded. Remove sealed material immediately on acknowledged completion and disclose pending retention truthfully.

To avoid a delayed old revocation invalidating a newly reauthorized grant, index pending jobs by `HMAC-SHA256` of the Apple subject using a purpose-separated server secret. Check the digest before exchanging any new authorization code; if a job is pending, return retryable 503 `apple_revocation_pending` without consuming the code or creating a session. Complete outstanding work, then let the user retry authorization. Serialize this check and grant acceptance with purge/job creation using the same subject-scoped lock; a pre-exchange check without that lock is insufficient. Settings-only revocation creates no deletion job and therefore does not block reconnection through this fence. Apple callbacks for a missing user are idempotent no-ops and never upsert a user. Repeated revoke/job execution must be safe.

Alternative rejected: log-and-forget revocation after purge (violates automatic completion), or refuse to delete Lifio data whenever Apple is unavailable (unnecessarily blocks account deletion).

### D8 — External consent revocation is a separate sign-out operation

Validate Apple's notification signature, issuer, configured audience, documented time claims, event type, subject, and event time against the official payload contract; enforce expiry if documented/present rather than requiring a third-party helper's unsupported claim shape. Do not copy a third-party helper's missing-audience validation or event-name assumptions. `consent-revoked` revokes all Lifio sessions authorized before that event and closes their recovery receipts; retain the user, Apple subject, entries, categories, all account files, and sync cursors. Erase unusable Apple-vault secrets when revoked, but only if they belong to the affected old authorization lineage; never discard a newer completed reauthorization's token. Retain the stable identity mapping. Duplicate/out-of-order notifications are idempotent and must not end a newer completed reauthorization.

Persist the latest verified consent-revocation cutoff on the user; carry original authorization time and lineage ID through refresh families, recovery, access-token claims, and associated Apple-vault metadata so rotation cannot evade the cutoff. Compare with authenticated Apple event time, never notification-arrival time. Existing server rows/access tokens without lineage are pre-cutoff when an applicable verified revocation exists; migrations preserve normal operation when no cutoff exists, without legacy local decoders. A genuinely fresh Apple sign-in after revocation starts a new authorization lineage against the existing UUID. Rejected pre-cutoff credentials return an ordinary authentication failure that preserves local files, not deletion proof. Ordinary per-device logout/reuse semantics remain unchanged. This also closes the signature-only JWT gap for pre-revocation access tokens.

Native credential-revoked observation and credential-state checks sign out the current Apple session promptly and preserve data. Never interpret `.notFound`/transferred/unknown state or a transport failure as account deletion. Primary all-device notification comes from the verified server endpoint, not a client assertion that can delete data. Ensure delayed native callbacks are checked against the current session/account generation and a fresh credential-state result.

This deliberately implements the user's retention decision. Apple's consumer documentation says reconnection can return to the same account; TN3194's deletion-oriented revocation section prescribes broader cleanup. Document this tension in review notes; citations do not guarantee approval. Automatic revocation initiated by our own deletion can generate the same callback, which must remain harmless.

### D9 — Local cleanup is account-scoped, durable, and coordinated

Use a single AppContainer/AuthService-owned operation, not networking/erase logic in the view. Capture the original account UUID and session generation. Pause sync, block new mutations/Stop intents for the target lifecycle, cancel or fence late auth work, and settle the current sync owner before destructive local work. A shutdown timeout is not permission to unlink a file while a writer is still live.

After confirmed deletion, durably mark that exact UUID as cleanup-required before clearing authentication artifacts. Clear the cross-process active-account marker and coordinate deletion with extension/local-store writers so an already-open Stop intent cannot recreate or write an orphan file during cleanup. End the corresponding Live Activity immediately (no Saved face and no invented entry), cancel its reap work, close all target database handles, and remove the file plus SQLite sidecars through LocalStore. Keep stable device identity and unrelated accounts' files/credentials untouched. Clear current auth/refresh snapshots, pending attempts, account cache, observability identity, and navigation only if still owned by that account/generation.

If local removal fails after server purge, sign out because the account no longer exists, retain a minimal Keychain cleanup marker, and offer retry from the auth gate. Resume unfinished cleanup before opening that UUID on subsequent launches, even if another account has become active. Extend LocalStore with an explicit by-account cleanup primitive for a dormant target; never repurpose active-file-only `eraseAll` to erase whichever account happens to be open. Remove cleanup/status intent only after durable cleanup succeeds. This is not a second cached session.

When another device receives a generic authentication failure, perform a scoped status check if valid evidence exists; only `deleted` schedules this cleanup. `active` or an inconclusive check locks with files intact. Retry retained monitor state only on auth failure/foreground/connectivity restoration with single-flight requests and bounded backoff, not continuous polling; stop at expiry. Do not expose data or block normal auth for another account. Clear the cross-process marker only when it still names the deleted UUID. A stale callback for A must never clear B's session, navigation, or Live Activity.

### D10 — Fresh registration is distinct from reconnecting

After explicit deletion, signup with the same email or Apple subject creates a new UUID and seeds a new file; pending old-account cleanup remains scoped to the old UUID. Do not copy its dormant data, outbox, or draft into the new file. While an old Apple revoke is pending, fence Apple signup as D7 describes. After Settings-only revocation, Apple upsert finds the existing UUID, and the dormant local file resumes under the normal account-bound rules.

### D11 — Privacy text matches operational deletion, not an impossible total-wipe promise

Update `web/privacy/index.html` alongside deployment, coordinating the active landing-page change. Explain the new navigation, local-only versus full deletion, Settings revocation retaining the account, automatic Apple unlink/retry, and delayed cleanup of offline devices. Remove the email-support-only deletion promise as the described product flow; general privacy contact remains, but scenario 4 is not implemented here.

Existing project context records 30-day backup retention. Distinguish immediate removal from live operational data from backup expiry and temporarily retained encrypted Apple-revocation work. Verify actual hosting/retention before publication (the current page's EU-hosting and hash-only-token claims already differ from newer deployment/recovery state); correct relevant factual claims, not the site's layout/toolchain. Establish a restore runbook that does not silently return a pre-deletion backup to live service without trustworthy reconciliation; if deletion reconciliation is unavailable, that snapshot must not be restored into live service. This plan does not assume an undeclared retained deletion ledger. No promise of immediate backup rewriting.

### D12 — Research basis and apply-time gates

Fetched 2026-10-21:
- Context7 library resolution: `Apple Human Interface Guidelines` / `managing accounts deletion` → `/websites/developer_apple_design_human-interface-guidelines`.
- Topic query `managing accounts app deletion account` returned no matching documents; do not claim it supplied account guidance. Use the official 5.1.1(v) page below for that topic.
- HIG query `confirmation alerts destructive actions` returned Alerts best practices: reserve alerts for uncommon irreversible actions, include Cancel, and clearly identify destructive consequences. This supports one explicit alert rather than duplicate confirmations.
- Earlier exploration Context7 `/timothylock/go-signin-with-apple`, queries on revoke-token mechanics and `consent-revoked` versus account deletion; supporting material only, no dependency adoption. The latter's examples differ from Apple's documented notification event names; official docs control.
- Official [5.1.1(v)](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion/), [TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple), [Apple token validation](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens), [revocation](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens), [notifications](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts), and [consumer Settings/reconnection guidance](https://support.apple.com/en-us/102571). Apple's documentation JSON endpoints under `https://developer.apple.com/tutorials/data/documentation/` supplied the complete API/technote content when HTML was JS-only.
- Version boundary: iOS 18 SDK via Xcode 16+, existing Go/JWT/Postgres/SQLite versions from the repository. Apple REST API is unversioned; recheck its current payloads before apply.
- New-library best-practice item is waived: no new library/service is selected; reuse existing HTTP/JWT/crypto/storage patterns. API/crypto-specific implementation lookup is not waived: the first apply tasks must reconfirm AuthenticationServices authorization/credential-state APIs and the existing Go JWT/encryption APIs, including domain separation and key rotation, before code. The planning lookup used 3 Context7 commands; no quota error occurred.
- Apply-time reconfirmation and the current-tree feature baseline are recorded in [verification.md](verification.md): Context7 reconfirmed HIG Alerts but did not index the native AuthenticationServices framework; official Apple JSON documentation supplied native authorization/state/cancellation APIs at the iOS 18 SDK boundary. Official Go JWT parser and AEAD references were fetched against the existing module/API patterns; no new dependency was selected. This is not a claim of production or signed-device verification.

## Risks / Trade-offs

- [Policy tension: Settings revocation retains data] → Keep the approved distinction explicit in specs, UI/privacy copy, and submission notes; obtain human review, never silently reverse the decision.
- [Status capability expires while a phone stays offline] → Lock and preserve when proof is unavailable; disclose conditional cleanup and retain explicit local erasure. No relaxed expiry checks.
- [Post-purge Apple work retains a secret temporarily] → Retain only sealed revocation material, alert on delay, erase on acknowledgment, and disclose retention. Do not describe hashing/pseudonymization as anonymization.
- [Old revocation cancels a new Apple grant] → Fence new Apple authorization against pending jobs; replay and delayed-callback tests cover re-registration.
- [Local cleanup races sync, refresh, account switching, or extensions] → One lifecycle coordinator, account/generation ownership, cross-process coordination, durable cleanup markers, and adversarial ordering tests.
- [New secrets or webhook registration missing] → Deployment checklist and real-device smoke gate; no successful silent skip.
- [Backup restore resurrects deleted data] → Verify 30-day expiry and document deletion-aware restoration before release; don't restore un-reconciled snapshots into production.

## Migration Plan

1. Reconfirm docs and current main; make additive server migrations for Apple-vault/revocation metadata, session authorization lineage, and the minimal revocation outbox. Inspect the actual schema before any remote migration. No remote write occurs during proposal creation.
2. Provision server-only Apple signing/encryption and status-signing configuration; wire secrets into deployment without exposing values. Register and validate the Apple callback endpoint. Verify managed-database permissions/backups and the worker's restart/claim behaviour.
3. Deploy backward-safe API additions first, then the iOS Account/deletion flow. Older clients without status capabilities retain lock-not-wipe and cannot remotely confirm deletion; never force a wipe as a rollout shortcut. Retain current identity-token-only login compatibility during rollout only if it does not bypass automatic-deletion prerequisites; updated clients always supply code.
4. Enable the user-visible deletion feature only when automatic Apple revocation, callback handling, status checks, and local cleanup are operational. Run the three approved scenarios, two-device checks, response-loss recovery, EN/RU/accessibility checks, and real-device Apple smoke before external submission.
5. Publish privacy wording with the matching shipped feature. Re-read against the exact submitted build and actual hosting/backup operations.
6. Rollback can hide the new Account deletion control and roll back additive application logic, but must retain a running revocation worker/status endpoint and cleanup recovery for already accepted deletions. Never restore deleted accounts as rollback and never remove encryption keys needed by pending jobs. Archive only after implementation and human approval; baselines remain untouched during planning.
