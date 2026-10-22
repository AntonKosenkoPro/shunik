# Implementation evidence

## Workspace and baseline

- Started implementation on 2026-10-21 in `/Users/antonkosenko/work/timeOfLife.wt/add-account-deletion`, branch `opsx/add-account-deletion`.
- `git fetch origin` followed by `git rebase origin/main`: already up to date at `cc20ca6`.
- Read the apply instruction's proposal, design, tasks, and seven delta-spec context files. CLI state: `ready`; initial progress: 0/59 implementation tasks.
- Main checkout and unrelated worktrees are untouched. Only this change's planning artifacts were initially untracked.

## Environment and release prerequisites

- Go lint, SwiftLint, and Docker executables are installed. `actionlint` is not installed; do not describe an actionlint run as passed.
- Read-only GitHub environment secret-name inspection (`stage`) found `APPLE_CLIENT_ID`, `JWT_SECRET`, and `REFRESH_RECOVERY_KEYS`, but no `ACCOUNT_STATUS_SECRET`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`, or `APPLE_TOKEN_KEYS`.
- No secret values were requested or printed. No portal registration, remote migration, secret provisioning, deployment, or production deletion has been performed.
- Required signing/encryption/status configuration, Apple notification registration, intended-environment deployment, and real-device/two-device smoke remain release gates until explicitly verified. Local/fake-provider tests cannot satisfy those gates.

## Results

Implementation and verification results will be added only when observed. Task checkboxes are not evidence of deployment or real-device verification.

## Research gate (2026-10-21)

- Context7 (3 commands, no quota error): `library "Authentication Services" "authorizationCode credentialState revocation notification iOS 18 SDK Xcode 16"` returned irrelevant LocalAuthentication results; `library "Sign in with Apple" "authorizationCode credential state revoke tokens iOS 18 SDK"` resolved third-party supporting material, not the native framework; `docs /websites/developer_apple_design_human-interface-guidelines "confirmation alerts destructive actions"` reconfirmed HIG Alerts. Native API indexing failure is explicitly recorded, not replaced by training-data assumptions.
- Primary Apple documentation fetched directly via `/tutorials/data/documentation/` JSON: AuthenticationServices `ASAuthorizationAppleIDCredential.authorizationCode` (optional Data, UTF-8 string), `ASAuthorizationAppleIDProvider.getCredentialState(forUserID:completion:)` / async credentialState (requires native credential.user, not Lifio UUID), `credentialRevokedNotification`, and `ASAuthorizationError.Code.canceled` (correct path `asauthorizationerror-swift.struct/code/canceled`). All are introduced before the required **iOS 18 SDK via Xcode 16+** boundary.
- Reconfirmed complete official TN3194, token exchange (single-use authorization code, five-minute lifetime; matching redirect URI only if originally supplied), token revocation (empty 200 includes previously invalid tokens), and server-notification documentation. Policy/user-reconnection references remain those in design D12. Retention on Settings-only revocation is the user's explicit choice despite the documented policy tension, not an approval guarantee.
- Go API references fetched: `https://golang-jwt.github.io/jwt/usage/parse/` (valid methods, issuer/audience/subject requirements, issued-at sanity checks) and `https://pkg.go.dev/crypto/cipher#AEAD` (unique per-key nonces and matching associated data on Open). Reuse existing project APIs, pinned `github.com/golang-jwt/jwt/v5 v5.2.2`, keyfunc v3.8.0, Go 1.24; the AEAD methods used predate that version, no newer Go API is required.
- File coordination reference fetched: official Foundation NSFileCoordinator JSON (cross-process coordination, per-operation lifetime, one thread per coordinator, suspension/background considerations). A concrete alternative primitive, if selected during implementation, still needs its own API verification and concurrency tests.
- No new runtime dependency selected; new-library setup research is inapplicable. No quota failure or hidden login requirement occurred.

## Feature baseline and design gate

- Initial `cc20ca6` source inspection by area workers confirmed Profile directly exposed `ProfileSignOutButton` and `ProfileEraseLocalDataButton`, no Account destination, no account-delete/status route, and signature-only access-token middleware; `/me` treated missing user as an internal error. These are source-level feature-baseline observations, not a claimed end-to-end failing test.
- Read/checked FURPS F0/F2/F4/F5 and Common localization/HIG/security/test/contract constraints. Only independent account-specific deletion confirmation can authorize the deletion exception to F5; a generic auth failure or Settings revocation cannot erase data.
- Design/SCREENS/Account.md, AppShell.md, and INTERACTIONS.md were authored before UI implementation. Existing ListRow is reused, so no new shared-component spec is necessary.

## Deployment workflow checks

- `.github/workflows/backend.yml` now renders the five new environment values, with raw multiline Apple PEM single-quoted during `.env` sourcing; preflight checks status-secret separation and all-or-none Apple provisioning.
- Worker validated Ruby YAML parsing and extracted deploy script with `sh -n` and `bash -n`. Fake-secret preflight dry runs passed 5/5 cases: complete configuration (including multiline PEM), fully disabled Apple, rejected reused status/JWT secret, rejected partial Apple configuration, rejected malformed Apple encryption keys.
- This is static/local deployment wiring validation, not task 9.4 production provisioning.

## Current limitations

- Backend/iOS implementation and their tests are in progress; no build/test success is claimed yet.
- `openspec validate add-account-deletion --strict` and repository-wide strict validation pass (28/28 items) before runtime implementation completes.
- Backup script confirms a configured/default 30-day minimum local retention with scheduled pruning, not a remotely verified hard maximum across every backup copy. Live bucket lifecycle/retention verification remains outstanding.
- Docker CLI is present but its daemon is not running (`docker info` cannot connect to the local socket). No test has been redirected to production; real-Postgres parity remains unverified until a local instance is available.
- Argent device discovery found booted iPhone 16 Pro / iOS 18.6 (`F132A44E-4F25-45E9-9092-990139466F4E`). Discovery alone started no UI flow and is not UI acceptance evidence. The paired personal physical phone has not been used.

## Documentation checks

- Added `docs/account-deletion-operations.md` and README link with provisioning, pending-unlink response meanings, rollback/restore restrictions, and disposable-account signed-device smoke steps.
- Updated privacy security wording to distinguish hashed Lifio authentication records from encrypted refresh recovery and Apple revocation material; no claim that all server tokens are only hashes.
- Clarified expired/unavailable remote deletion evidence preserves a locked copy, and backup policy/rotation is not an instantaneous hard erasure promise.
- Python standard-library HTML parsing and required scope-text assertions passed; the Account design page is linked in `Design/README.md`. These are static documentation checks, not production retention or feature verification.

## Backend implementation handoff

- Initial backend worker implemented the API/migration/status/vault/purge/revocation/notification slices and reported clean gofmt, vet, lint, all 12 Go packages, and repeated db/handlers/apple race runs. Those checks are a handoff baseline, not final acceptance of every concurrency scenario.
- Independent review found additional cases requiring fixes/regressions before the related tasks can complete: raw Apple 400 bodies leaking through errors; missing-vault purge precondition races; post-revocation multi-device lineage and delayed-event ordering; notification receipt-before-effect delivery loss; missing-event-time fallback; subject-digest key rotation; and actual monitoring escalation. Relevant tasks remain unchecked pending proof.
- API wire names are `account_status_credential`, `account_status_expires_at`, `has_apple_identity`, and `apple_deletion_authorization_required`; final OpenAPI is authoritative for both clients.

## Backend notification fixes (2026-10-21, worker-reported)

- Receipt-before-effect fixed: `consent-revoked` now applies the cutoff first and records the JTI after; effect-free events keep record-first. Regression `TestNotifications_TransientApplyFailureRetryStillApplies` (fail first apply with 500, same-JTI retry applies).
- Missing `event_time` fixed: undated `consent-revoked` is rejected 400 with no receipt, so a delayed undated event cannot fabricate a cutoff. Regression `TestNotifications_UndatedConsentRevokedRejected`.
- Worker reports `gofmt` clean, `go vet` clean, `golangci-lint` 0 issues, `go test -count=1 ./...` all 12 packages green (incl. contract tests). Trivial lint renames applied in three sibling-owned new test files to unblock verification; content untouched.
- Independent backend verification (incl. real-Postgres parity) is still pending with the separate verifier; relevant tasks stay unchecked until that completes.

## Independent backend verification (2026-10-21, isolated local Postgres)

- Isolated `postgres:17` container on a temp port, `TEST_PG_DSN`-gated; stopped and removed after. No production/remote use, no secret changes.
- `gofmt -l .` clean, `go vet ./...` clean, `golangci-lint run` 0 issues, `go build ./...` OK.
- `go test ./... -cover` all green; `go test ./... -race` all green; real-Postgres `-race` all 22 `TestPostgres_*` pass (deletion parity, missing-vault abort, purge-vs-signup lock-order hammer: 75 deadlocks pre-fix over 60 rounds, 0 post-fix).
- Fixes proven by revert-run regressions: Apple 400 allowlist (no secret echo at error, `last_error`, or 202 body), missing-vault purge precondition (409, full rollback), auth-time cutoff with same-second fail-closed legacy freshness, notification apply-before-record with undated rejection, stuck-job background issue escalation via `observe.ReportBackground`.
- Open point: status-secret rotation is documented as drain-first (`.env.example`) with tests proving re-keying changes digests, but hard enforcement (dual-key fence or startup gate) is undecided and left out of code. Track as a design follow-up, not a silent guarantee.

## Apple key material (2026-10-21, local only)

- User provided path `/Users/antonkosenko/Downloads/AuthKey_929PVDRGN3.p8` (Key ID `929PVDRGN3` from filename; Team ID `7923U48U87` assumed from Release signing — confirm in portal).
- Verified without reading contents: PEM header present, `openssl pkcs8 -nocrypt` parses OK, permissions tightened to 600. Key contents never printed, committed, or sent anywhere; no GitHub/staging secret changes made per local-only instruction.
- Still to confirm in the Apple Developer portal: key has Sign in with Apple enabled and is associated with primary App ID `com.antonkosenko.timeoflifeapp`. User-reported 2026-10-21: key is stored in their password manager and shows the SIWA capability for the app (portal-side association independently unverified by tooling).
- User-authorized staging provisioning completed 2026-10-21: `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`, `APPLE_TOKEN_KEYS`, `ACCOUNT_STATUS_SECRET` all present in the GitHub `stage` environment (names verified via secret list; values never printed or logged). Temp key material destroyed after upload. No deployment triggered.
- Portal configuration user-reported 2026-10-21: email sources registered (`lifio.antonkosenko.pro` domain + `noreply@lifio.antonkosenko.pro`; SPF pending custom MAIL FROM `mail.lifio.antonkosenko.pro` verification in SES/Cloudflare) and the server-to-server notification endpoint set to the production notifications URL from the OpenAPI contract (route itself ships with this change — 404 until deployed). Deploy and real-device smoke remain pending.

## iOS implementation handoff (2026-10-21, worker-reported)

- `swiftlint lint --strict` clean (pre-existing `number_separator` config warning only), `build-for-testing` succeeded, full suite **829 tests / 79 suites passed** on booted iPhone 16 Pro / iOS 18.6. No `project.yml`/scheme churn, no commits, physical device and production data untouched.
- Three review gaps fixed with tests: signed-in `cleanupRetryNeeded` now surfaces a retry notice wired to `retryCleanup` (`cleanupRetryWhileSignedIn`); distinct short notice titles in EN+RU with `noticeTitlesDistinct` asserting title != message; gate retry reloads remaining markers and offers `.first`.
- New app code: coordinator, storage, credential observer, Account view + view model. Modified: auth models/DTOs (root status credential + expiry, provider metadata, 204/202 handling), API client custom-Bearer precedence with no status refresh, Keychain separation + `appleUserId`, LocalStore by-UUID erase with sidecars, sync fence, silent timer discard, Profile→Account move, RootView resume/monitor/gate retry, EN+RU copy, UITesting stateful stub.
- Independent iOS verification (task 9.6) still pending with a separate verifier; relevant integration tasks stay open until that completes.

## Independent iOS verification (2026-10-21, separate verifier)

- `project.yml` untouched, `xcodegen` correctly skipped. Booted iPhone 16 Pro / iOS 18.6, one `xcodebuild` at a time, log-file polling.
- `swiftlint lint --strict`: 0 violations / 199 files. `build-for-testing`: succeeded, no warnings-as-errors trips.
- Targeted deletion suites (coordinator/monitor/storage/navigation/VM, then remote/status/fence/observer/erase/bearer/repo/VM): 52 + 59 tests, all passed. Full suite: **829 tests / 79 suites, EXIT=0**.
- Wire reconciliation iOS ↔ OpenAPI ↔ backend JSON tags all match (status credential/expiry, provider metadata, status envelope, 202 flags, identity/code fields, 204-vs-202 semantics). Two fail-safe tolerant-reader asymmetries noted, no fix needed.
- No fixes required; no edits made by the verifier.

## User-authorized local setup

- User authorized starting Docker Desktop for dedicated local Postgres tests. `open -a Docker` completed; the independent backend verifier owns creation/cleanup of an isolated test container and actual parity results remain pending.
- User selected **local testing only** for Apple configuration. No GitHub/staging secret changes or deployment are authorized. The user is obtaining a registered Sign in with Apple `.p8` key; no key contents or local key file have been read.
- Official Apple instructions reconfirmed: Account Holder/Admin creates a Sign in with Apple-enabled key associated with the primary App ID, downloads `.p8` once, and records the Key ID. The key is not an App Store Connect API key. Current setup guidance was checked against Apple primary documentation plus Context7 supporting material, without adopting a new library.
