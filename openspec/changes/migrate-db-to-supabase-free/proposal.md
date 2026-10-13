## Why

The relay's PostgreSQL currently lives inside the same e2-micro VM as the API and nginx (issue #79). That single box is a single point of failure with no managed backups, and its 1 GB RAM is shared between Postgres and Go. Sizing analysis shows ~9 GB in year one at realistic growth — far below the issue's 100 GB ceiling — so the first step is to split the database off the VM onto a $0 managed host and validate the split before spending on a paid tier. Why now: this unblocks the pre-release backend-evolution path with zero monthly cost and a rollback that stays free.

## What Changes

- Provision a Supabase Free project (500 MB database size, shared CPU, N. Virginia region) as the relay's first remote database.
- Repoint the single (staging — no prod exists yet) VM deployment's `DATABASE_URL` at Supabase over TLS (`sslmode=require`, session-mode pooler, port 5432); the switch is secret-driven and backward compatible (empty secret keeps VM-local Postgres). Keep the existing `pgdata` volume and a dump as rollback for one week.
- Pin a small pgx pool (`MaxConns` single digits); run embedded migrations at boot exactly as today (advisory-locked, migrate-once semantics preserved).
- Validate with a full smoke (OTP round-trip, Apple verify path, one sync cycle) plus a k6 sync-cycle load probe (10 RPS sustained / 50 RPS peak) before the deployment is repointed.
- Stand up a weekly `pg_dump` cron from day one (Free tier has no automated backups) and a usage alert at ~70% of 500 MB (over-quota flips the project read-only).
- Paid-tier upgrade trigger defined but **not executed** here: >70% sustained usage or AppStore launch date, whichever first.

## Capabilities

### New Capabilities

- `backend-database`: relay database hosting contract — the relay SHALL run against a remotely-hosted managed Postgres reachable over TLS; connection, migration, backup-floor, quota-guard, and upgrade-trigger requirements for the Supabase Free first step.

### Modified Capabilities

(none — no baseline REQUIREMENTS change: OpenAPI contract, sync protocol, auth flows, and local-first guarantees are untouched; this change only relocates the relay's database.)

## Impact

- Backend only: `DATABASE_URL` value, pgx pool sizing, deploy env regeneration (`.env` on the VM via the existing `backend.yml` flow), docs (`docs/project-context.md` Deployment section + sizing note).
- No iOS changes; no OpenAPI changes; no migration SQL changes (existing 7 files apply unmodified; `pgcrypto` pre-enabled on Supabase).
- New external dependency: Supabase-hosted Postgres (Free plan). Cross-cloud latency (GCP VM → AWS) lands in sync p95 — measured by this change's load probe, not assumed.

## Non-goals

- No prod topology: prod does not exist yet — this change repoints the single staging deployment. Prod creation (host, paid tier, version pin) rides with the AppStore launch milestone, not here.
- No multi-instance API, no Redis rate-limit swap (still single Go instance; in-memory limiter stays correct).
- No PITR (unavailable on Free; daily-backup equivalent is the `pg_dump` cron until the paid tier).
- No retention/GC policy for entries/tombstones; no note-size caps (tracked as follow-ups, not this change).
- No Postgres major-version change (stays on 15; avoids Cloud SQL Enterprise Plus pricing later).

## External docs (ctx7)

- Library: `/supabase/supabase` (supabase/supabase master, no version pin — docs track the hosted platform).
- Queries used: "free plan limits database" (500 MB database size, 1 GB disk, 5 GB egress, 2-project cap), "free plan pause cold start connection pooling" (pause after 1 week inactivity, Supavisor 6543 transaction mode vs 5432 direct), "backups point in time recovery free plan" (no automated backups/PITR on Free; manual `db dump`; Pro 7-day backups; PITR +$100/mo).
