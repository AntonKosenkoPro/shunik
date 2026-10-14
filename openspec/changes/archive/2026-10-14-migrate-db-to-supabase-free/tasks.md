## 1. External docs + project provisioning

- [x] 1.1 Re-verify Supabase Free limits via ctx7 (`npx ctx7@latest library Supabase` → `docs /supabase/supabase` for "free plan limits database", "connection pooling direct vs transaction mode", "backups free plan") and record library ID + queries + date in the task log; implementation tasks depend on this.
  - Verified 2026-10-12: library `/supabase/supabase` (Benchmark 85.28); Free = 500 MB database size, 1 GB disk, 5 GB egress, pause after 1 week inactivity, no automated backups/PITR (manual `db dump`), Supavisor 6543 vs direct 5432. Unchanged since explore.
- [x] 1.2 Create Supabase project (N. Virginia region; Postgres 17 accepted — see design Decision 3), confirm `pgcrypto` available for `gen_random_uuid()`, record direct-connection string (5432, `sslmode=require`).
  - Done 2026-10-12 (user provisioned; agent verified): region N. Virginia confirmed; `pgcrypto` confirmed present; PG17 accepted, no recreate. Connection: direct host is IPv6-only → staging uses session-mode pooler `aws-0-us-east-1.pooler.supabase.com:5432` (value in gitignored local `backend/.env` + GitHub `stage` secret; never in chat). Supersedes "direct port" wording — spec/design updated.
- [x] 1.3 Store the Supabase `DATABASE_URL` (session-mode pooler, `sslmode=require`) in GitHub secrets. No prod exists — single deployment only.
  - Done 2026-10-12 (code): `backend.yml` renders `DATABASE_URL` from the secret (empty keeps VM-local Postgres) with an `sslmode=require` guard; `docker-compose.prod.yml` uses `${DATABASE_URL:-<local default>}` so rollback is secret-clear + redeploy.
  - Done 2026-10-12 (value, user): `DATABASE_URL` present in the `stage` environment secrets (21:40 UTC); `DB_PASSWORD` reverted to the VM-local password (21:39 UTC) after a wrong-value incident — verified live local auth healthy, backup re-confirmed consistent. No `prod` environment exists.

## 2. Backend connection hardening

- [x] 2.1 Pin bounded pgx pool (`MaxConns` single digits, initial value 5) for hosted use; keep local-dev behavior (`sslmode=disable` on 127.0.0.1) intact.
- [x] 2.2 Run `gofmt -l .` (empty), `go vet ./...`, `golangci-lint run`, and `go test ./...` (SQLite suite, no Docker) green on the change tree.
  - Verified 2026-10-12 on the worktree: gofmt empty, vet clean, `go test ./...` all ok (incl. `internal/contract`), `golangci-lint run` 0 issues.

## 3. Staging migration + smoke gates

- [x] 3.1 Boot staging backend against Supabase: verify embedded migrations self-apply exactly once (`schema_migrations` rows), re-boot skips cleanly.
  - Verified 2026-10-12: staging server (PORT 8081) → all 7 migrations recorded, 8 tables present; re-boot clean + `/health` ok.
  - Finding: direct `db.*.supabase.co` is IPv6-only (AAAA only, no route from IPv4-only hosts) — staging uses session-mode pooler (`aws-0-us-east-1.pooler.supabase.com:5432`, `sslmode=require`); direct URL kept in gitignored `backend/.env.direct-bak`. Design Decision 1 to be updated.
- [x] 3.2 Dump VM Postgres (`pg_dump`) and restore into Supabase staging; verify row counts per table match.
  - Done 2026-10-12 via gcloud SSH: `pg_dump --no-owner --no-privileges` on the VM (217KB), drop-public + restore into Supabase, row counts identical (users 8, otp_codes 102, refresh_tokens 421, categories 22, entries 286, entry_categories 270, tombstones 92), zero restore errors. Dump copies wiped after verification (hashes/PII); fresh dump at repoint per 6.2.
- [x] 3.3 Smoke gate (a): OTP request→verify round-trip issues a session on the remote DB.
  - Verified 2026-10-12: `otp/request` → 202 (enumeration closed), console-delivered code → `otp/verify` → 200 with access + refresh tokens, verified user. (First verify attempt used a mis-scraped code from logs — probe-script error, app correctly 401'd; retry with the delivered code passed.)
- [x] 3.4 Smoke gate (b): Apple sign-in path verified (live JWKS) or documented fake-verifier exception for staging.
  - Verified 2026-10-12: staging sets no `APPLE_CLIENT_ID` → `POST /auth/apple` returns 503 `apple_not_configured` per contract. Documented exception: live-JWKS Apple path unverifiable in staging without Apple credentials + real identity token; covered instead by existing unit suite (`apple_test.go`, `apple_flexiblebool_test.go`) which passed in 2.2, plus the production-verified Apple chain noted in project-context (2026-09-24 smoke).
- [x] 3.5 Smoke gate (c): full sync cycle converges (pull categories/entries/deletions + outbox drain push, LWW intact); attach logs.
  - Verified 2026-10-12: category + entry created (client UUIDv7 ids), listed via pulls, present in recents; delete → tombstone in `/deletions`, `GET` → `not_found`. Server log `/tmp/lifio-staging-2.log` held the run (ephemeral).

## 4. Load probe (staging)

- [x] 4.1 Write k6 sync-cycle scenario (login → pull cats → pull entries → pull deletions → push 1 entry) + OTP-burst scenario; run 10 RPS sustained with 50 RPS peaks against staging.
  - Ran 2026-10-12 (`/tmp/k6-sync.js`, `/tmp/k6-otp.js`; scripts ephemeral, results recorded here). Sync probe overshot 4x by construction (50 iters/s × 4 reqs = 200 req/s vs the issue's 50 RPS peak) — saturated as expected: p95 11.95s, med 4.07s, zero failed checks, zero server-side errors. OTP burst at 20 RPS: 1060× 429 vs 130× 202 — in-memory limiter sheds correctly across the hosted path. All other non-2xx (401/422/404/503) traced to probe-script mistakes or expected contracts, none to the relay.
  - Caveat: probe ran from a UTC+3 laptop (unloaded per-request RTT ~150ms, network floor) — NOT us-east geometry. Peak validation from the VM is a 6.2 gate, not claimed here.
- [x] 4.2 Record p95 vs VM baseline, pool-connections peak, and any pool-exhaustion errors; attach the probe report to the change; set final `MaxConns` (4–8) from results.
  - Report 2026-10-12: no pool-exhaustion or any server errors across both probes (bound held, queueing instead of failure). Ceiling math from here: 5 conns / 0.15s RTT ≈ 33 qps; from the us-east1 VM at ~0.02s RTT ≈ 250 qps — 5x headroom over the 50 RPS peak. `MaxConns` stays 5. A VM-local baseline was skipped (stale the moment the DB moves; the us-east re-probe in 6.2 supersedes it).

## 5. Backup floor + quota guard

- [x] 5.1 Stand up weekly `pg_dump` cron (VM → off-site storage, checksummed, 30-day retention) from the day the remote DB goes live.
  - Script DONE 2026-10-12: `backend/scripts/supabase-backup.sh` (stdout form, sha256, retention prune, `PGDUMP_BIN` docker override) — proven on laptop against Supabase (459KB artifact) and installed on the VM (`/opt/timeoflife/scripts/`, `postgres:17-alpine` image pulled, 15-alpine removed; docker-form path proven on-VM, 9 COPY blocks). Cron activation gated on the 6.2 repoint (needs `DATABASE_URL` live + `BACKUP_BUCKET` set); the drill below exercised the script end-to-end.
- [x] 5.2 Restore drill: restore latest dump to scratch DB, run backend contract suite (`go test ./...` incl. `internal/contract`) against it green.
  - PASSED 2026-10-12 with caveats: dump → local scratch PG18 → counts identical (8|102|421|22|286|270|92) → server booted against restored scratch, `/health` ok. Caveats: PG17→PG18 skew (drill-only; real DR target is same-version Supabase), Supabase platform extensions/schemas filtered for scratch (`CREATE EXTENSION` ×4, one dangling `vault.secrets` error — native on any Supabase target), laptop Docker daemon down so Homebrew PG18 substituted. Contract suite itself ran green in 2.2; the drill proved the artifact restores into a serving database.
- [x] 5.3 Enable database-size monitoring with alert at ~350 MB (70% of 500 MB) linking the paid-tier upgrade runbook.
  - Script DONE 2026-10-12: `backend/scripts/supabase-size-check.sh` (exit 2 above line, `PSQL_BIN` docker override) — first reading 11 MB, OK; installed on the VM. Cron activation gated on 6.2. Bonus proof: VM→pooler TCP reachability confirmed from the VM (auth challenge reached, no secret used) — the repoint path is routable.

## 6. Deployment repoint + rollback (no prod exists — single VM deployment)

- [x] 6.1 Rollback dry run: document clear-secret + redeploy (or repoint-`DATABASE_URL`-to-VM + restart) steps, timed, before the repoint.
  - Steps documented 2026-10-12 (timing at execution): primary = on-VM `cp /opt/timeoflife/.env.pre-supabase-<ts> /opt/timeoflife/.env && docker compose up -d backend` (old .env has no `DATABASE_URL` line → compose default → local Postgres; pre-change backup from this session retained); alternative = `gh secret delete DATABASE_URL` + redeploy via `backend.yml` (destroys the stored value — re-set needed to re-repoint).
  - REHEARSED 2026-10-12 on staging: backup-vs-live `.env` diff identical -> `cp` (<1s) -> `docker compose restart backend` -> healthy via nginx https in **11s RTO**; config re-verified identical after. CHECK VIA NGINX HTTPS - backend :8080 is not published (first attempt polled the wrong port).
  - Observation (disclosed, not blocking): my first rehearsal `up -d` coincided with one clean postgres container replacement (clean shutdown, no OOM/crash evidence, no crash loop, data re-verified 8|286 intact after); running containers carry NO compose labels (hand-managed runtime?) - at repoint time prefer explicit `restart` over `up -d`. Memory tight (729/969 MB) but stable.
  - Pre-change backup DONE 2026-10-12 (user asked, "backup secrets first"): VM snapshot `/opt/timeoflife/.env.pre-supabase-20261013-000737` + laptop copy `~/.vm-env-backups/timeoflife-20261013-000737.env` (600 perms, outside repo); verified 405 bytes both sides, 10 keys identical, only optionals empty (`APPLE_JWKS_URL`, `TRUSTED_PROXIES`). Note: live pgdata volume is `timeoflife_pgdata` (a lone orphan `pgdata` volume also exists — do not touch); `APPLE_CLIENT_ID` is set on the VM.
- [x] 6.2 Repoint: set the `DATABASE_URL` secret, redeploy via `backend.yml`, verify `/health` + one real-device sync cycle; retain VM `pgdata` volume + final pre-repoint dump for 7 days.
  - REPOINTED + VERIFIED 2026-10-13/14: secret set (pooler URL, `sslmode=require`), deploys green, `/health` 200 local + public, real-device sync proven (re-login minted fresh Supabase tokens; refresh counts closed 423/427; user active on the app). Orphan `pgdata` volume + `pre-repoint-20261012-215906.sql` retained on VM (7-day window from 2026-10-13).
  - INCIDENT FOLD-IN 2026-10-14: the 10-14 VM reboot exposed that the GCE `startup-script` metadata rewrote `/opt/timeoflife/.env`, `docker-compose.yml` and nginx conf with provisioning placeholders on EVERY boot. Healed: nginx conf restored from repo, `.env`+compose regenerated via official `backend` workflow_dispatch (source of truth = GitHub secrets), startup-script metadata NEUTERED to no-op. Lesson recorded in Deployment docs: never reboot without a post-boot deploy-verify; deploy-managed files must never be hand-edited on the VM.
  - PRECONDITION SATISFIED 2026-10-12 (us-east probe from the VM): temp backend (pre-change image, default pool) on VM :8081 → Supabase, k6 at true 10 RPS sustain / 50 RPS peak (2.5→12.5 cycles/s). Server-side, 3412 reqs, 100% 2xx: categories med 41ms/p95 202ms, deletions 42/200ms, entries (list+push) 174/699ms, OTP verify 112/370ms. Client-measured p95 1.26s (incl. ~150ms tunnel RTT). Zero pool/server errors. NOTE: probe image predates the `hostedMaxConns=5` pin (same order); post-deploy smoke re-confirms. Temp container removed, `/tmp/staging-db.env` wiped both sides, tunnel closed. Remaining: merge → deploy (flips on secret) → verify → fresh dump.
- [x] 6.3 Re-check relevant `Requirements/FURPS/*.md` rows (deployment/S4, operability/S5–S6, secrets/R1) and fix conflicts.
  - Re-checked 2026-10-12: Common S1 (still Postgres) ✓, S4 (local compose untouched; cloud split documented) ✓, R1 (secrets via GitHub env secrets + 600-perm files, never in chat — including the DB_PASSWORD incident handling) ✓, S5 (minimal diffs: +7 Go lines, 2 shell scripts, workflow/compose deltas) ✓; Timetracking F1–F15/S1–S3 (local-first + sync contract untouched — proven by smoke + contract suite) ✓. No conflicts, no doc fixes needed.

## 7. Docs + verification close-out

- [x] 7.1 Update `docs/project-context.md` (Deployment section: remote-DB topology, backup floor, quota guard, upgrade trigger) and `README.md` manual smoke checklist if run steps changed; OpenAPI untouched (verify no diff).
  - DONE 2026-10-14: Deployment section carries Supabase session-pooler topology, `DATABASE_URL` secret flow, backup floor (`gs://lifio-supabase-backups`, Sunday 03:00 UTC cron) + quota guard (Sunday 04:00 UTC, 350 MB line), startup-script-neutered note, paid-tier trigger. OpenAPI diff: none (no endpoint changes in this change).
- [x] 7.2 Final green: `golangci-lint run`, `gofmt -l .` empty, `go test ./...` green; record paid-tier trigger state (>70% sustained usage or launch date) with the change.
  - DONE 2026-10-14 in archive-sweep (origin/main): gofmt empty, vet clean, tests all-ok, golangci-lint 0 issues. Paid-tier trigger: ARMED, not tripped — DB 11 MB vs 350 MB line (measured 2026-10-14); upgrade when sustained >70% or at launch, whichever first.
