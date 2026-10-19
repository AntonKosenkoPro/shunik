# Lifio — Project Context

Durable architecture and repository context for AI agents working in this repo.
This is the **canonical context file** (S7): `AGENTS.md`, `openspec/README.md`,
and `openspec/config.yaml` all point here. If you need to know what this project
is and how it is built, read this file. It is kept accurate against the codebase
and the active OpenSpec change; update it in the same iteration as the code.

## What this is

**Lifio** — a personal time-tracking iOS app (SwiftUI, iOS 18+, local-first and **account-bound**).
The repository contains a **Go backend** (identity + sync relay) and an **iOS app**.

Current product scope:
- **Auth MVP** — passwordless email-OTP sign-up/sign-in plus **Sign in with Apple** (config-gated), implemented end-to-end.
- **Track experience** — a three-tab shell (Track / History / Insights) with a centered numeric timer, a name row opening the shared name picker (autofocused field pinned on top, scrollable suggestions over all committed names newest-first, exact match included) plus exact-text Recents chips (cap 12 in a fixed-height internally-scrolling area, newest first, first-position category icons, filled accent selected presentation; tap fills the field and inherits that entry's ordered categories) and no editing affordance on Track, a running state with leading-aligned locked name + live select-only tag selector (a separator sits between each section caption and its chips), a Profile destination (pushed per-tab with the tab bar hidden), and a compact cross-tab running timer. The running timer additionally mirrors to a Live Activity (expanded Island with big timer + Stop + name with icon category chips, transparent Lock Screen banner with Stop and return-to-Track — system glass on iOS 26+, solid card below — `live-activities-natural-glass` change; retag refreshes chips in place with the live icon following the first ordered category, timer fallback when empty). Categories are optional per-entry metadata, seeded locally and managed from Profile. There is no activity entity: entries own their text, ordered categories, and notes at write time and history never mutates retroactively. Landing is the result of the archived OpenSpec changes `redesign-track-experience`, `keep-timer-position-on-stop`, `unify-activity-preparation-flow`, `refine-selected-activity-from-track`, `add-category-management`, `refine-track-recents`, `remove-activities-layer`, `dedicated-name-picker`, and `per-tab-navigation-paths`.
- **History** — a read-only, day-grouped list of committed time entries in the History tab (archived `history-entry-list`, nav bar made persistent by `revert-history-nav-collapse`): `HistoryView` + `HistoryViewModel` with `EntryRow` rows (Variant H layout: first-position category icon, name + natural-language duration, category names + "via <Source>" provenance + timeframe, blue `note.text` glyph when the entry has non-empty notes), relative-then-absolute day labels, per-day totals as an always-visible subheader line under each day label (Calendar-Agenda-like bare two-line headers in a native `List(.plain)` — no background fill, pinned bleed accepted on every OS; opaque tab bar on iOS 18, glass on iOS 26+), a permanently visible nav bar, and the compact cross-tab timer preserved. Tapping an entry row pushes the unified entry form onto the History navigation stack (archived `edit-entry-from-activity-detail`, repointed by `remove-activities-layer`, pushed by `fix-entry-form-gestures` so the edge-back gesture works): EDIT for `manual` entries (prefilled name/start/end/categories/notes, Save via LWW `updateEntry`), LOCKED read-only for imported entries (delete only), bottom destructive Delete entering the durable undo buffer with shake-to-undo and no toast. In-progress drafts never appear in the list and never contribute to totals. The populated list offers pull-to-refresh (`HistoryPullModel` verdict flow, `history-pull-to-sync`): online runs/joins a sync cycle with the existing cycle-exit reload as the sole refresh; offline shows an inline offline banner (the user is always signed in — the mandatory gate removed the signed-out branch); pull-awaited failures show an OK-only dialog. Manual logging (`Features/ManualEntry`, archived `add-manual-entry`): a Calendar-style Log Time sheet (Name + Start + End + Categories + Notes in that order, Start/End as separate cards with inline pickers, Add validity gate) from the History toolbar `[+]`, saving committed `manual` entries through the outbox. Deferred follow-ups (filtering, History-row swipe delete, undo polish + bulk-delete cap) live in `docs/history-roadmap.md`.
- **Insights** — a read-only, mirror-only breakdown of committed time in the Insights tab (`Features/Insights`, `insights-v1-breakdown` change): a `Today | This week | All time` period switch (default `This week`), a hero period total, a `By category | By text` lens toggle (default `By category`), and proportional rows with max-scaled bars. The text lens groups by exact entry text (`Gym` ≠ `GYM`); each entry's full duration attributes to its text row. Category rows attribute the full duration to every attached category (rows may sum above the hero) with a one-line footnote naming the rule; rows are not tappable; no percentages, targets, or comparisons. Aggregation is pure and in-memory over the existing `LocalStore` reads; no navigation, drill-in, or filtering yet.

Requirements live in `Requirements/FURPS/` (the FURPS+ table) and `Requirements/Usecases/` (use-case narratives). The design system lives in `Design/` (see `Design/README.md`): all visual, component, and interaction decisions for iOS are Markdown specs so they can be implemented deterministically.

## Architecture: local-first (account-bound)

The device is the **source of truth**; the backend is the **identity + sync relay**. The app is **account-bound**: sign-in is mandatory before any Track/History/Insights use (email-OTP or Sign in with Apple), then the tracker works fully offline — anonymous use no longer exists. Local data is **per-account**: one SQLite file per account (`lifio_<userId>.db` in the App Group), one active file at a time with the active marker keyed on `user_id`; dormant files are kept, and re-login as the same account reopens and resumes (outbox, cursors, timer draft). Sessions are **per-device**: a stable Keychain UUID sent as `X-Device-Id`, with per-device refresh families, enforced refresh TTL, per-device logout/reuse revocation, and **lock-not-wipe** on revocation (local files are never touched by auth failures). The archived OpenSpec change `account-bound-local-data` delivered the per-account store (`account-bound-store` baseline) and per-device sessions (`device-sessions` baseline). Until then, the existing local-first contract lives in the `local-first-store`, `sync-client`, `entry-provenance`, and `lock-screen-controls` baselines; the category-management baseline is in `openspec/specs/category-management/`.

### Data plane

- **GRDB `LocalStore`** (D1): SQLite via GRDB.swift in the App Group shared container `group.com.antonkosenko.timeoflifeapp` (entitlement in `ios/TimeOfLife/TimeOfLife/Configuration/TimeOfLife.entitlements`), data protection `.completeUntilFirstUserAuthentication` (default). **Account-bound files**: `LocalStore` opens `lifio_<userId>.db` for the signed-in account (built lazily/swapped by `AppContainer` on sign-in; nothing touches a store before an account is bound — seed, `commitAll`, and first sync live behind the gate). Starter categories seed **per account file** on first open. State tables (entries, categories, entry_categories with position, timer_state), the transactional outbox, the durable undo buffer, and per-resource sync cursors. Accessible cross-process (widgets, Screen Time extension, lock-screen Control intents) and after first-unlock-since-boot. `LocalStore` is the **single chokepoint for all mutations** — no raw GRDB writes outside it (lint/review rule).
- **Transactional outbox** (D2): every mutation (create/update/delete) writes the state change + an outbox row in one transaction. Outbox rows hold the *operation* (op, resource, record_id, payload, created_at), so deletes are first-class (the row persists after the record is gone). Survives relaunch; each row maps to one idempotent POST / LWW PATCH / hard DELETE on the relay.
- **Durable undo buffer** (D3): deletions enter an `undo_buffer` table (full serialized snapshots) + remove the records in one transaction; a buffered deletion stays restorable until the app restarts — no wall-clock window. No outbox row is created while a deletion is in the buffer. A cold launch commits whatever is still buffered (never while the process is alive); no background timer. Survives suspension and backgrounding. Supersession (U7): only the most recent buffered deletion is restorable; older ones stay buffered until undone or the app restarts. Entry and category deletions share the unified editor-Delete + system Undo confirmation grammar (`unify-catalog-deletion`).
- **Running timer state** (D8): a `timer_state` singleton row in GRDB (`activity_text`, `category_ids`, `started_at`, `status`); `TimerService` reads/writes it, widgets and Controls read it to render. The running timer survives app crashes. The name is locked while running; the ordered tag selector stays live and rewrites the draft snapshot.
- **Entry provenance** (D10): entries carry `source` (enum: `manual`, `widget`, `siri`, `control`, `screentime`, `garmin`, `calendar`, `healthkit`; default `manual`) and nullable `source_ref` (external id). `UNIQUE(user_id, source, source_ref)` for non-null `source_ref` prevents duplicate imports (server-enforced). Non-`manual` sources show a localized "via <Source>" label appended to entry-row captions in the History list and the entry form (`EntryProvenance.viaText`); `manual` shows nothing. There is no entry-detail surface.

### Sync plane

**`SyncController`** (D6): `@MainActor`, long-lived, session-gated — `activate()` on `.signedIn`, `deactivate()` on `.signedOut`; observes `SessionStore` and `Connectivity`. Wired in `AppContainer` and `RootView`. Triggers: foreground, connectivity restored (`.satisfied`), manual "Sync now", History pull-to-refresh (populated list only, sync-only). A trigger arriving mid-cycle joins the in-flight cycle instead of forking (`syncNow` awaits it; `trigger()` early-returns). **Same-account guard**: the controller records the bound `userId` at activation and refuses/skips cycles on account mismatch — it never pushes one account's outbox under another account's token; sync mechanics within one account are unchanged.

- **First-sync is pull-first** (D4): full pull + server-wins merge, then drain the outbox.
- Delta pulls use `?modified_since=` (per-resource cursor advanced to max `updated_at` received).
- Conflicts resolve **LWW on `updated_at`** (D5): on pull, apply only if `server.updated_at > local.updated_at`; on push, 409 `conflict` → adopt server version (keep-latest) and clear the outbox row. 409 `category_exists` → re-map local references to the winning id. 404 on DELETE → treat as success. Conflict recovery never synthesizes record content: a winner-fetch failure rethrows and keeps the outbox row queued (a stub named with an id would be LWW-immortal).
- Pull-merge and conflict adoption are **delete-wins**: a server record the user deleted locally — buffered in the undo buffer or committed with a pending outbox DELETE (`LocalStore.isLocallyDeleted`) — is skipped, never resurrected; the queued DELETE converges the relay on drain. Undo or a successful drain lifts the exclusion.
- Deletes propagate **cross-device via tombstones**: every relay hard delete records `(resource, record_id, deleted_at)` (`GET /api/v1/deletions?deleted_since=`, `deletions` cursor); each cycle applies tombstones before draining (no outbox row, stale pending create/update rows dropped, pending DELETE rows kept for 404-as-success). Pushes for tombstone-less relay-missing records resurrect from local data and retry once (never silently dropped); updates for locally-missing records drop pre-push; a `not_found` deletions fetch skips the step for pre-tombstone relays. A clean local row newer than the tombstone is a recreation that won (R1). Stopping a timer whose draft references categories deleted elsewhere prunes the unknown ids and keeps the remainder.
- Pull resolves same-name/different-id category collisions by newer-owns-the-name (adopt via identity remap, else skip + heal on push); entry merges adopt-or-remap relay-known-but-locally-missing category ids (same-name local rival remap is local-only and never enqueued; otherwise the snapshot row is merged) and prune only snapshot-unknown or locally-deleted ids; a tie/older pull whose local category set strictly supersets the server set enqueues a truncation-safe healing update (join-set fork heal). The drain ensures referenced categories exist on the relay before each entry push (create missing local rows first; `category_exists` 409 remaps), so the 422 prune-and-retry heal is a last resort for dangling/delete-wins ids only. Dangling category references drop with a log. Seeding skips present names instead of failing the set.
- Outbox drain is idempotent (one HTTP call per row, `category` rows before `entry` rows, `created_at, id` within each resource). Entry pushes receiving `validation_error` on `category_ids` fetch relay categories, prune unknown ids keeping the remainder, rewrite the outbox payload, retry once, and fail loudly if nothing is pruned or the retry fails.
- Exposes `@Published status` ("Last synced" / "Syncing…" / error) + manual "Sync now" in Profile, visible only when signed in. Views observe `SyncController` directly (nested reads through `AppContainer` never invalidate); relay dates decode as RFC 3339 via wire DTOs, never the local `Double`-timestamp Codable.
- Sign-out keeps every account file (Keychain/cache/session cleared, DBs untouched, dirty outbox stays in the dormant file, a running timer resumes when the account returns); an explicit per-account "Erase local data" deletes only the **active** account file.

### Incomplete / deferred (per OpenSpec tasks and current code)

Do not claim these are done. The following remain open (leftovers live in `docs/history-roadmap.md` and archived change tasks):

- **App-wide Undo UI**: entry, activity, and category deletions all undo through the DEFAULT system Undo confirmation (shake → prompt → confirm restores the newest eligible deletion; `unify-catalog-deletion` removed the Manage Categories `UndoToast`, its swipe-to-delete, and the `UndoToast` component). Remaining deferred: supersession UX polish and the bulk-delete cap (local-first tasks 3.3–3.6).
- **Enable Sync presentation** — **removed** by `account-bound-local-data`: sign-in is the launch gate (`RootView` renders the auth flow full-screen when signed out), so the optional-voice "Enable Sync" sheet/row, the History signed-out banner branch, and `EnableSyncPresenter`/`EnableSyncSheet` no longer exist. The global `OfflineBanner` is removed (`fix-offline-banner-duplication`): offline signed-in keeps working, surfaced via the History pull-to-refresh offline notice and the Profile sync status.
- **Activity deletion UI** — removed with the activities layer (`remove-activities-layer`): there is no activity editor, detail sheet, or cascade. Entry deletion lives on the entry form (single confirm naming the text) with system-prompt undo.
- **Lock-screen Controls** (iOS 18 WidgetKit `ControlWidget` toggle via an `alwaysAllowed` AppIntent): the ControlWidget itself is still deferred (a widget extension target now exists for Live Activities — `LifioLiveActivities` in `ios/TimeOfLife/project.yml` — but it hosts no Control); the account-bound storage/provenance foundations are in place — Controls will read the **active account file** post-first-unlock (device-unlock is the authorization; no auth of their own).
- **Device quota + picker (#46) — pre-release blocker**: the device-sessions foundation is shipped (stable `X-Device-Id` Keychain UUID, per-device refresh families, TTL enforcement, per-device reuse-detection/logout revocation), but **device quota counting and the 6th-device picker are not implemented** (`device_limit` intentionally absent from the API — deferred to issue #46) and must land before release. Reinstall with a surviving Keychain UUID reuses the old device slot; the picker is the escape hatch. A multi-session **device switcher** is future work by design: one active session per device, every account switch re-authenticates, and no device-management UI (`device_name`/`last_seen_at` heartbeat) exists.
- **Track editing affordance** — removed during refine-track-recents; its placement is deferred to a later change (the editor sheet machinery remains in TrackViewModel).
- **Sign in with Apple follow-ups** — nonce replay defense (`harden-apple-signin` change planned), account-deletion token revocation via Apple `/auth/revoke` (App Store 5.1.1v, needs `.p8` + `APPLE_TEAM_ID`/`APPLE_KEY_ID`), Apple credential-state/revocation observation, identity merging between email-OTP and Apple accounts (kept separate by design), and localized copy for Apple-path server error codes (`invalid_apple_token`, `apple_not_configured` — currently falling back to the generic "Something went wrong" banner). The enablement work itself is **complete and production-verified** (`enable-sign-in-with-apple`): entitlement + Release signing (team `7923U48U87`) + portal App ID + `APPLE_CLIENT_ID` on prod; real-device smoke passed 2026-09-24 (sheet → token → JWKS verify → upsert → signed-in + sync). Also fixed en route: the Postgres conflict target for the partial `apple_subject` index (SQLSTATE 42P10), covered by `TestPostgres_UpsertUserByAppleSubject` parity test; prod needs `TRUSTED_PROXIES` set or all clients share one rate-limit bucket behind Nginx.
- **Kafka** — deferred (S1 names it but auth MVP doesn't need an MQ). **Rate-limit store** is in-memory; swap for Redis before multi-instance deploy.
- **SwiftUI snapshot / on-device keychain tests** — manual smoke checklist in `README.md`.

## OpenSpec routing

The repo is **spec-driven** (`openspec/config.yaml`, `schema: spec-driven`). Baseline specs, active deltas, and archives play different roles — know which one you are reading:

- **Baseline specs** (`openspec/specs/<capability>/spec.md`): the current merged contract, in force. Twenty-four baselines exist today: `app-icon`, `app-identity`, `app-shell`, `account-bound-store`, `apple-signin`, `device-sessions`, `category-management`, `editor-sheet-ux`, `entry-editor`, `entry-provenance`, `history-entry-list`, `insights-breakdown`, `live-activities`, `local-first-store`, `lock-screen-controls`, `manual-entry`, `name-picker`, `release-versioning`, `sync-client`, `timer-capture-experience`, plus `backend-database`, `email-otp-auth`, `observability`, and `relay-cors`. They were synced from archived changes. **Rule: never edit a baseline spec directly** — behavior changes go through a change with a delta spec.
- **Active deltas** (`openspec/changes/<change>/specs/<capability>/spec.md`): proposed ADDED/MODIFIED requirements not yet in the baseline. `bump-ios-deployment-to-18` is archived and folded into the `lock-screen-controls` baseline (iOS 18 floor, no availability guards, Control target deferred). Active changes live under `openspec/changes/` — check `openspec list` before starting new behavior work. `history-entry-notes-icon` is archived (`2026-10-10-history-entry-notes-icon`) and folded into the `history-entry-list` baseline (notes indicator on rows with non-empty notes); `reduce-codebase-complexity` is archived (`2026-10-02-reduce-codebase-complexity`) and folded into the baselines (wording-only docs-contract sync, no behavior change); check `openspec list` before starting new behavior work. `account-bound-local-data` is archived and folded into the baselines (mandatory sign-in gate, per-account DB files, per-device sessions, same-account sync guard), adding the `account-bound-store` and `device-sessions` baselines. `fix-history-sync-refresh` (cycle-exit invalidate/reload), `fix-category-sync-loss` (wire `categories` decode, ensure-before-push, adopt-or-remap, tie fork healing both directions) and `propagate-buffered-deletes` (push-then-commit: buffered deletions push before drain, in-flight undo guard) are archived and folded into the `sync-client` and `local-first-store` baselines. `replace-gate-brand-mark` is archived (`2026-10-10-replace-gate-brand-mark`) and folded into the `app-identity` and `app-shell` baselines (gate `^▬` brand mark on the restoring splash + Welcome). `move-ios-checks-to-xcode-cloud` is archived (`2026-10-12-move-ios-checks-to-xcode-cloud`) as tooling-only (`skip_specs`, no baseline fold): iOS PR checks moved to Xcode Cloud, `ios.yml` release-verify-only; operational round closed 2026-10-14 (13/13) in `2026-10-14-move-ios-checks-to-xcode-cloud`. `observability-stage-0` is archived (`2026-10-14-observability-stage-0`) with the new `observability` baseline (off-box uptime watch, bounded VM logs, quiet `/health`, Sentry backend + iOS with dSYM upload from Cloud archives). `fix-sync-cursor-rebaseline` is archived (`2026-10-14-fix-sync-cursor-rebaseline`) and folded into the `sync-client` baseline (poisoned-cursor one-time re-baseline with persisted flag). `fix-terminated-stop-saved-face` is archived (`2026-10-14-fix-terminated-stop-saved-face`) and folded into the `live-activities` baseline (Link-based open-and-stop for Island/banner Stop; dimmed-inert presentation kept). `migrate-db-to-supabase-free` is archived (`2026-10-14-migrate-db-to-supabase-free`) with the new `backend-database` baseline (remote pooler topology, backup floor, quota guard, validation gates, rollback window). `steady-track-launch` is archived (`2026-10-14-steady-track-launch`) and folded into the `app-shell` and `timer-capture-experience` baselines (optimistic instant Track launch: restore signs in from cache and clears the hold before `/me`, gate preloads bind+seed+snapshot before mounting, no splash/skeleton/spinner/fade, single-commit publishes, no-op reload suppression, `elapsed` seeds synchronously). `fix-entry-date-picker-taps` is archived (`2026-10-15-fix-entry-date-picker-taps`) and folded into the `entry-editor` and `manual-entry` baselines (calendar day-cell tap-away carve-out, month browsing persistence with no snap-back, no-flash picker expansion; shell ticker publishes the running draft on real change only). `fix-history-sticky-headers` is archived (`2026-10-16-fix-history-sticky-headers`) and folded into the `history-entry-list` baseline (static two-line day headers in native `List(.plain)` with accepted pinned bleed, opaque tab bar on iOS 18 / glass on iOS 26+, tight header tops, simplified `SectionHeader`). `time-picker-duration-floor` is archived (`2026-10-17-time-picker-duration-floor`) and folded into the `manual-entry` and `entry-editor` baselines (always-preserve Start moves in both directions, 1-minute End floor enforced in the pickers, untouched-draft display mapping with touch-to-adopt minute normalization, grandfathered sub-minute saves).
- **Archives** (`openspec/changes/archive/<change>/`): completed changes. Their delta specs were folded into the baselines by `openspec archive`; the folder is history. See `openspec/changes/archive/` for the full list.
- **Routing**: before touching a behavior, check the active change's tasks and delta specs (`openspec validate --all`, `openspec list`, `openspec status --change <change>`). When implementing, mark tasks in the relevant `tasks.md`. Archive each change only after its own tasks and verification are complete, then update this context.

## Repo layout

```
backend/                 Go backend (chi + pgx/Postgres; sqlite for tests) — identity + sync relay
  api/openapi.yaml      OpenAPI 3.0 spec (S10 — authoritative API contract)
  cmd/server/main.go     entrypoint (run() int pattern; os.Exit owns lifecycle)
  internal/
    auth/                token service (JWT + rotated refresh) + otp service
    handlers/            HTTP handlers (auth + activity catalog/entries)
    server/              chi router + middleware (recoverer, logger, jwtAuth)
    db/                  Store interface + postgres + sqlite impls
    migrations/          embedded SQL migrations (go:embed)
    email/               Sender (console + AWS SES) + localized bodies
    ratelimit/           in-memory token bucket
    config/              env config (fail-fast JWT_SECRET ≥32 bytes)
  Dockerfile, docker-compose.yml, docker-compose.prod.yml, nginx/, deploy.sh, Makefile
ios/TimeOfLife/          SwiftUI app (iOS 18+), XcodeGen-managed (project.yml)
  TimeOfLife/Features/Auth/        passwordless flow: Welcome → EmailEntry → OtpEntry; AppleSignIn
  TimeOfLife/Features/AppShell/    three-tab shell (Track/History/Insights) + Profile destination
  TimeOfLife/Features/TimeTracking/  Track state machine, plain-text capture + Recents, numeric/compact timers, TimerService
  TimeOfLife/Features/Catalog/     Models/CatalogModels.swift, ActivityName.swift (exact-text rule), CategoryName.swift, Repositories/RemoteCatalogRepository.swift; Views/ViewModels are categories-only (ManageCategories, CategoryEditor)
  TimeOfLife/Features/Sync/        SyncController.swift (outbox drain + delta pull)
  TimeOfLife/Core/Storage/         LocalStore.swift (GRDB), UndoBufferStore.swift, SessionCache.swift
  TimeOfLife/Core/                 networking, keychain, reachability, theme, navigation, DI, design components
  TimeOfLife/Localization/         en + ru Localizable.strings + L10n enum
  project.yml              XcodeGen spec — edit this, then `xcodegen generate`; never hand-edit the .pbxproj
.github/workflows/       CI: backend.yml (PR checks) + release.yml (version bump) + Xcode Cloud (iOS PR checks)
.golangci.yml            Go linters (run from backend/)
ios/TimeOfLife/.swiftlint.yml   Swift linters (run from ios/TimeOfLife/)
docs/                    Durable repo documentation (this file, docs/ci.md, docs/ios-test-loop.md)
openspec/                Spec-driven change workflow (see openspec/README.md)
```

Note: `RemoteCatalogRepository` exists only as the SyncController's relay client; the catalog UI reads the local store.

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
cd ios/TimeOfLife
xcodegen generate
swiftlint lint --strict         # linters (S6); --fix autocorrects
xcodebuild -scheme TimeOfLife \
  -destination 'generic/platform=iOS Simulator' build
```

`project.yml` sets warnings-as-errors on the app and test targets. Do not pass those settings globally on the command line because GRDB intentionally compiles with `-suppress-warnings`.

Agents running the iOS suite: follow `docs/ios-test-loop.md` (booted-sim-by-ID destination, `-only-testing` filters, one `xcodebuild` at a time, log-file polling instead of `| tail`).

## API contract (`/api/v1`)

[`backend/api/openapi.yaml`](../backend/api/openapi.yaml) is the sole authoritative endpoint and schema reference (OpenAPI 3.0, S10). Do not duplicate its endpoint table in project documentation.

Durable invariants: the error envelope is `{ "error": { "code", "message", "details": {} } }`; category and entry routes are Bearer-protected; IDs are client-generated UUID v7; creates are idempotent on ID; updates use last-write-wins on `updated_at`; hard deletes leave tombstones listed at `GET /deletions?deleted_since=`; default-category seeding is client-side; recents group committed entries by exact text; delta pulls use `modified_since`; entry provenance uses `source` and nullable `source_ref`. If an endpoint changes, update the server, iOS relay client, OpenAPI document, and contract tests together.

## Auth model (passwordless, per-device sessions)

Enter email → `otp/request` (always 202, account auto-created unverified) → server emails a 6-digit code → `otp/verify` → marks verified + issues JWT access (15 min) + rotated refresh. Sign in with Apple is the alternate path. The OTP proves email ownership — there is no separate "verify email" step and no password anywhere (R1). OTP codes and refresh tokens are stored only as **SHA-256 hashes**; tokens live in the iOS **Keychain**. `otp/request` and `otp/verify` are rate-limited per IP+email. The client IP for rate limiting is resolved by `Handler.clientIP`, which honours `X-Forwarded-For`/`X-Real-IP` **only** when the direct TCP peer is in `TRUSTED_PROXIES` (comma-separated IPs/CIDRs; empty = trust nobody, the safe default that prevents rate-limit bypass via spoofed headers). The email body puts the 6-digit code on its own line for iOS `.oneTimeCode` autofill (U5); the template is configurable via `OTP_EMAIL_TEMPLATE` and may need empirical tuning.

Auth is **the launch gate** (not optional): `RootView` gates on `SessionStore` — an unresolved restore holds a blank background (never the auth flow), signed-out renders the auth flow full-screen, signed-in renders the app shell only after the account file is bound, buffered deletions committed, starter categories seeded, and the first Track snapshot loaded (optimistic launch: restore signs in from cache and clears the hold before `/me` returns, so the first paint is complete with no splash, skeleton, or spinner; the first-sync pull stays background and Track converges via its sync-exit reload, mirroring History/Insights). Sessions are **per-device**: the client mints a UUID v4 into the Keychain and sends it as `X-Device-Id` on verify/apple/refresh/logout; every refresh row persists its `device_id`, so each device owns its own refresh family. Reuse-detection revokes only that device's family, logout revokes only the calling device's tokens (a second phone keeps its session), and the refresh TTL is enforced at the refresh handler against `created_at` (one conditional UPDATE; first-writer-wins on concurrent refreshes). A revoked, reused, or TTL-exhausted refresh **locks to the auth gate — never wipes**: local account files, outbox, and cursors are untouched, and a successful re-login reopens and resumes the account's file. Only explicit per-account Erase deletes data. The Keychain device UUID intentionally survives uninstall/Erase+logout (reinstall presents the old slot; the #46 picker is the future escape hatch). The iOS `APIClient` retries protected requests once after a 401 using the single-flight refresh path; a rejected refresh transitions `SessionStore` to the locked state (files intact). Offline or transport failures never lock or wipe — signed-in offline keeps working (no global banner; offline surfaces via the History pull notice and the Profile sync status).

## Coding standards (Requirements S5)

Keep code **minimal and standardized**, following modern best practices.
- **Backend (Go):** idiomatic Go; `gofmt`-formatted (tabs); table-free errors via the domain error types in `internal/`; `context.Context` first param; no `panic` in request paths; `log/slog` only (never log codes/tokens/bodies/emails at info). No new deps without strong justification (S1: mainstream).
- **iOS (Swift):** SwiftUI, MVVM + Repository, all dependencies injected via `AppContainer`; every layer replaceable in tests; `@MainActor` on view models; views use only `Theme` semantic colors (no raw `Color` literals); user-facing strings via `L10n`/`Localizable.strings` (never hard-coded); iOS 18+ with no availability guards for older OS versions.
- **Tests (S3):** logic layer ~100% covered. Backend `go test` (SQLite, no Docker); iOS SwiftTesting. Don't leave failing tests; don't lower coverage by deleting tests.
- **Security (R1):** never persist/log passwords, OTP codes, or tokens in plaintext. Secrets from env. Keep user-enumeration closed (`otp/request` always 202).
- **Locales (U4):** every new user-facing string must be added to **both** `en.lproj` and `ru.lproj`, and to the `L10n` enum's `allCases` in `LocalizationTests` if enumerated.

### External docs first (ctx7)

Mandatory before implementing every feature/bugfix: research the topic, applicable HIG guidelines, Apple documentation, and best practices. Training data is stale by default — fetch, don't guess.

- **Bundle (max 5 commands, no secrets in queries):** 1× topic/problem-space query always; + 1× HIG query when UI is involved (known ID `/websites/developer_apple_design_human-interface-guidelines`); + 1× Apple API query with SDK pin when an Apple SDK is involved (known IDs `/websites/developer_apple_swiftui`, `/websites/developer_apple_activitykit`; pin pattern "iOS 18 SDK via Xcode 16+"); + 1× best-practice/setup query when an external lib/service is involved.
- **Waiver (not silence):** waive an inapplicable bundle item only with a one-line reason + evidence (e.g. "HIG N/A — `backend/`-only diff, no UI"). Pure business logic or repo-internal refactoring waives the external/API items but keeps the topic query when one applies.
- **Procedure:**
  1. `npx ctx7@latest library <name> "<what to look up>"` — use the official name ("Next.js", not "nextjs"); pick the ID (`/org/project`) by exact name match, description relevance, snippet count, source reputation, benchmark score.
  2. `npx ctx7@latest docs <libraryId> "<single concept>"` — one concept per query; separate `docs` call per distinct concept. For version-specific work use `/org/project/version` from the `library` output. Re-confirm at apply time ("nothing changed since explore").
  3. Design/implement from the fetched docs only.
- **Cite:** proposal/design/tasks state the ctx7 library IDs + queries + pins used (e.g. "GRDB `/groue/GRDB.swift` — `transaction observation`"; "HIG `/websites/developer_apple_design_human-interface-guidelines` — `tab bar navigation guidance`") or the waiver reasons.
- **Quota failure:** if a command fails with a quota error, tell the user to run `npx ctx7@latest login` or set `CONTEXT7_API_KEY` — never silently fall back to training data.

## Per-iteration revising process (Requirements S5)

On every iteration (feature/fix PR) the author MUST:
1. Start from a fresh base and stay isolated: work in a separated git worktree (`timeOfLife.wt/<change-name>`, one branch per worktree; main checkout stays clean); `git fetch origin` + rebase onto `origin/main` before implementing and again before opening the PR (re-run affected linters/tests after each rebase; `push --force-with-lease`; never `merge main`). Worktrees do not lift the one-`xcodebuild` / one-simulator / single-writer-file serialization.
2. Complete the ctx7 research bundle before coding (topic + applicable HIG + Apple API + best practice, max 5 — see "External docs first (ctx7)"), with cites or waiver reasons recorded; re-confirm at apply time.
3. Run both linters and fix every finding: `golangci-lint run` (backend), `swiftlint lint --strict` (iOS); run the iOS build and inspect/fix every `xcodebuild` warning (app/test warnings are errors through `project.yml`); `gofmt -l .` must be empty.
4. Run both test suites green (`go test ./...`; `xcodebuild test -scheme TimeOfLife -destination '<available simulator>'`).
5. Re-read the relevant `Requirements/FURPS/*.md` rows and confirm the change aligns; correct the requirements doc if rows conflict (see the passwordless correction as precedent).
6. Update `AGENTS.md`, `README.md`, `docs/project-context.md`, the relevant `Design/*.md` files, and [`backend/api/openapi.yaml`](../backend/api/openapi.yaml) if architecture/contract/run steps or visual design changed. The OpenAPI spec is the authoritative API contract — keep it in sync with the handlers. Advance or archive the active OpenSpec change as appropriate.
7. Prefer reusing existing utilities/patterns over new code; remove dead code.

### Reproduce before fixing, verify after (bugfix rule)

No bugfix implementation without a recorded reproduction on the current tree:
1. **Reproduce first** — re-run the issue's repro steps (or write your own) and record the evidence (screen recording, log excerpt, or failing test). Precedent: the repros in issues #101/#67 outlived their merged fixes — merged code is not proof.
2. **Research in parallel** — complete the ctx7 research bundle (see "External docs first (ctx7)") with cites or waiver reasons. Repro and research jointly gate implementation: an unreproducible bug stops the change even with perfect research, and a reproduced bug without research may not implement.
3. **Implement only after the repro confirms the bug.** If it cannot be reproduced, stop and report instead of guessing.
3. **Verify after** — re-run the identical repro on the fixed tree and record the evidence with the change/PR. Where automatable, encode the repro as a regression test (fails before, passes after).
4. Merges with "Fixes #" auto-close issues — reopen the issue if the bug survives the fix.

## CI (Requirements S6)

`.github/workflows/backend.yml` (Go: gofmt, go vet, golangci-lint, test + coverage) runs on pull requests that touch `backend/` and on similarly path-filtered pushes to `main`; iOS verification (xcodegen, SwiftLint, warning-as-error xcodebuild build, test) runs on Xcode Cloud's `iOS PR Checks` workflow on PRs touching `ios/**` (`.github/workflows/ios.yml` keeps no automatic triggers — it runs only as release verification via `workflow_call` from `release.yml`; the post-bump `verify` job runs it on the pushed head, and the tag-triggered Cloud Test→Archive uploads to TestFlight — crash symbolication is preserved — `ci_post_xcodebuild.sh` uploads the signed archive's dSYMs to the Sentry staging + release projects from Xcode Cloud shared secret env vars, all optional with graceful skip). Each is a **mandatory** PR check when triggered — a PR is not mergeable until the applicable checks are green. `.github/workflows/openspec.yml` additionally enforces `openspec validate --all --strict` on every PR. An **advisory** AI review (`ai-review.yml`) comments on every PR but never blocks — the two-stage review process (AI stage 1 → human stage 2) is defined in [`docs/review-process.md`](review-process.md). See `docs/ci.md` for the full pipeline guide.

## Deployment (S4)

The backend is deployed to a **Google Cloud Compute Engine VM** (`timeoflife-backend`, us-east1-b). The production stack runs via Docker Compose:

- **PostgreSQL 15** — database
- **Backend** — Go API server (container image from GHCR)
- **Nginx** — reverse proxy with SSL termination (Let's Encrypt)

**CI/CD pipeline**: on every push to `main` that touches `backend/`, CI runs lint + test, builds the Docker image and pushes to `ghcr.io/antonkosenkopro/timeoflife/backend:latest`, then SSHs into the VM, pulls the new image, and restarts the backend container.

**Manual deploy**: dispatch the `backend` workflow in GitHub Actions and select the target environment.

**Production URL**: `https://timeoflife-api.antonkosenko.pro`.

**Database topology** (remote since 2026-10-13, `migrate-db-to-supabase-free`): the relay's system of record is Supabase Postgres 17 (N. Virginia) reached via the session-mode pooler (`aws-0-us-east-1.pooler.supabase.com:5432`, `sslmode=require`, pool capped at 5). `DATABASE_URL` selects the database and is rendered into the VM `.env` from the GitHub `stage`-env secret on every deploy — empty keeps VM-local Postgres (rollback is config-only). The orphan VM `pgdata` volume is retained, never mounted. **Never reboot casually**: the original GCE `startup-script` metadata rewrote deploy-managed files with placeholders on every boot (found + neutered 2026-10-14 after a reboot clobbered `.env`/compose/nginx conf); post-boot, always re-run the `backend` workflow and verify `/health`.

**Backup floor**: weekly `pg_dump` (Sunday 03:00 UTC VM cron) to `gs://lifio-supabase-backups` (30-day retention, sha256 per artifact); quota guard runs Sunday 04:00 UTC (`supabase-size-check.sh`, alert line 350 MB of the 500 MB read-only tripwire). Cron-failure notification is still unwired (no MTA on the VM) — follow-up: ping a dead-man's-switch check on failure. **Paid-tier trigger**: armed, not tripped (11 MB measured 2026-10-14); upgrade at sustained >70% or at launch.

**Required GitHub Actions secrets**: `VM_HOST` (VM external IP), `VM_USER` (SSH user `deploy`), `VM_SSH_KEY` (SSH private key for deployment).

**iOS production config**: `API_BASE_URL` is per build configuration, injected into `Info.plist` via xcconfig: `Debug` → `Config.Debug.xcconfig` → `http://127.0.0.1:8080` (local backend; ATS allows plain HTTP to `127.0.0.1` only); `Release` → `Config.Release.xcconfig` → `https://timeoflife-api.antonkosenko.pro` (production, HTTPS — no ATS exception needed). `AppConfig` reads it at runtime and falls back to the dev URL if missing/malformed. Unit tests run under `Debug`, so they keep asserting `127.0.0.1:8080`.

Code signing is **split per configuration** in `project.yml`: Debug (base) stays unsigned (`DEVELOPMENT_TEAM: ""`, `CODE_SIGNING_REQUIRED: NO`) so simulator/CI builds need no Apple Developer account; Release carries `DEVELOPMENT_TEAM: 7923U48U87`, `CODE_SIGN_IDENTITY: Apple Development`, `CODE_SIGNING_REQUIRED: YES` — automatic signing pairs the development identity with device builds, and archives pick the distribution identity on their own (an explicit `Apple Distribution` there conflicts with automatic signing). **TestFlight/App Store distribution is the next step**: create the App Store Connect app record, archive the Release configuration, and upload (fastlane/App Store Connect API automation deferred). Releases are cut with the manual `release` workflow (`.github/workflows/release.yml`: `workflow_dispatch` with a `version` X.Y.Z input — validates strictly-greater-than-current on `main`, bumps the `project.yml` marketing version, auto-increments the build by +1, commits, and pushes an annotated `vX.Y.Z` tag). The tag-triggered Cloud archive doubles as the symbolication source: `ci_post_xcodebuild.sh` uploads its dSYMs to the Sentry staging + release projects (shared secret env vars in App Store Connect; skips gracefully when absent). The bump covers **every target in lockstep** (app + each extension's `CFBundleShortVersionString`/`CFBundleVersion` must be unanimous or the workflow refuses; every Release `Info.plist` is mirrored, Debug plists stay pinned) — **when adding an Xcode target, wire it into `release.yml` (`RELEASE_PLISTS` + `git add`) and the Cloud `iOS PR Checks` workflow's Test-action scheme coverage in the same PR** (the `LifioLiveActivities` appex broke the `0.2.1` release by adding duplicate version keys the single-target workflow rejected); full checklist: `docs/ci.md` → "New-target checklist". Profile shows the built commit in a trailing version row (`1.0.0 (a1b2c3d)`; `1.0.0 (a1b2c3d) • Debug` on Debug builds) so testers can report the exact commit. The integer build (`CFBundleVersion` / `CURRENT_PROJECT_VERSION`, auto-+1 per release) survives solely as the App Store Connect upload identifier and is no longer displayed. Account deletion (App Store 5.1.1(v)) and Apple token revocation are still open — see "Incomplete / deferred".

## Observability (Stage 0)

Solo-dev, anti-fatigue: two lanes. **Interrupt** (Telegram, sound on): `/health` failing 3 consecutive off-box checks, a Sentry NEW issue type, Supabase DB size crossing ~350 MB, VM disk > 80%. **Digest** (morning Telegram): deploy results, 70% tripwire crossings, daily uptime % / Sentry issue count / DB size / quota consumption, weekly quota trend. **Ratchet**: anything paging more than 2×/month gets demoted from interrupt to digest.

### Tripwires (70% alert → 90% shed load → 100% migrate)

| Tier | 70% alert | 90% shed-load |
|---|---|---|
| Sentry events/mo | Telegram ping | errors-only, drop breadcrumbs/perf |
| Grafana series (10k, Stage 1) | Telegram ping | cut `operation`, coarsen status |
| Grafana logs GB (Stage 1) | Telegram ping | retention 30→7d, drop DEBUG |
| Supabase 500 MB | already specced (see below) | already specced (see below) |

Supabase convention (from `migrate-db-to-supabase-free`, unchanged): Free flips the project read-only above 500 MB database size — the guard alerts at ~350 MB (70%) via `backend/scripts/supabase-size-check.sh`, and the deployment is not repointed above the line without the paid-tier upgrade first.

All 70% alerts route to Telegram. The Telegram channel/bot itself is a separate pending task (observability Stage 0 task 1.2) — routing targets it once it exists.

### Daily digest

Uptime % (off-box `/health`), Sentry issue count (new + total), DB size in MB, quota consumption per tier; weekly quota trend on top.

## Pre-release policy

The app is unreleased; there is no on-disk data in the wild. **No backward compatibility / migration for local on-disk formats is needed before release.** Do not add legacy-decode branches, `legacy*` fields, or `migrateIfNeeded` paths to local stores. On-disk schema changes are applied by editing the `Codable` shape in place; existing test fixtures and dev devices simply start fresh. Revisit this policy once a build ships to TestFlight or any external tester — the first `vX.Y.Z` release tag marks that point.

## Sign in with Apple (F2)

- iOS: `Features/AppleSignIn/` — `AppleSignInService` wraps an injectable `AppleAuthorizationProviding` (real `ASAuthorizationAppleIDProvider`-backed impl + a fake in tests). The `AppleSignInButton` (UIControl wrapper) lives on `WelcomeView` and triggers `WelcomeViewModel.signInWithApple()`, which obtains Apple's identity token and posts it via `AuthService.signInWithApple` → `POST /api/v1/auth/apple`. Success reuses `AuthService.persist` → `SessionStore` flips → the app shell (Track) appears behind the mandatory gate (no separate navigation wiring).
- Backend: `POST /api/v1/auth/apple` (`internal/handlers/auth.go` `AppleSignIn`) verifies Apple's RS256 identity-token JWT via `internal/apple` (JWKS fetched with `github.com/MicahParks/keyfunc/v3`, pinned `RS256`, `iss`/`aud`=Bundle ID/`exp`), upserts a user keyed by Apple's `sub` (`Store.UpsertUserByAppleSubject`, migration `002_apple.sql` adds `users.apple_subject`), and issues the same token pair as OTP verify.
- **Config-gated**: the route is always registered. When `APPLE_CLIENT_ID` is absent, the handler returns `apple_not_configured` (503); when configured, the Bundle ID is validated against the identity token's `aud`. `APPLE_JWKS_URL` defaults to `https://appleid.apple.com/auth/keys`.
- **Enabled for distribution**: the `com.apple.developer.applesignin` entitlement is in `TimeOfLife.entitlements`; Release signs with team `7923U48U87` (`Apple Development`, signing required) while Debug stays unsigned for simulator/CI; the portal App ID `com.antonkosenko.timeoflifeapp` has Sign In with Apple enabled; production sets `APPLE_CLIENT_ID=com.antonkosenko.timeoflifeapp`. The full chain (real Apple sheet, live JWKS fetch, Private Relay email) is verified by the **manual smoke checklist** in `README.md` — unit tests fake the Apple authorization and cannot cover it.

## Decisions log (precedents to respect)

- Backend language is **Go** (+3); mobile is **Swift** (+4). Do not reintroduce Swift/Vapor in the backend.
- Auth is **passwordless** — do not reintroduce passwords.
- Tests use **SQLite in-memory** so they run without Docker (S4 local + cloud).
- The Xcode project is **XcodeGen-managed** — edit `ios/TimeOfLife/project.yml`, then `xcodegen generate`; do not hand-edit the `.pbxproj`. File-based `Info.plist`s are **regenerated from `info.properties` on every generate** — declare plist keys in `project.yml`, never by hand-editing the plist (hand-added keys are wiped); the unmanaged `Info-Debug.plist` is the only hand-maintained exception.
- **Sign in with Apple** (F2) verifies Apple's RS256 identity-token JWT with `github.com/MicahParks/keyfunc/v3` (JWKS) on the backend and is **config-gated** by `APPLE_CLIENT_ID` (Bundle ID); it reuses the OTP session machinery rather than a separate token type. The capability is enabled: entitlement + Release signing (team `7923U48U87`) + portal App ID + production `APPLE_CLIENT_ID`; account-deletion revocation is deferred (App Store 5.1.1v).
