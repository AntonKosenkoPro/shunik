# Backend Test Framework

Test framework: **Go test (built-in)** — `*_test.go` alongside source (Go convention), SQLite in-memory for unit/API tests, PostgreSQL for parity tests, executable OpenAPI contract fixtures.

## Quick Start

```bash
go test ./...            # full suite (SQLite only; no Docker needed)
go test ./... -race      # race detector (matches CI)
make test                # go test ./... -cover
make test:race           # go test ./... -race
make test:cover          # coverage profile + per-function report
make test:pg             # PostgreSQL parity tests (needs Docker)
```

`make test:pg` runs the PostgreSQL parity tests against `TEST_PG_DSN` (defaults to the local `docker-compose.yml` Postgres on `localhost:5432`); it does **not** start Docker itself — run `docker compose up -d postgres` first. The parity suite skips itself when `TEST_PG_DSN` is unset, so `go test ./...` stays green offline.

## Architecture

| Piece | Location | Purpose |
|---|---|---|
| Unit + API tests | `internal/*/*_test.go` | Logic + handler tests over an in-memory SQLite store (no Docker) |
| OpenAPI contract gate | `internal/contract/openapi_test.go` | Executable contract fixtures pinning `api/openapi.yaml` to documented invariants (R-006) |
| PostgreSQL parity | `internal/db/postgres_parity_test.go` | Same critical auth/session semantics against real PostgreSQL (R-007) |
| Factories | `internal/handlers/auth_test.go` (helpers: `mintBearer`, `decodeBody`, `errCode`) | Deterministic seeding for auth-domain tests |
| Handler harness | `catalogRouter`, `serve`, `mintBearer`, `jsonReq`, `decodeBody`, `errCode` | Real chi routing + auth + handlers without a network socket |

## Best Practices

- **Factories over hand-rolled bodies** — seed state with the `auth_test.go` helpers (`mintBearer`, `decodeBody`, `errCode`); overrides keep intent explicit.
- **SQLite everywhere possible** — the parity suite is the only Postgres-dependent piece and is `TEST_PG_DSN`-gated.
- **Contract discipline** — the OpenAPI spec is authoritative (S10). If a handler emits a new error code or a path changes, update `api/openapi.yaml` **and** the `canonicalErrorCodes`/`bearerProtectedPaths` lists in `internal/contract/openapi_test.go` together; the gate fails otherwise.
- **Deterministic time** — avoid `time.Now()` in seeds and assertions; use fixed UTC anchors.
- **Ownership checks** — cross-user tests mint two bearers (user A's resources must 404 for user B).

## CI Integration

`.github/workflows/backend.yml` runs `gofmt`, `go vet`, `golangci-lint`, and `go test ./... -race -coverprofile` on every PR (Requirements S6). The OpenAPI contract gate and SQLite suites run there with no Docker. Run PostgreSQL parity explicitly with `make test:pg` against the compose Postgres.

## Troubleshooting

- **Parity tests skip** — `TEST_PG_DSN` unset; run `docker compose up -d postgres` then `make test:pg`, or point `TEST_PG_DSN` at a reachable database.
- **Contract gate fails** — a handler/spec drifted; align `api/openapi.yaml` and the contract lists per Best Practices.
- **Lint `unused` on a helper** — helpers exist for upcoming API tests; keep them referenced by at least one test. Delete a helper together with its last usage.
