# Shunik

A pet-care iOS app (SwiftUI, iOS 18+) with a Go backend acting as identity + sync relay. **Local-first:** sign in once (mandatory), then your device is the source of truth and the backend relays sync between your devices and household.

Current state is the **auth scaffold** forked from Lifio: passwordless email-OTP + Sign in with Apple, account deletion, per-device sessions, and an auth-gated profile shell. The pet domain (household sharing, pets, vaccinations, medications, weight, grooming, documents, reminders) is defined in the active OpenSpec change `shunik-v1-foundation` and lands next.

| Doc | What it's for |
|---|---|
| [`docs/project-context.md`](docs/project-context.md) | Canonical architecture + repo context (for AI agents, S7) |
| [`AGENTS.md`](AGENTS.md) | Concise AI-agent entrypoint |
| [`openspec/`](openspec/) | Spec-driven change workflow (active: `shunik-v1-foundation`) |
| [`backend/api/openapi.yaml`](backend/api/openapi.yaml) | Authoritative API contract (OpenAPI 3.0, S10 — auth-only for now) |

## The app in one minute

1. **Log in** — the app launches into the auth flow (email OTP or Sign in with Apple); no anonymous use exists. After sign-in you land in the profile shell.
2. **Stay signed in on every device** — sessions are per-device (`X-Device-Id`); a revoked session locks to the auth gate without wiping local data.
3. **Sync** — the `SyncController` drains the outbox and pulls deltas on foreground/connectivity/manual "Sync now", and works fully offline when the tunnel drops. (No domain resources exist yet — sync is a wired-up no-op.)

Local data is **per-account**: one SQLite file per account (`shunik_<userId>.db` in the App Group `group.com.antonkosenko.shunik`); dormant files are kept (never wiped by logout or revocation); only the explicit per-account Erase deletes the active file. This rekeys to per-household files when household sharing lands. Writes go through a transactional **outbox**; deletions sit in a durable **undo buffer** restorable until the app restarts.

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

### iOS (`/ios/Shunik`) — SwiftUI, iOS 18+

XcodeGen-managed: edit `project.yml`, run `xcodegen generate` — never hand-edit the `.pbxproj`.

```bash
cd ios/Shunik
xcodegen generate
open Shunik.xcodeproj
```

- `API_BASE_URL` is injected per build configuration: Debug → `http://127.0.0.1:8080` (local backend; ATS allows plain HTTP only to `127.0.0.1`), Release → `https://shunik-api.antonkosenko.pro` (reserved — backend not yet deployed). On a physical device, use your LAN IP instead.
- Code signing is split per configuration: **Debug stays unsigned** (simulator/CI need no Apple Developer account); **Release signs** with team `7923U48U87` and carries the Sign in with Apple entitlement (App ID `com.antonkosenko.shunik` must have the SIWA capability enabled in the portal). The backend needs `APPLE_CLIENT_ID=com.antonkosenko.shunik` set or `/auth/apple` returns 503. Before TestFlight, also bind `7923U48U87.com.antonkosenko.shunik` in the `apple-app-site-association` file on `antonkosenko.pro`.
- Releases (TestFlight): cut via the manual **release** workflow (Actions → `release` → Run workflow, `version` = `X.Y.Z`) — validates strictly-greater-than-current on `main`, bumps `project.yml` (marketing version, build auto-+1, `Info.plist` mirrored), commits, pushes annotated tag `vX.Y.Z`. Profile shows the built commit in a trailing row so testers can report the exact commit.
- Tests & lint:

```bash
swiftlint lint --strict     # --fix autocorrects
xcodebuild -scheme Shunik -destination 'generic/platform=iOS Simulator' build
xcodebuild test -scheme Shunik \
  -destination 'platform=iOS Simulator,name=<available simulator>'
```

Warnings are treated as errors on the app and test targets through `project.yml`. Do not pass the flags globally on the command line; that also applies them to GRDB, which uses `-suppress-warnings`.

Unit tests cover the auth flow (validators, API client incl. 401→refresh→retry, repositories, auth service + view models) and the local-first layer (GRDB `LocalStore`, `UndoBufferStore`, sync skeleton). Out of scope: SwiftUI snapshot and on-device keychain tests.

### Sign in with Apple — manual smoke checklist

Unit tests fake the Apple authorization (`AppleAuthorizationProviding`), and Apple's identity-token JWKS is only fetched for real with `APPLE_CLIENT_ID` configured — so the following must be verified manually on a **real device** (the entitlement has no effect in the simulator):

Prerequisites: Release build installed on the device, backend reachable with `APPLE_CLIENT_ID=com.antonkosenko.shunik` (local or production), a sandbox/production Apple ID.

1. [ ] **Sheet presents** — launch the app (signed-out, the auth flow is the root screen) → tap *Sign in with Apple*; Apple's native authorization sheet appears (not an error).
2. [ ] **Sign-in succeeds** — complete the sheet (try a *Hide My Email* address); the app lands in the shell; Profile shows the session and "Sync now".
3. [ ] **Backend verified the token** — backend log shows the Apple sign-in line for the user (JWKS fetched, `aud` matched); the relay address `*@privaterelay.appleid.com` is stored as the email with `email_verified=true`.
4. [ ] **Per-user resume** — sign out and sign back in as the **same** account: the file reopens and resumes (outbox drains without a re-pull). Signing in as a **different** account opens that account's own file (no cross-account data). Log out and confirm the dormant file is kept (no wipe); only the explicit per-account Erase deletes the active file.
5. [ ] **Revoked session locks, never wipes** — force a server-side revocation of device A's refresh family (reuse detection, TTL expiry, or logout-revoked token): the app returns to the auth gate; local data is intact. Re-authenticating reopens and resumes the same account file. Logging out of device B must **not** affect device A (per-device logout).
6. [ ] **Cancel is silent** — start the Apple flow, dismiss the sheet; no error banner appears.
7. [ ] **Offline gates the button** — airplane mode on; the Apple button is disabled (dimmed); the email path still navigates.
8. [ ] **Idempotent re-sign-in** — sign out, sign in with Apple again; the same account file reattaches (no duplicate account).
9. [ ] **Hide My Email attribution (email-OTP path)** — on Continue with Email, the system sheet attributes to Shunik (never a numeric PID). Requires the `webcredentials:antonkosenko.pro` association verified (`swcd`) **and** the new app ID bound in the site's `apple-app-site-association`.

## CI (S6)

`.github/workflows/backend.yml` (gofmt, go vet, golangci-lint, test + coverage) and the Xcode Cloud `iOS PR Checks` workflow (xcodegen, SwiftLint, warning-as-error build, test) are **mandatory PR checks**. `.github/workflows/openspec.yml` enforces `openspec validate --all --strict` on every PR. See [`docs/ci.md`](docs/ci.md) for the full pipeline guide.

## Deployment (S4)

Backend deploys to a **GCP Compute Engine VM** (`shunik-backend`, us-east1-b) via Docker Compose: PostgreSQL 15, the Go backend, and Nginx (Let's Encrypt SSL) — **not yet provisioned**. Every push to `main` touching `backend/` will lint, test, build, and deploy automatically once the VM exists. Production URL (reserved, DNS pending): `https://shunik-api.antonkosenko.pro`. Manual deploys use the `backend` GitHub Actions workflow dispatch.

**Account deletion rollout**: see [`docs/account-deletion-operations.md`](docs/account-deletion-operations.md) for required signing/encryption/status secrets, Apple notification registration, pending-unlink recovery, backup-restore restrictions, and signed-device release gates. Local implementation or passing fixture tests do not prove production provisioning.

## Deferred / out of scope

- **Pet domain v1** (`shunik-v1-foundation` change): household sharing, pets + event base/details, medications, weight history, document library + CDN, reminder engine, canonical units.
- **Explicitly parked**: calendar integration (whole), owner analytics, vet reports, weight norm/BCS (v2), litter multi-create (v2), curated drug data, doc↔event links, per-pet roles, multi-household per user.
- **Sign in with Apple follow-ups** — nonce replay defense, identity merging between email-OTP and Apple accounts (kept separate by design), localized copy for Apple-path server error codes (generic banner for now).
- **Kafka** — deferred. **Rate-limit store** — in-memory; Redis before multi-instance.
- **SwiftUI snapshot / on-device keychain tests** — not automated; verified manually in the simulator.
