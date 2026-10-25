## Context

See proposal.md (Why) for motivation. Starting points: Lifio's proven chassis — GRDB `LocalStore` as the single mutation chokepoint with transactional outbox + durable undo buffer + per-resource sync cursors (see `local-first-store`, `sync-client` baselines, `docs/project-context.md` → Data/Sync planes); passwordless auth + per-device sessions (`email-otp-auth`, `apple-signin`, `device-sessions`); OpenAPI as authoritative contract (S10). Hard constraints inherited: no passwords/plaintext secrets (R1), Theme-only colors, en+ru strings + L10n (U4), XcodeGen-managed project, no on-disk backward compat (pre-release). The target is a **new repo** (`AntonKosenkoPro/shunik`): Lifio runtime code and baselines are untouched by this change; artifacts here are portable and migrate at fork time.

## Goals / Non-Goals

**Goals:** portable v1 spine (domain + sharing + blob + units + reminders), fork mechanics (clone-then-strip with verbatim/re-scope/drop piles), and agent-scaffolding migration that an agent can execute in the Shunik repo without re-deciding anything settled in explore.

**Non-Goals:** screen-by-screen UI, endpoint-by-endpoint API authoring (that is Shunik-repo apply work against these specs), calendar/analytics/vet-report builds, curated drug content, field-level merge.

## Decisions

### D1. Base + detail events (not one table, not N tables)

Base `event_base(pet_id NOT NULL immutable, kind, occurred_at, next_due_at, title, updated_at, updated_by)` + kind tables (`vacc_detail`, `grooming_detail`, `weight_point`, `med_course → intakes[]`). Alternative considered: single `events` table with JSON payload — rejected (medication edit semantics and weight range scans degrade; conditional validation spreads). Alternative: fully separate tables per kind — rejected (timeline/reminder queries fan out; sync needs N resource pipelines). Base gives one timeline query, one reminder feed, one tombstone stream; details give typed validation and independent evolution. Intake rows are children of `med_course` (never base rows): past intakes immutable, edits regenerate future pendings only (mirrors Lifio's "history never mutates" rule).

### D2. Household scoping by mechanical rescope

New tables scope `household_id`; Lifio's `WHERE user_id = ?` becomes `WHERE household_id = ?` plus a membership check at the edge (`households`, `household_members`, `household_invites`). Alternative: per-pet ACL — rejected for v1 (per-resource authz on every handler; deferred with per-pet roles). One user → one household; local file `shunik_<householdId>.db` after household resolution post-sign-in (gate ordering: signed in → resolve/create household → open store → shell). Sync order: pets before dependents (mirrors Lifio's categories-before-entries ensure-before-push). `document_pets` links need no name-collision healing (unlike Lifio's category same-name forks): ID links only.

### D3. Blobs outside sync, metadata inside

Presigned PUT (upload) → confirm → presigned GET (lazy, cached) against S3-compatible storage; metadata rows go through outbox + LWW + tombstones; readiness flag gates visibility; server GC for unconfirmed uploads; async blob delete on tombstone (never blocks drain). Alternative: bytes in Postgres or through outbox — rejected (outbox rows must stay small and replayable; background `URLSession` needs resumable transfers outside the sync cycle). v1 share = local file via system sheet (zero backend surface).

### D4. Reminder engine as the only scheduler

Derived stream `(due_at, pet_id, title, link)` → rolling ~14d UN window, re-top-up on launch/mark/edit/pull/timezone-change; deterministic IDs (`intake_<id>`, `due_<event_id>`) so any member device cancels what another resolved; both-buzz default, per-device mute (local `UserDefaults`, never synced). Wall-clock intakes (travel-safe), no alarms on any future calendar mirror. Snooze cut for v1 (pending sits red; revisit only via proposal review).

### D5. Canonical units with per-device lens

Integer grams stored/synced; Metric/Imperial per-device local state defaulting from `Locale.measurementSystem`; field chip filtered by system with live draft conversion; decimal pounds; epsilon on trend. Discrete dose dimensions reserved (no conversion) so future `mg/IU/tabs/drops` arrive without touching weight storage. Invariants preserved: display prefs never enter GRDB-sync or the backend (Lifio's device-local `UserDefaults` pattern, cf. `SessionCache`).

### D6. Clone-then-strip fork + clean agent scaffold

Fork preserves `git log` for auth/sync archaeology. Piles: verbatim (auth/apple/email/ratelimit/config/middleware/device-sessions, Docker/compose/nginx, CI workflows, iOS Core + Auth flow + Sync skeleton, contract-test harness); re-scoped (Store pg+sqlite, handlers, migrations fresh, openapi.yaml, LocalStore tables + FTS reservation, sync resource list, tabs); dropped (timer/Live Activities/Insights/categories/provenance-sources/archives). Agent scaffold: `AGENTS.md` rewritten for household scoping, `opencode.json` agent defs verbatim (re-point `timeOfLife.wt` → `shunik.wt`), clean `openspec init` + reinstall from `skills-lock.json` (never copy `.agents/skills` output), selected Lifio specs cited by link (commit SHA) not copied.

## Risks / Trade-offs

- [LWW with two writers] Concurrent edits to one course/intake silently drop one write → Mitigation: row-level LWW kept (v1-sufficient); `updated_by` attribution makes loss visible; past-intake immutability halves the collision surface. Field-level merge explicitly deferred.
- [64-slot UN cap] Two pets × two courses overflow naive scheduling → Mitigation: rolling window + re-top-up triggers (spec `reminder-engine`); verified against `/websites/developer_apple_usernotifications` (`UNUserNotificationCenter pending notification requests`) at Shunik apply.
- [Orphaned blobs] Client mints PUT URL, never uploads → Mitigation: `confirm` step + server GC of unconfirmed metadata (S3 library `/websites/aws_amazon_s3` resolved; presigned-flow docs re-confirmed at Shunik apply).
- [Unit round-trip jitter] lb→g→lb residue fakes trends → Mitigation: integer grams + display epsilon rule (spec `unit-system`).
- [External calendar deletion] (parked with calendar) recreated-mirror annoyance → Mitigation: already decided (user-deleted calendar = opt-out); no action in v1.
- [Shared-login temptation] Teams may ship single-account-two-phones to dodge invites → Mitigation: invite flow reuses OTP chassis (cheap), audit story documented; acceptable fallback, not the plan.
- [HIG waived] No screen specs here → Mitigation: adaptive-IA rule is structural; HIG query (`/websites/developer_apple_design_human-interface-guidelines`) lands with Shunik screen design.
- [SwiftUI Charts waived] Trend rendering API shapes → Mitigation: standard usage; re-confirm at Shunik apply ("nothing changed since explore").

## Migration Plan

In the Shunik repo (not here): clean `openspec init` → copy agent skeleton → clone-then-strip Lifio at pinned SHA → rename bundle/App Group/Keychain/`APPLE_CLIENT_ID`/GHCR/domain/DB → fresh migrations + `openapi.yaml` per specs → new `docs/project-context.md` → first TestFlight. Rollback: new repo, nothing to roll back in Lifio; this change itself archives with zero Lifio impact. Deploy order: backend + DB first, iOS TestFlight second (same as Lifio's pipeline).

## Open Questions

- Q1: Snooze cut stands? (If overturned: single 30m action, max 3, clamp before next due — needs spec edit to `reminder-engine` + task delta. Safely answerable at proposal review without changing other specs.)
- Q2: Analytics placement (sections vs tab) — parked with analytics; answerable when analytics un-parks, no v1 impact.
- Q3: S3-compatible vendor choice (AWS vs R2 vs MinIO) — backend detail, no spec impact; decide at Shunik infra setup.
