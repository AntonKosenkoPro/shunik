# Account deletion: deployment and recovery gates

This runbook accompanies `openspec/changes/add-account-deletion/`. It is not evidence that the feature, secrets, Apple portal configuration, or deletion-enabled build has been deployed. Check the change's `verification.md` and unchecked tasks for observed results.

## Provision before enabling deletion

| Server value | Purpose |
| --- | --- |
| `ACCOUNT_STATUS_SECRET` | At least 32 random bytes, distinct from `JWT_SECRET`; signs read-only account-status evidence, not login credentials. |
| `APPLE_TEAM_ID` | Developer team owning the configured native Apple client. |
| `APPLE_KEY_ID` | Registered Sign in with Apple signing-key identifier. |
| `APPLE_PRIVATE_KEY` | Raw multiline PKCS#8 `.p8` PEM; never put it in source, an iOS bundle, tickets, chat, or logs. |
| `APPLE_TOKEN_KEYS` | Comma-separated 64-hex AES-256 keys, primary first; retained keys cover existing credentials and pending revocations. |

`APPLE_CLIENT_ID` remains the native bundle ID. A redirect URI is optional unless included in the original authorization. Apple disabled and Apple partially configured are different states: partial automatic-unlink provisioning must not silently claim successful revocation.

Use the intended GitHub environment's secret manager; inspect names, never values. The workflow renders raw PEM as a single-quoted multiline environment value and checks configuration before recreating services. These checks do not register an Apple key or callback for you.

Register the verified Apple-notification endpoint on the primary App ID: Certificates, Identifiers & Profiles → Identifiers → select the App ID → enable Sign in with Apple → Configure → enter the backend's public notifications URL (exact path from `backend/api/openapi.yaml`; absolute URI with scheme, host, and path; TLS 1.2+; one URL per app grouping; backend must be deployed and reachable first), then Done and Save. Separately, Services → Sign in with Apple for Email Communication manages private-relay email sources only — register the SES sending domain there if login mail must reach Apple private-relay addresses. Use a designated disposable account for signed-device checks. A fixture cannot verify the portal or Apple's real authorization sheet. Do not destructively test a personal production account without its owner's explicit consent.

## Operational meaning

- **Settings-only Apple revocation:** invalidate affected sessions, preserve Lifio identity/data; reconnect the same Apple subject to its existing account.
- **Explicit deletion:** atomically remove operational identity/data/session records. Scoped status evidence can establish absence of the original immutable UUID without granting access.
- **204:** operational deletion and Apple unlink complete, or Apple not applicable.
- **202:** operational deletion committed; minimal encrypted automatic-revocation work remains. Do not announce completed Apple unlink.
- **401/404/timeout/5xx alone:** not deletion proof; never erase a local file on that basis.

Status evidence expires after 30 days. A phone offline beyond that window can retain a locked local copy; do not promise unconditional or immediate remote wiping. Status evidence is not a second cached login.

## Pending Apple revocation

Monitor the durable worker; alert on permanent/configuration errors and work older than 24 hours. Investigate keys/client/network without dumping credentials or ciphertext. Never drop a job merely to clear an alert, restore its deleted user, or claim an unacknowledged unlink completed.

Keep encryption keys available until affected jobs/credentials are handled. Fingerprint/key changes must preserve pending-job lookup so a new authorization cannot race an old revocation. Rollback must retain worker/status support for accepted deletions even if the new UI is hidden.

## Backups and restoration

`backend/scripts/supabase-backup.sh` configures a default 30-day local retention threshold with scheduled pruning; it does not prove a hard maximum for every off-site copy. Before submission, verify actual bucket lifecycle, rotation cadence, access controls, and applicable retention; align published policy with observed operation.

Do not silently restore a pre-deletion backup to production:

1. Restore only into an isolated, non-public verification environment.
2. Establish trustworthy deletion reconciliation for all accounts possibly deleted after the snapshot. Expired capabilities or a missing list are not reconciliation.
3. Purge those accounts/data before exposure; ensure old sessions/recovery receipts cannot become valid again. Reconcile pending revocations and decryption keys separately.
4. If reconciliation is unavailable, **do not restore that snapshot into live service**. No undeclared permanent deletion ledger is assumed.
5. Record results and obtain human approval before promotion.

Do not promise instantaneous rewriting of retained backups. General privacy contact can remain public; an email-requested deletion workflow is outside this change.

## Release gates

- Backend contracts, migrations, SQLite and real-Postgres concurrency/parity checks pass.
- Strict SwiftLint, warnings-as-errors build, full iOS tests, and account/extension isolation checks pass.
- Intended-environment secrets, callback registration, worker restart/retry, and alert delivery are verified.
- Disposable-account scenarios 1–3 pass on signed devices: Settings reconnection retains UUID; signup after explicit deletion gets a new UUID.
- Two-device proof/expiry and local-cleanup retry pass; offline is never treated as deleted.
- English/Russian and accessibility checks pass. Publish privacy copy with the matching shipped app/backend only.
- Task completion does not authorize merge, archive, production migration, or deployment.

## Signed-device smoke (disposable accounts only)

Record app commit, backend revision/environment, locale, OS, and the test's outcome. Do not attach tokens, authorization codes, private keys, emails, or database dumps. A model cannot substitute a fake-provider test for this checklist.

### 1. Revoke Apple access, then reconnect to the same account

1. Sign in with Apple on two test devices; create and sync a recognizable test entry. Record the fixture's account UUID through an authorized test diagnostic, not a public account lookup.
2. On one phone, open Settings → Apple Account → Sign in with Apple → Lifio and revoke authorization.
3. Verify that the native state check/verified callback signs out affected sessions. Confirm the tracked data and local file are retained, not erased.
4. Authorize the same Apple identity again. Confirm the same account UUID and recognizable entry return, including any retained draft/outbox state covered by the test fixture.
5. Deliver a duplicate/delayed old callback in an isolated fixture and confirm the newly authorized session is not revoked.

### 2. Explicitly delete an Apple-created account

1. Open Profile → Account. Confirm the stored email is visible (test Hide My Email separately) and sync controls remain on Profile.
2. Tap Delete account and local data. Check that the single alert's title and destructive button name both consequences. Cancel once and verify nothing was deleted.
3. Repeat and confirm once. If the account predates token capture, finish the native authorization for the same identity; cancelling that sheet must send no DELETE.
4. Verify the auth gate appears, the target local file/session artifacts are removed, its Live Activity disappears without Saved, and operational server records are purged. Preserve another dormant account and the device identifier.
5. Confirm Apple's authorization is revoked. If the fixture forces an Apple outage, check explicit pending status, restart-safe retry and monitoring; do not mark automatic unlink complete until acknowledged.
6. Re-register using that Apple identity after pending unlink completes. Confirm a new UUID with none of the deleted entries.

### 3. Explicitly delete an email-created account

1. Sign in with an email disposable account; create/sync a recognizable entry.
2. Follow Account → Delete account and local data → one confirmation. Verify the same operational/local cleanup and auth gate, without any Apple exchange/revoke request.
3. Register the same email again. Confirm a fresh UUID/file and no old content.

### Cross-cutting cases

- Keep the second device offline during deletion: no immediate-wipe claim. On reconnect, valid matched deletion evidence removes only the deleted UUID's copy. Expired/missing evidence or an ordinary auth rejection must preserve a locked copy.
- Exercise local-only Delete local data separately: server account/entries remain, other devices remain signed in, and signing back in can pull retained server data.
- Exercise ordinary Sign out: no confirmation; local files/drafts remain. It must not become permanent deletion.
- Interrupt DELETE delivery after commit, restart the app, and verify status-based completion rather than another login or an assumed 401 success.
- Inject local-removal/Keychain failure in a fixture after confirmed deletion; verify safe gate and persistent cleanup retry. Switch to another account before the retry and prove it is untouched.
- Check English and Russian, largest accessibility text, long email, VoiceOver labels, light/dark, and iOS 18. No additional destructive confirmation alert is allowed.
