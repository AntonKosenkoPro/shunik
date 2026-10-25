## Why

Lifio's chassis (passwordless auth + per-device sessions, GRDB outbox sync, CI/deploy pipelines) is the most expensive part to rebuild, but its domain (time tracking) shares nothing with the new pet-care app **Shunik** (new repo `AntonKosenkoPro/shunik`, App Store Connect record already created). This change captures the entire explore-session spine — domain model, day-1 household sharing, infra/agent migration plan, and the deferred list — as portable planning artifacts so the Shunik repo can be forked without repaying the design cost or losing the open-thread resolutions.

## What Changes

- **New product spine**: account-rooted library + one-pet events via `event_base` + kind details, medication `course → intakes[]`, staged documents (CDN presigned blobs, metadata syncs), unified reminder engine, canonical-units system, day-1 household sharing (two equal owners).
- **Fork plan (clone-then-strip)**: what moves verbatim from Lifio, what is re-scoped (`user_id → household_id`), what is dropped (timer, Live Activities, categories, Insights-by-time).
- **Agent-scaffolding migration**: `AGENTS.md` rewrite, `opencode.json` verbatim, clean `openspec init` + skill reinstall in the new repo.
- **Explicit v1 cuts**: weight norm/corridor, calendar integration (whole), owner analytics, vet PDF reports, litter multi-create, curated drug DB — all parked as named deferred items, not silent omissions. Snooze ships cut (pending sits red until marked) unless proposal review overturns it.
- **BREAKING** (for the new repo, not Lifio): fresh DB + migration history — no Lifio rows, no Lifio on-disk formats. Nothing in this change touches Lifio runtime code or baselines.

## Capabilities

### New Capabilities

- `household-sharing`: one household per user, two equal owners day-1, email-OTP invite flow, `updated_by`/`marked_by` attribution, revoke = lock-not-wipe, both-phones-buzz reminders.
- `pet-events`: `event_base` (`pet_id NOT NULL`, immutable) + kind details (vaccination/grooming point + next-due, weight series); single-pet-feel adaptive IA (no scope chrome until `pets.count > 1`).
- `medication-schedule`: `course → intakes[]` children with dose snapshot, states pending → taken/missed/skipped, auto-miss on supersede, PRN as schedule-less course, wall-clock `due_at`, edit rewrites future pendings only.
- `document-library`: account-rooted library, zero-to-many pet links (`document_pets`), metadata syncs via outbox + tombstones, bytes via CDN presigned PUT/GET, staged search (name → extracted text → OCR) and staged share (sheet → link).
- `reminder-engine`: one cross-kind queue over `(due_at, pet_id, title, link)`; rolling ~14d UN window (64-slot cap); deterministic notification IDs; per-device mute; duplicate suppression via `marked_by` sync.
- `unit-system`: canonical integer storage (grams), per-device Metric/Imperial setting (locale default), field chip filtered by system with live draft conversion, decimal pounds, trend epsilon rule; dimension concept reserved for future dose units.

### Modified Capabilities

(none — this change alters no Lifio baseline behavior; it is a portable plan for the Shunik repo.)

## Non-goals

- No Lifio code changes in this change (planning artifacts only; `skip_specs` is NOT set because new-capability deltas are declared).
- No calendar integration, no analytics, no weight norm, no vet reports, no PRN beyond log-only, no per-pet roles, no multi-household per user, no FTS/OCR beyond schema reservation, no share-links beyond the system sheet.
- No curated drug database (owner-typed card + prescription photo only; no medical-accuracy liability in v1).
- No field-level sync merge (row-level LWW is enough for v1).

## Impact

- **Code**: zero runtime impact on Lifio. Artifacts migrate to `AntonKosenkoPro/shunik` at fork time: delta specs become seed specs, design becomes the build reference, tasks become the fork checklist.
- **API**: new-repo `openapi.yaml` will follow Lifio conventions (envelope, client UUIDv7 ids, idempotent creates, LWW `updated_at`, tombstones at `GET /deletions`) with `household_id` scoping; S3-compatible blob endpoints are new surface.
- **Systems**: second backend deployment (same cluster, new DB/image/domain), new bundle + App Group + `APPLE_CLIENT_ID`, new GHCR image path, new TestFlight record (exists).
- **Docs**: new-repo `docs/project-context.md` must be written at fork (this change does not create it — Shunik repo does).

## Research

- GRDB `/groue/grdb.swift` — `FTS5 full-text search` (FTS5Pattern/MATCH for staged document search; pin: GRDB v7.x as in Lifio).
- Apple UserNotifications `/websites/developer_apple_usernotifications` — `UNUserNotificationCenter pending notification requests` (rolling-window scheduling; 64-slot cap is the documented platform limit, re-verified at Shunik apply).
- Amazon S3 `/websites/aws_amazon_s3` — library resolved for presigned PUT/GET + confirm + GC flow; docs fetch deferred to Shunik apply (standard flow, backend-side).
- HIG `/websites/developer_apple_design_human-interface-guidelines` — WAIVED for this artifact (no pixel/screen decisions; adaptive-IA rule is structural, HIG query lands with screen design in the Shunik repo).
- SwiftUI Charts — WAIVED (standard chart usage for weight trend; API shape re-confirmed at Shunik apply, "nothing changed since explore" check then).
