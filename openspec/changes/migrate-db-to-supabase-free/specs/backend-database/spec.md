## Purpose

Pins the relay's database hosting contract for the first migration step off the all-in-one VM: the relay SHALL run against a remotely-hosted managed Postgres (Supabase Free) reached over TLS, with a backup floor, quota guards, and validation gates that must pass before the deployment is repointed. (No prod exists yet — the single VM deployment is staging; "repoint" throughout means that deployment.)

## ADDED Requirements

### Requirement: Relay database is remote managed Postgres over TLS

The relay SHALL connect to a remotely-hosted managed Postgres instance (Supabase Free, N. Virginia region) as its system of record. The connection SHALL use TLS (`sslmode=require`) over a session-stable connection: the provider's direct Postgres port where reachable, else the provider's session-mode pooler — never plaintext, and never a transaction-mode pooler for boot-time work (session-scoped migration locks are invalid there). The existing embedded migration set SHALL apply unmodified at boot (recorded in `schema_migrations`, exactly-once semantics preserved). All existing relay behavior (auth flows, sync protocol, OpenAPI contract) SHALL be byte-identical from the caller's perspective: no endpoint, status code, or error envelope changes.

#### Scenario: Boot applies migrations on the remote database
- **WHEN** the relay boots against the remote database with no `schema_migrations` rows
- **THEN** all embedded migrations apply exactly once and subsequent boots skip them (recorded rows present, no re-apply)

#### Scenario: TLS-only connection
- **WHEN** the relay connects to the remote database
- **THEN** the connection negotiates TLS; a plaintext connection attempt is refused by configuration (no `sslmode=disable` outside local development)

#### Scenario: API contract unchanged
- **WHEN** any existing contract test suite runs against the relay on the remote database
- **THEN** every test passes unmodified (same endpoints, same idempotency, same LWW semantics)

### Requirement: Bounded connection pool and direct-connection boot discipline

The relay SHALL use a small bounded connection pool (single digits) against the hosted database — never the pgx default unbounded growth. Boot-time migration work (advisory-locked) and readiness checks SHALL use the direct connection, because session-scoped primitives (advisory locks) are invalid through a transaction-mode pooler. Steady-state queries MAY share the same direct pool while the deployment stays single-instance.

#### Scenario: Pool stays bounded under peak probe
- **WHEN** the 50 RPS peak load probe runs a full sync cycle workload
- **THEN** the relay's open database connections never exceed the configured bound and no query fails with pool exhaustion

#### Scenario: Concurrent boots serialize migrations
- **WHEN** two relay instances boot simultaneously against the same remote database
- **THEN** exactly one applies each pending migration (advisory lock serializes them) and both end serving with identical schema

### Requirement: Backup floor despite no automated backups on Free

The Free plan provides no automated backups, so the system SHALL have a weekly `pg_dump` cron from day one of the remote database going live, with artifacts retained off-site (outside both the VM and the database project) for at least 30 days. A restore drill against a scratch database SHALL succeed before the deployment is repointed. Deleting the database project SHALL be a prohibited operation while it serves any environment.

#### Scenario: Weekly dump artifact exists
- **WHEN** any calendar week passes with the remote database serving the deployment
- **THEN** at least one restorable `pg_dump` artifact for that week exists in off-site storage with a recorded checksum

#### Scenario: Restore drill passes pre-cutover
- **WHEN** the operator restores the latest dump into an empty scratch database and runs the relay's contract tests against it
- **THEN** the restore completes and the contract suite passes (proving the dump is not just bytes but a working database)

### Requirement: Quota guard below the read-only tripwire

The Free plan flips a project read-only above 500 MB database size (writes fail while reads succeed — a confusing partial outage for a sync relay). The system SHALL monitor database size continuously and SHALL raise an alert at or before 70% of quota (~350 MB). The deployment SHALL NOT be repointed while usage sits above the alert line without the paid-tier upgrade executed first.

#### Scenario: Alert fires before read-only
- **WHEN** database size crosses ~350 MB
- **THEN** an alert reaches the operator (dashboard alarm or equivalent) while writes still succeed, with the paid-tier upgrade runbook linked

#### Scenario: Over-quota blocks repoint
- **WHEN** a repoint is requested while usage exceeds the alert line
- **THEN** the repoint is refused until the paid-tier upgrade (or data reduction with a fresh measurement below the line) is complete

### Requirement: Validation gates before the deployment is repointed

The deployment SHALL be repointed to the remote database only after ALL of the following pass against it: (a) OTP request→verify round-trip issues a session; (b) Apple sign-in path verifies (live JWKS or a documented fake-verifier exception for staging); (c) one full sync cycle (pull categories/entries/deletions + outbox drain push) converges; (d) a k6 sync-cycle probe sustains 10 RPS with peaks of 50 RPS with recorded p95 latency and zero pool-exhaustion errors. Results SHALL be recorded with the change before the repoint.

#### Scenario: Staging gates all green
- **WHEN** the four validations run against staging on the remote database
- **THEN** each passes with its evidence (logs, probe report with p95) attached to the change, and only then is the repoint task unblocked

#### Scenario: Failed gate blocks repoint
- **WHEN** any validation fails (e.g. p95 regression vs the VM baseline beyond the accepted budget, or a sync conflict divergence)
- **THEN** the deployment stays on the VM database and the failure is triaged as a blocking issue for this change

### Requirement: One-week rollback window after repoint

After the repoint, the previous VM database volume and a final pre-repoint dump SHALL be retained for 7 days. Rollback SHALL be a configuration-only operation (repoint `DATABASE_URL` at the VM database, restart) requiring no code change and no migration replay. The rollback SHALL be exercised as a dry run (documented steps, timed) before the repoint.

#### Scenario: Rollback repoints without migrations
- **WHEN** the operator performs the rollback within the retention window
- **THEN** the relay serves from the VM database after a restart with no schema changes and no data written to the remote database is required for correctness (any writes made remotely during the window are reconciled per the documented reconciliation note, or the window is declared lossy-by-design with sign-off)
