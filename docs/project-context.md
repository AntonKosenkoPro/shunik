# Shunik — Project Context

Durable architecture and repository context for AI agents working in this repo.
This is the **canonical context file** (S7): `AGENTS.md`, `openspec/README.md`,
and `openspec/config.yaml` all point here. If you need to know what this project
is and how it is built, read this file. It is kept accurate against the codebase
and the active OpenSpec change; update it in the same iteration as the code.

## What this is

**Shunik** — a pet-care iOS app (SwiftUI, iOS 18+, local-first) with a **Go backend**
acting as identity + sync relay. Forked from Lifio (`timeOfLife@607fae3`); the
time-tracking domain was stripped, the auth chassis kept.

Current state is the **auth scaffold plus household sharing (backend)**: passwordless email-OTP + Sign in with Apple,
account deletion, per-device sessions, tombstone store helpers, and an auth-gated
profile shell with a no-op sync skeleton — and, since §3, `households` /
`household_members` / `household_invites` with invite + accept + member-removal
endpoints. No pet domain exists yet. The v1 plan
lives in the active OpenSpec change `shunik-v1-foundation` (proposal + 6 spec deltas
+ design + tasks, migrated from explore): household sharing, pets + event
base/details, medication courses, weight history, document library, reminder engine,
canonical units.

Requirements live in `Requirements/FURPS/` (Lifio tables — Shunik rows land with the
domain work) and `Requirements/Usecases/` (ditto). The design system lives in
`Design/` (Lifio system — Shunik screens land with the domain work). Do not treat
any of them as Shunik's contract.

## Architecture: local-first (account-bound, household papers over)

The device is the **source of truth**; the backend is the **identity + sync relay**.
Sign-in is mandatory before any use (email-OTP or Sign in with Apple); the tracker
works fully offline afterwards. Local data is **per-account**: one SQLite file per
account (`shunik_<userId>.db` in the App Group), one active file at a time with the
active marker keyed on `user_id`. **This rekeys to `shunik_<householdId>.db` when
the `household-sharing` capability lands** (gate order becomes sign-in → resolve/
create household → open store → shell); until then, do not assume household scoping
anywhere in code.

### Data plane

- **Households** (day-1 sharing, backend done since §3): `households` (one per user, enforced by unique membership), `household_members` (equal owners + `added_by`), `household_invites` (email + SHA-256 token hash, 7-day expiry, replace-on-reinvite). Every sign-in ensures a household (`EnsureHousehold` in `VerifyOTP`/`AppleSignIn`); invites join via `POST /invites/accept`; removal revokes the removed user's refresh tokens before deleting the membership (lock-not-wipe). Pet tables scope to `household_id` when they land (§4).

- **GRDB `LocalStore`** (D1): SQLite via GRDB.swift in the App Group shared container
`group.com.antonkosenko.shunik` (entitlement in
`ios/Shunik/Shunik/Configuration/Shunik.entitlements`), data protection
`.completeUntilFirstUserAuthentication` (default). State tables (sync metadata),
the transactional outbox, the durable undo buffer, and per-resource sync cursors.
`LocalStore` is the **single chokepoint for all mutations** — no raw GRDB writes
outside it (lint/review rule).
- **Transactional outbox** (D2): every mutation writes the state change + an outbox
row in one transaction (`op, resource, record_id, payload, created_at`), so deletes
are first-class. Survives relaunch; each row maps to one idempotent POST / LWW
PATCH / hard DELETE on the relay.
- **Durable undo buffer** (D3): deletions enter an `undo_buffer` table (full
serialized snapshots) + remove the records in one transaction; restorable until the
app restarts — no wall-clock window. No outbox row is created while a deletion is
buffered. A cold launch commits whatever is still buffered.
- **Outbox/cursor/tombstone scaffolding is live but idle**: no domain resources
exist yet, so `SyncController.syncNow` is a no-op success. Triggers (foreground,
connectivity restored, manual), join-in-flight, and status publishing are wired;
per-resource drain + delta pull arrive with the first domain tables.

### Sync plane

Same contract as inherited: first-sync is pull-first, delta pulls use
`?modified_since=`, conflicts resolve **LWW on `updated_at`**, deletes propagate
**cross-device via tombstones** (`GET /api/v1/deletions?deleted_since=`), outbox
drain is idempotent with create-before-dependent ordering. Currently only auth/
account routes exist; the deletions route returns with the first synced resources.

### Incomplete / deferred (do not claim these are done)

Everything pet-shaped is unbuilt: pets + adaptive single-pet IA,
event base/details (vaccination, grooming, weight series), medication courses +
intakes, document library + CDN blobs, the reminder engine (rolling UN window),
canonical units + per-device lens, per-household data files (the store is still
per-account until the §5 household gate lands — the backend household already
exists), calendar integration (deferred whole), owner
analytics (deferred), vet reports (deferred), litter multi-create (v2), curated drug
data (never without vet review + disclaimer). No device management
UI exists yet. The iOS 18 lock-screen ControlWidget was never built here.

## OpenSpec routing

The repo is **spec-driven** (`openspec/config.yaml`, `schema: spec-driven`).
Fresh `openspec init` after the fork — no Lifio history was copied.

- **Baseline specs** (`openspec/specs/<capability>/spec.md`): none yet. The first
baselines form when `shunik-v1-foundation` archives at v1 landing.
- **Active deltas** (`openspec/changes/<change>/specs/<capability>/spec.md`):
`shunik-v1-foundation` (6 capabilities). Check `openspec list` before starting new
behavior work.
- **Rule: never edit a baseline spec directly** — behavior changes go through a
change with a delta spec. (Nothing to archive yet; do not "archive" the foundation
change piecemeal — it lands as one v1.)

## Repo layout

```
backend/                 Go backend (chi + pgx/Postgres; sqlite for tests) — relay: auth + account
  api/openapi.yaml      OpenAPI 3.0 spec (S10 — authoritative API contract, auth-only for now)
  cmd/server/main.go     entrypoint (run() int pattern; os.Exit owns lifecycle)
  internal/
    auth/                token service (JWT + rotated refresh) + otp service
    handlers/            HTTP handlers (auth + account)
    server/              chi router + middleware (recoverer, logger, jwtAuth)
    db/                  Store interface + postgres + sqlite impls + tombstone helpers
    migrations/          embedded SQL migrations (go:embed)
    email/               Sender (console + AWS SES) + localized bodies
    ratelimit/           in-memory token bucket
    config/              env config (fail-fast JWT_SECRET ≥32 bytes)
  Dockerfile, docker-compose.yml, docker-compose.prod.yml, nginx/, scripts/, Makefile
ios/Shunik/              SwiftUI app (iOS 18+), XcodeGen-managed (project.yml)
  Shunik/Features/Auth/        passwordless flow: Welcome → EmailEntry → OtpEntry; AppleSignIn
  Shunik/Features/AppShell/    profile-only shell (tabs land with the domain)
  Shunik/Features/Sync/        SyncController.swift (triggers + status; drain is a no-op stub)
  Shunik/Core/Storage/         LocalStore.swift (GRDB), UndoBufferStore.swift, SessionCache.swift
  Shunik/Core/                 networking, keychain, reachability, theme, navigation, DI, components
  Shunik/Localization/         en + ru Localizable.strings + L10n enum
  project.yml            XcodeGen spec — edit this, then `xcodegen generate`; never hand-edit the .pbxproj
.github/workflows/       CI: backend.yml + ios.yml (mandatory), openspec.yml, release.yml, ai-review.yml
docs/                    this file, ci.md, ios-test-loop.md, account-deletion-operations.md, review-process.md
openspec/                spec-driven change workflow (see openspec/README.md)
```

`RemoteCatalogRepository` is gone with the Lifio catalog; the relay client gets
rebuilt with the first domain resources.

## Build, test, run

### Backend (Go 1.24)
```bash
cd backend
go build ./...
go test ./... -cover            # tests use SQLite — no Docker needed
golangci-lint run               # linters (S6)
gofmt -l .                      # must be empty
go vet ./...
# Real run (needs Postgres):
cp .env.example .env            # DATABASE_URL, JWT_SECRET (≥32 bytes), EMAIL_BACKEND=console, OTP_*
docker-compose up -d postgres
go run ./cmd/server             # serves http://127.0.0.1:8080
```

### iOS (Xcode 16+, xcodegen, swiftlint)
```bash
cd ios/Shunik
xcodegen generate
swiftlint lint --strict         # linters (S6); --fix autocorrects
xcodebuild -scheme Shunik \
  -destination 'generic/platform=iOS Simulator' build
```

`project.yml` sets warnings-as-errors on the app and test targets. Do not pass those settings globally on the command line because GRDB intentionally compiles with `-suppress-warnings`.

Agents running the iOS suite: follow `docs/ios-test-loop.md` (booted-sim-by-ID destination, `-only-testing` filters, one `xcodebuild` at a time, log-file polling instead of `| tail`).

## API contract (`/api/v1`)

[`backend/api/openapi.yaml`](../backend/api/openapi.yaml) is the sole authoritative endpoint and schema reference (OpenAPI 3.0, S10). Auth-only for now (auth + account + Apple paths).

Durable invariants (carried from the fork, enforced by `internal/contract`): the error envelope is `{ "error": { "code", "message", "details": {} } }`; routes are Bearer-protected unless documented otherwise; IDs are client-generated UUID v7; creates are idempotent on ID; updates use last-write-wins on `updated_at`; hard deletes leave tombstones listed at `GET /deletions?deleted_since=`; delta pulls use `modified_since`. If an endpoint changes, update the server, iOS relay client, OpenAPI document, and contract tests together.

## Auth model (passwordless, per-device sessions)

Enter email → `otp/request` (always 202, account auto-created unverified) → server emails a 6-digit code → `otp/verify` → marks verified + issues JWT access (15 min) + rotated refresh. Sign in with Apple is the alternate path. The OTP proves email ownership — no separate "verify email" step, no passwords anywhere (R1). OTP codes and refresh tokens are stored only as **SHA-256 hashes**; tokens live in the iOS **Keychain**. `otp/request` and `otp/verify` are rate-limited per IP+email. The iOS `APIClient` retries protected requests once after a 401 using the single-flight refresh path; a rejected refresh transitions `SessionStore` to the locked state (files intact). Offline or transport failures never lock or wipe.

Sessions are **per-device**: the client mints a UUID v4 into the Keychain and sends it as `X-Device-Id` on verify/apple/refresh/logout; logout revokes only the calling device's family. A revoked, reused, or TTL-exhausted refresh **locks to the auth gate — never wipes**: local files, outbox, and cursors are untouched, and re-login reopens and resumes. The Keychain device UUID intentionally survives reinstall.

## Coding standards (Requirements S5)

Keep code **minimal and standardized**, following modern best practices.
- **Backend (Go):** idiomatic Go; `gofmt`-formatted (tabs); table-free errors via the domain error types in `internal/`; `context.Context` first param; no `panic` in request paths; `log/slog` only (never log codes/tokens/bodies/emails at info). No new deps without strong justification (S1: mainstream).
- **iOS (Swift):** SwiftUI, MVVM + Repository, all dependencies injected via `AppContainer`; every layer replaceable in tests; `@MainActor` on view models; views use only `Theme` semantic colors (no raw `Color` literals); user-facing strings via `L10n`/`Localizable.strings` (never hard-coded); iOS 18+ with no availability guards for older OS versions.
- **Tests (S3):** logic layer ~100% covered. Backend `go test` (SQLite, no Docker); iOS SwiftTesting. Don't leave failing tests; don't lower coverage by deleting tests.
- **Security (R1):** never persist/log passwords, OTP codes, or tokens in plaintext. Secrets from env. Keep user-enumeration closed (`otp/request` always 202).
- **Locales (U4):** every new user-facing string must be added to **both** `en.lproj` and `ru.lproj`, and to the `L10n` enum's `allCases` in `LocalizationTests` if enumerated.
- **XcodeGen-managed:** edit `ios/Shunik/project.yml`, run `xcodegen generate`, never hand-edit the `.pbxproj`.

### External docs first (ctx7)

Mandatory before implementing every feature/bugfix: research the topic, applicable HIG guidelines, Apple documentation, and best practices. Training data is stale by default — fetch, don't guess.

- **Bundle (max 5 commands, no secrets in queries):** 1× topic/problem-space query always; + 1× HIG query when UI is involved (known ID `/websites/developer_apple_design_human-interface-guidelines`); + 1× Apple API query with SDK pin when an Apple SDK is involved (known IDs `/websites/developer_apple_swiftui`, `/websites/developer_apple_activitykit`; pin pattern "iOS 18 SDK via Xcode 16+"); + 1× best-practice/setup query when an external lib/service is involved.
- **Waiver (not silence):** waive an inapplicable bundle item only with a one-line reason + evidence (e.g. "HIG N/A — `backend/`-only diff, no UI").
- **Procedure:**
  1. `npx ctx7@latest library <name> "<what to look up>"` — pick the ID (`/org/project`) by exact name match, description relevance, snippet count, source reputation, benchmark score.
  2. `npx ctx7@latest docs <libraryId> "<single concept>"` — one concept per query; separate `docs` call per distinct concept.
- **Cite:** proposal/design/tasks state the ctx7 library IDs + queries + pins used (e.g. "GRDB `/groue/grdb.swift` — `transaction observation`") or the waiver reasons.
- **Quota failure:** if a command fails with a quota error, tell the user to run `npx ctx7@latest login` or set `CONTEXT7_API_KEY` — never silently fall back to training data.

## Per-iteration revising process (Requirements S5)

On every iteration (feature/fix PR) the author MUST:
1. Start from a fresh base and stay isolated: work in a separated git worktree (`shunik.wt/<change-name>`, one branch per worktree; main checkout stays clean); `git fetch origin` + rebase onto `origin/main` before implementing and again before opening the PR (re-run affected linters/tests after each rebase; `push --force-with-lease`; never `merge main`). Worktrees do not lift the one-`xcodebuild` / one-simulator / single-writer-file serialization.
2. Complete the ctx7 research bundle before coding (topic + applicable HIG + Apple API + best practice, max 5 — see "External docs first (ctx7)"), with cites or waiver reasons recorded; re-confirm at apply time.
3. Run both linters and fix every finding: `golangci-lint run` (backend), `swiftlint lint --strict` (iOS); run the iOS build and inspect/fix every `xcodebuild` warning (app/test warnings are errors through `project.yml`); `gofmt -l .` must be empty.
4. Run both test suites green (`go test ./...`; `xcodebuild test -scheme Shunik -destination '<available simulator>'`).
5. Re-read the relevant `Requirements/FURPS/*.md` rows once Shunik rows exist and confirm the change aligns.
6. Update `AGENTS.md`, `README.md`, `docs/project-context.md`, the relevant `Design/*.md` files, and [`backend/api/openapi.yaml`](../backend/api/openapi.yaml) if architecture/contract/run steps or visual design changed. The OpenAPI spec is the authoritative API contract — keep it in sync with the handlers. Advance or archive the active OpenSpec change as appropriate.
7. Prefer reusing existing utilities/patterns over new code; remove dead code.

### Reproduce before fixing, verify after (bugfix rule)

No bugfix implementation without a recorded reproduction on the current tree:
1. **Reproduce first** — re-run the issue's repro steps (or write your own) and record the evidence (screen recording, log excerpt, or failing test).
2. **Research in parallel** — complete the ctx7 research bundle with cites or waiver reasons. Repro and research jointly gate implementation.
3. **Implement only after the repro confirms the bug.** If it cannot be reproduced, stop and report instead of guessing.
4. **Verify after** — re-run the identical repro on the fixed tree and record the evidence. Where automatable, encode the repro as a regression test (fails before, passes after).

## CI (Requirements S6)

`.github/workflows/backend.yml` (Go: gofmt, go vet, golangci-lint, test + coverage) and the Xcode Cloud `iOS PR Checks` workflow (xcodegen, swiftlint, warning-as-error xcodebuild build, test) are **mandatory PR checks**. `.github/workflows/openspec.yml` enforces `openspec validate --all --strict` on every PR. An **advisory** AI review (`ai-review.yml`) comments on every PR but never blocks. See `docs/ci.md` for the full pipeline guide.

## Deployment (S4)

Backend deploys to a **Google Cloud Compute Engine VM** (`shunik-backend`, us-east1-b) via Docker Compose (PostgreSQL 15 + Go API + Nginx/Let's Encrypt) — **not yet provisioned**; the Lifio VM is untouched and this backend has never been deployed. CI builds the image to `ghcr.io/antonkosenkopro/shunik/backend:latest`. Production URL (reserved, DNS pending): `https://shunik-api.antonkosenko.pro`.

**iOS production config**: `API_BASE_URL` is per build configuration, injected into `Info.plist` via xcconfig: `Debug` → `Config.Debug.xcconfig` → `http://127.0.0.1:8080` (local backend); `Release` → `Config.Release.xcconfig` → `https://shunik-api.antonkosenko.pro` (pending deploy). Code signing is **split per configuration**: Debug unsigned (simulator/CI), Release signed with team `7923U48U87` (SIWA entitlement live; backend needs `APPLE_CLIENT_ID=com.antonkosenko.shunik`). Before TestFlight: provision the VM + DNS + `APPLE_CLIENT_ID`, and add `7923U48U87.com.antonkosenko.shunik` to the `apple-app-site-association` file on `antonkosenko.pro` (the `webcredentials` entitlement is declared but the new app ID is not bound yet).

Releases use the manual `release` workflow (strictly-greater-than-current version check, multi-target plist bump, annotated `vX.Y.Z` tag).

## Pre-release policy

The app is unreleased; there is no on-disk data in the wild. **No backward compatibility / migration for local on-disk formats is needed before release.** Do not add legacy-decode branches, `legacy*` fields, or `migrateIfNeeded` paths to local stores. On-disk schema changes are applied by editing the `Codable` shape in place. Revisit this policy once a build ships to TestFlight or any external tester — the first `vX.Y.Z` release tag marks that point.

## Sign in with Apple

- iOS: `Features/AppleSignIn/` — `AppleSignInService` wraps an injectable `AppleAuthorizationProviding` (real + fake in tests). The button lives on `WelcomeView`; success posts the identity token via `AuthService.signInWithApple` → `POST /api/v1/auth/apple`, reusing the OTP session machinery.
- Backend: `POST /api/v1/auth/apple` verifies Apple's RS256 identity-token JWT via `internal/apple` (JWKS fetched with `github.com/MicahParks/keyfunc/v3`, `RS256`, `iss`/`aud`=Bundle ID/`exp`), upserts a user keyed by Apple's `sub`, and issues the same token pair as OTP verify.
- **Config-gated**: the route is always registered. When `APPLE_CLIENT_ID` is absent, the handler returns `apple_not_configured` (503).
- Manual smoke checklist: `README.md` — unit tests fake the Apple authorization and cannot cover it.

## Decisions log (precedents to respect)

- Forked from Lifio `timeOfLife@607fae3` (seed; strip `45fda7a` split out domain deletion; rename `879a1d0`; structural rename `dbc2f91`; scaffold `0cd3e2d`). Lifio history is preserved for archaeology; Lifio's `openspec/`, `Requirements/`, `Design/` were deliberately NOT copied as contract — only the plan artifacts migrated.
- §3 (branch `opsx/shunik-v1-foundation`): household sharing backend — `010_households.sql`, store impls (pg + sqlite), `POST /invites` / `POST /invites/accept` / `DELETE /members` / `GET /mine`, `EnsureHousehold` on both sign-in paths, invite-token SHA-256 pattern reused from OTP codes, revoke-before-remove ordering. Next: §4 pet tables scoped to `household_id`.
- Backend language is **Go**; mobile is **Swift**. No reintroductions.
- Auth is **passwordless** — do not reintroduce passwords.
- Tests use **SQLite in-memory** so they run without Docker.
- The Xcode project is **XcodeGen-managed** — never hand-edit the `.pbxproj`. Structural names are now Shunik (`ios/Shunik`, `Shunik`/`ShunikTests` targets + scheme).
- **Sign in with Apple** verifies RS256 via JWKS and is **config-gated** by `APPLE_CLIENT_ID`.
- The v1 domain plan (`shunik-v1-foundation` change) is the product spine: base+detail events, course→intakes medications, library documents on presigned CDN, unified reminder engine, canonical units, day-1 household sharing. Calendar + analytics + vet reports are explicitly deferred; weight norm/BCS is v2.
