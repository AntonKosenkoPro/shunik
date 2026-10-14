## Context

See `proposal.md` (Why) and `specs/backend-database/spec.md` (requirements). Current state shaping this design:

- Relay: single Go process (`cmd/server/main.go`) on an e2-micro VM, `NewPostgresStore` parses `DATABASE_URL` via `pgxpool.ParseConfig` with **default pool settings** (unbounded for hosted use), `sslmode=disable` in local compose.
- Migrations (`internal/migrations/embed.go`) are embedded SQL, tracked in `schema_migrations`, serialized by a session-scoped `pg_advisory_lock` — safe for concurrent boots only on a session-stable connection.
- SQL is vanilla Postgres (`gen_random_uuid()`, `ON CONFLICT` incl. the partial-index Apple upsert); no extensions are created by the migration set.
- Deploy: `backend.yml` regenerates `/opt/timeoflife/.env` from GitHub secrets on every deploy — the repoint/rollback lever is env-only (`DATABASE_URL` secret set = hosted, empty = VM-local).
- Invariants (from `docs/project-context.md`): OpenAPI is the authoritative contract (S10 — unchanged here); secrets from env, never logged (R1); iOS/LocalStore untouched — device stays source of truth, so relay downtime degrades to offline-mode, never data loss.

## Goals / Non-Goals

**Goals:**

- Split the database off the VM onto Supabase Free with zero query changes and zero contract changes.
- Prove the split with recorded gates (smoke + k6 10/50 RPS probe) before the deployment is repointed.
- Establish the backup floor (`pg_dump` cron) and quota guard (~350 MB alert) from day one.
- Keep rollback configuration-only with a 7-day window.

**Non-Goals:**

- No pooler adoption (Supavisor 6543) in this change — single instance uses direct 5432; pooler is a later multi-instance concern alongside the Redis limiter swap.
- No PITR, no HA, no read replicas — explicitly deferred to the paid-tier follow-up.
- No migration SQL edits unless staging proves one is needed (e.g. explicit `CREATE EXTENSION IF NOT EXISTS pgcrypto` if the project lacks it).

## Decisions

### 1. Session-mode pooler (5432 + `sslmode=require`), not direct 5432

Why: the provider's direct host is IPv6-only and both the dev laptop and (almost certainly) the GCE VM are IPv4-only — direct 5432 is unreachable (`no route to host`, proven in staging). The session-mode pooler on the same hostname is IPv4-reachable and preserves session semantics, so the boot path's session-scoped advisory lock and single held connection stay valid; a single Go instance with a bounded pool fits the Free connection budget either way. Transaction mode (6543) is still excluded: it breaks the migration lock and buys nothing single-instance. Alternatives considered: dedicated IPv4 add-on (~$4/mo) to keep direct — deferred to the paid-tier follow-up (keeps this step $0); giving the VM external IPv6 — most invasive, no benefit over session mode for this workload.

### 2. Pin `MaxConns` to single digits + keep all timeouts from config

Why: pgx defaults assume a local Postgres; against a hosted micro, an unbounded pool turns a 50 RPS burst into connection-churn latency and risks hitting plan limits. Timeouts already come from env (`HTTP_*`, `RequestTimeout`) — no new knobs, just a bounded pool sized for 10/50 RPS of small indexed queries (validation probe confirms).

### 3. Supabase project in N. Virginia (us-east-1); Postgres 17 accepted for this step

Why: closest region to the GCE VM (`us-east1-b`) minimizes the cross-cloud penalty that every sequential sync-cycle round trip pays. The provisioned project runs Postgres 17 (Supabase default for new projects; major-version downgrade in place is unsupported — it would mean recreating the project): accepted because the relay's SQL is version-insensitive across 15→17 (`gen_random_uuid()`, `ON CONFLICT` incl. the partial-index Apple upsert, advisory locks, plain indexes — no version-gated features). The PG15-match rationale (local `postgres:15-alpine` image, Cloud SQL Enterprise Plus defaults on 16+) is preserved for the paid-tier follow-up, where the production version gets pinned deliberately. Alternative (recreate the project on PG15 if the creation dialog still offers it) rejected: process churn for zero behavioral benefit at this step.

### 4. Weekly `pg_dump` cron to off-site storage from day one

Why: Free has no automated backups (ctx7: "free tier projects [should] regularly export ... and maintain off-site backups"); the relay is a sync relay, not source of truth, but a week of OTP/refresh/category writes is still worth a cheap cron. Dump runs from the VM (same region as API, credentials from existing secrets flow), artifacts checksummed, 30-day retention. Alternative (Supabase Pro for backups now) rejected: $25/mo before the split is even proven — the upgrade trigger in specs covers it.

### 5. Validate-then-repoint on the single deployment

Why: the failure modes (latency surprise, pause-after-idle, RO-tripwire) are all observable for $0 before the repoint. The `.env` regeneration already exists in `backend.yml`, so the flip is a secrets change + redeploy, with the old volume retained. There is no prod yet, so no prod-vs-staging topology is decided here — prod creation rides with the launch milestone.

## Risks / Trade-offs

- [Cross-cloud p95 regression] → k6 probe records p95 vs VM baseline in staging; accepted budget documented before flip; region choice minimizes it.
- [Pause after 7d idle] → accepted (loud wake-up, documented): no prod traffic exists yet to keep the project warm, so pauses are expected pre-launch; no keepalive hack committed — if pauses annoy, that data point accelerates the paid-tier decision at launch.
- [500 MB RO-tripwire partial outage] → quota guard requirement (alert at ~350 MB) + repoint refusal above the line; sizing math (~9 GB/yr realistic) says months of headroom.
- [Dump cron is not PITR] → RPO is up to 7 days by design in this step; stated in specs, superseded by the paid-tier trigger. Relay is secondarily reconstructible (devices hold source of truth; worst case is re-bootstrap via first-sync pull-first).
- [`pgcrypto` availability] → verified at staging boot (Supabase pre-enables it); if absent, a one-line idempotent `CREATE EXTENSION` migration addition — no other SQL changes expected.
- [Secrets sprawl] → new `DATABASE_URL` value flows through the existing GitHub-secrets → `.env` regeneration; no new secret channel, R1 preserved.

## Migration Plan

1. Create project (N. Virginia, PG15), record direct connection string in GitHub secrets (staging set first).
2. Staging backend boots → embedded migrations self-apply → verify `schema_migrations` + `pgcrypto`.
3. Seed/import: `pg_dump` from VM Postgres → restore into Supabase (pre-release data is tiny; full dump, no replication).
4. Staging gates: OTP round-trip, Apple path, full sync-cycle convergence, k6 10/50 RPS probe with p95 report.
5. Repoint: set the `DATABASE_URL` secret, redeploy via `backend.yml`, verify health + one sync cycle from a real device; retain VM `pgdata` + final dump 7 days.
6. Enable `pg_dump` cron + quota alert; record paid-tier trigger state.
7. Rollback (≤7d): clear the secret (or repoint `DATABASE_URL` to VM), redeploy/restart — no code, no migrations (dry-run documented pre-repoint).

## Open Questions

- Apple staging verification: live JWKS against staging Supabase-backed relay, or documented fake-verifier exception? Answer during implementation; does not change specs (gate (b) allows either with documentation).
- k6 host: second small VM vs CI runner? Pick at implementation time; either satisfies the probe requirement.
- Exact `MaxConns` value (4–8): set from probe results, not upfront.

## External docs (ctx7)

- `/supabase/supabase` — "free plan limits database", "free plan pause cold start connection pooling", "backups point in time recovery free plan" (same fetch as proposal; platform-tracked docs, no version pin).
