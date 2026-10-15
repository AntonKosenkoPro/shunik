# Lifio

A personal time-tracking app for iOS — minimal-effort tracking of where your time goes (widgets, shortcuts, integrations). **Local-first and account-bound:** sign in once (mandatory), then your device is the source of truth; the Go backend is the identity + optional sync relay.

Current scope: **auth MVP** (mandatory passwordless email-OTP or Sign in with Apple, per-device sessions) and the **Track experience** — a three-tab shell (Track/History/Insights) with a centered numeric timer, a plain-text name field with exact-text Recents chips, a live tag selector while running, a Profile destination, and a compact cross-tab running timer. There is no activity entity: entries own their text, ordered categories, and notes.

| Doc | What it's for |
|---|---|
| [`docs/project-context.md`](docs/project-context.md) | Canonical architecture + repo context (for AI agents, S7) |
| [`AGENTS.md`](AGENTS.md) | Concise AI-agent entrypoint |
| [`Requirements/FURPS/`](Requirements/FURPS/) | Requirements (FURPS+ table + use cases) |
| [`Design/`](Design/) | Text-based design system (colors, components, screens) |
| [`backend/api/openapi.yaml`](backend/api/openapi.yaml) | Authoritative API contract (OpenAPI 3.0, S10) |

## The app in one minute

1. **Log in** — the app launches into the auth flow (email OTP or Sign in with Apple); no anonymous use exists. After sign-in you land in Track.
2. **Name it** — type a name or tap a recent chip (exact match inherits that entry's categories; typing never starts timing).
3. **Start** — the centered numeric timer counts up while the device stays awake.
4. **Stop** — saves the entry to the local GRDB database and enqueues an outbox row; the `SyncController` drains the outbox and pulls deltas on foreground/connectivity/manual "Sync now" — and works fully offline when the tunnel drops.
5. **Switch tabs freely** — a running timer stays visible above the tab bar on History and Insights with return-to-Track and in-place Stop.

Entries, categories, the running timer state, the outbox, and the undo buffer live in the App Group shared container (`group.com.antonkosenko.timeoflifeapp`), ready for future cross-process system integrations.

### Local-first architecture (account-bound)

The app requires sign-in before any tracking use; after that the device is the source of truth and everything works offline. Local data is **per-account**: one SQLite file per account (`lifio_<userId>.db` in the App Group), one active file at a time; dormant files are kept (never wiped by logout or revocation), and re-login as the same account reopens and resumes — outbox drains, cursors continue, a running timer draft resumes. Sessions are **per-device**: a stable Keychain UUID travels as `X-Device-Id`, refresh families and logout/reuse revocation are scoped to one device, the refresh TTL is enforced, and a revoked/exhausted session **locks to the auth gate without wiping local data**. Writes go through a transactional **outbox** (deletes are first-class), deletions sit in a durable **undo buffer** restorable until the app restarts (committed on cold launch), and `SyncController` syncs via `?modified_since=` delta pulls with last-write-wins on `updated_at` — guarded to the same account it was activated under. Specs: `openspec/specs/` baselines (19 incl. `account-bound-store` / `device-sessions` / `apple-signin`) plus the archived `2026-10-02-reduce-codebase-complexity` change (wording-only docs-contract sync, folded into the baselines). Categories seed **per account file** on first open and are managed from Profile; entry and category deletions share the editor-Delete + shake-to-undo system confirmation grammar. The "via <Source>" labels and the iOS 18 lock-screen Control remain **incomplete**; device quota + picker (#46) is a pre-release blocker — see `docs/project-context.md` → "Incomplete / deferred".

## Security (R1)

- **No passwords.** Accounts authenticate by proving email ownership via a 6-digit OTP (stored only as a SHA-256 hash; `otp/request` always returns 202 — no user enumeration).
- **JWT access token** (HS256, 15 min) + **opaque refresh token** stored as a SHA-256 hash, rotated on every use with reuse detection.
- Tokens live in the iOS **Keychain**; `log/slog` never touches codes, tokens, or request bodies.

## Development

### Backend (`/backend`) — Go 1.24

Stack: `chi` router, `pgx`/PostgreSQL (SQLite for tests), JWT, AWS SES email. No Docker needed for tests.

```bash
cd backend
go build ./...
go test ./... -cover        # SQLite in-memory — self-contained
golangci-lint run && gofmt -l . && go vet ./...
# Real run (needs Postgres):
cp .env.example .env        # DATABASE_URL, JWT_SECRET (≥32 bytes), EMAIL_BACKEND=console, OTP_*
docker-compose up -d postgres
go run ./cmd/server         # serves http://127.0.0.1:8080 (watch stdout for OTP codes)
```

### iOS (`/ios/TimeOfLife`) — SwiftUI, iOS 18+

XcodeGen-managed: edit `project.yml`, run `xcodegen generate` — never hand-edit the `.pbxproj`.

```bash
cd ios/TimeOfLife
xcodegen generate
open TimeOfLife.xcodeproj
```

- `API_BASE_URL` is injected per build configuration: Debug → `http://127.0.0.1:8080` (local backend; ATS allows plain HTTP only to `127.0.0.1`), Release → `https://timeoflife-api.antonkosenko.pro`. On a physical device, use your LAN IP instead.
- Code signing is split per configuration: **Debug stays unsigned** (simulator/CI need no Apple Developer account); **Release signs** with team `7923U48U87` (development identity; archives sign distribution automatically) and carries the Sign in with Apple entitlement (App ID `com.antonkosenko.timeoflifeapp` must have the SIWA capability enabled in the Apple Developer portal). The backend needs `APPLE_CLIENT_ID=com.antonkosenko.timeoflifeapp` set or `/auth/apple` returns 503.
- Releases (TestFlight): cut via the manual **release** workflow (Actions → `release` → Run workflow, `version` = `X.Y.Z`, e.g. `1.0.0`) — it validates the version is strictly greater than current on `main`, bumps `project.yml` (marketing version, build auto-+1, `Info.plist` mirrored), commits, and pushes annotated tag `vX.Y.Z`. Pushing the tag triggers the **Xcode Cloud** workflow (tag pattern `v*`), which runs `ci_post_clone.sh` (`xcodegen generate`, since the `.xcodeproj` is gitignored), archives the Release configuration, and uploads to TestFlight automatically. Symbolication rides the same signed archive: `ci_post_xcodebuild.sh` uploads its dSYMs (`$CI_ARCHIVE_PATH/dSYMs`) to the Sentry staging + release projects, skipping gracefully when secrets are absent. Profile shows the built commit in a trailing row (`1.0.0 (a1b2c3d)`; `1.0.0 (a1b2c3d) • Debug` on Debug builds) so testers can report the exact commit. The integer build (auto-+1) survives solely as the App Store Connect upload identifier and is no longer displayed. The tag-triggered Cloud Test→Archive run is the post-bump verification — do not distribute the TestFlight build until it is green.
- Tests & lint:

```bash
swiftlint lint --strict     # --fix autocorrects
xcodebuild -scheme TimeOfLife -destination 'generic/platform=iOS Simulator' build
xcodebuild test -scheme TimeOfLife \
  -destination 'platform=iOS Simulator,name=<available simulator>'
```

Warnings are treated as errors on the app and test targets through `project.yml`. Do not pass the flags globally on the command line; that also applies them to GRDB, which uses `-suppress-warnings`.

Unit tests cover the auth flow (validators, API client incl. 401→refresh→retry, repositories, auth service + view models) and the local-first layer (GRDB `LocalStore`, `UndoBufferStore`, `SyncController`, provenance). Out of scope: SwiftUI snapshot and on-device keychain tests.

### Sign in with Apple — manual smoke checklist

Unit tests fake the Apple authorization (`AppleAuthorizationProviding`), and Apple's identity-token JWKS is only fetched for real with `APPLE_CLIENT_ID` configured — so the following must be verified manually on a **real device** (the entitlement has no effect in the simulator):

Prerequisites: Release build installed on the device (`Product → Destination → your device`, Release scheme archive or Run with Release config), backend reachable with `APPLE_CLIENT_ID=com.antonkosenko.timeoflifeapp` (local or production), a sandbox/production Apple ID.

1. [ ] **Sheet presents** — launch the app (signed-out, the auth flow is the root screen) → tap *Sign in with Apple*; Apple's native authorization sheet appears (not an error).
2. [ ] **Sign-in succeeds** — complete the sheet (try a *Hide My Email* address); the app lands in the shell; Profile shows the session and "Sync now".
3. [ ] **Backend verified the token** — backend log shows the Apple sign-in line for the user (JWKS fetched, `aud` matched); the relay address `*@privaterelay.appleid.com` is stored as the email with `email_verified=true`.
4. [ ] **Sync works** — start/stop a timer, run "Sync now"; the entry appears on the relay (check via a second sign-in on another device/simulator, or the backend DB).
5. [ ] **Per-user resume** — with entries + a running timer on device A, log out and log back in as the **same** account: the file reopens and resumes (entries list intact, timer draft resumes, outbox drains without a re-pull). Logging in as a **different** account opens that account's own file (no cross-account data). Log out and confirm the dormant file is kept (no wipe); only the explicit per-account Erase deletes the active file.
6. [ ] **Revoked session locks, never wipes** — force a server-side revocation of device A's refresh family (reuse detection via a replayed refresh token, a TTL-expired refresh, or a logout-revoked token): the app returns to the auth gate; all local data (entries, categories, timer draft, outbox) is intact. Re-authenticating reopens and resumes the same account file. Logging out of device B must **not** lock or affect device A's session (per-device logout).
7. [ ] **Cancel is silent** — start the Apple flow, dismiss the sheet; no error banner appears.
8. [ ] **Offline gates the button** — airplane mode on; the Apple button is disabled (dimmed); the email path still navigates.
9. [ ] **Idempotent re-sign-in** — sign out, sign in with Apple again; same user (the same account file reattaches, no duplicate account or duplicate seeded categories).

### Live Activities — manual smoke checklist

Live Activities need a real device with Dynamic Island (the simulator shows the Lock Screen banner only) and a signed-in account with at least one category.

1. [ ] **Island appears** — start a timer on Track; the Dynamic Island shows the compact face (first-category icon + ticking elapsed).
2. [ ] **Expanded card** — long-press the Island; the expanded card shows the exact name, icon, elapsed, Stop, and Go-to-Track.
3. [ ] **Go to Track** — tap the compact face (or the Go row); the app opens on the Track tab with the timer running.
4. [ ] **Stop from the Island** — stop from the expanded card or the Lock Screen banner; the entry saves as `manual` (no "via" label), the banner shows the Saved card with the final duration, then dismisses within seconds and the Island collapses.
5. [ ] **Minimal face** — with music (or another Live Activity) active, the timer collapses to the icon-only minimal face without layout breakage.
6. [ ] **Lock Screen banner** — lock the device while running; the banner shows icon + name + ticking elapsed + Stop.
7. [ ] **Dismissal delay** — confirm the Saved card lingers long enough to read but never minutes; record the final seconds in the change's spec delta (task 5.1).

## CI (S6)

`.github/workflows/backend.yml` (gofmt, go vet, golangci-lint, test + coverage) and the Xcode Cloud `iOS PR Checks` workflow (xcodegen, SwiftLint, warning-as-error build, test) are **mandatory PR checks**. See [`docs/ci.md`](docs/ci.md) for the full pipeline guide.

## Deployment (S4)

The backend deploys to a **GCP Compute Engine VM** (`timeoflife-backend`, us-east1-b) via Docker Compose: PostgreSQL 15, the Go backend, and Nginx (Let's Encrypt SSL). Every push to `main` touching `backend/` lints, tests, builds, and deploys automatically. Manual deploys use the `backend` GitHub Actions workflow dispatch. Production URL: `https://timeoflife-api.antonkosenko.pro`.

## Deferred / out of scope

- **Sign in with Apple follow-ups** — account-deletion token revocation via Apple `/auth/revoke`, nonce replay defense, credential-state observation, identity merging between email-OTP and Apple accounts (kept separate by design for now).
- **iOS History list/edit UI** — the History day-grouped list and entry editing (tap a row → unified entry form) have shipped (deferred filtering lives in `docs/history-roadmap.md`); the Insights breakdown v1 (period switch + category/text lenses, mirror-only) is implemented.
- **App-wide Undo UI, "via <Source>" labels, lock-screen Control** — local-first storage/sync foundations are done; these UI surfaces are open tasks (the widget extension target exists for Live Activities — Dynamic Island + Lock Screen banner, #40 — but the ControlWidget toggle itself is still deferred). **Device quota counting + 6th-device picker (#46)** is a pre-release blocker on top of the per-device session foundation; a multi-session device switcher is future work (one active session per device; switching re-authenticates).
- **Kafka** — deferred (S1 names it; not needed yet). **Rate-limit store** — in-memory; Redis before multi-instance.
- **SwiftUI snapshot / on-device keychain tests** — not automated; verified manually in the simulator.
