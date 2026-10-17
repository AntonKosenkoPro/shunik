## Why

Sentry received three fresh `lifio-backend` issues (`LIFIO-BACKEND-1..3`: `POST /auth/refresh`, `GET /auth/me`, `GET /categories` → 500) that are
untriageable: message-only events, no stacktrace, no breadcrumbs, no spans/logs, Seer actionability `super_low`. Root cause: the Stage-0
middleware (`internal/server/sentry.go`) only sees the final status code, so it reports `server error: <method> <route> -> <status>` via
`CaptureMessage` — the underlying store error (logged server-side by `slog`, e.g. `list categories failed`) never reaches Sentry. The two
same-second issues (`/auth/me` + `/categories`, shared trace) strongly suggest one common dependency failure, but the payload cannot prove it.
The `observability` baseline mandates backend 5xx in Sentry with route + status-class context; this change keeps that contract and adds the
missing error string + per-op fingerprinting so same-cause failures group and different-cause failures do not collapse.

## What Changes

- New leaf package `internal/observe` holding the Sentry core moved out of `internal/server` (init/flush/enabled flag, middleware, tags, scrub,
  route-template helpers) plus a new `ReportError(r, op, err)` for handled 500s. The move breaks the `handlers → server` import cycle so
  handlers can report the error they already hold; `server` keeps no Sentry code of its own.
- New `Handler.writeInternalError(w, r, op, err)` helper: reports via `observe`, logs via `slog` as today, writes the existing generic
  `{code: internal_error}` envelope. All 14 handled-500 sites (auth ×9, catalog ×3 incl. the `writeCatalogStoreErr` default branch, entries ×2)
  route through it. Client responses are byte-identical; user-enumeration posture unchanged.
- `ReportError` attaches route template, op tag, `5xx` status class, the error string as context, and fingerprint `{{ default }}, <op>`.
  BeforeSend scrub and the no-PII tag allowlist are unchanged.
- Tests: moved Sentry suite to `observe` (+ fake-`Transport` test asserting tags/fingerprint/error context on `ReportError`); new handlers test
  proving a store failure still returns the generic 500 envelope with and without Sentry enabled.

## Capabilities

### New Capabilities

(none — enriches the existing `observability` capability.)

### Modified Capabilities

- `observability`: backend handled-500s now arrive in Sentry with the store error string + per-op fingerprint; panics unchanged (stack + request
  context via repanic middleware); empty `SENTRY_DSN` still disables everything without breaking the server (baseline scenario, spec untouched).

## Impact

- New `backend/internal/observe/`; deleted `backend/internal/server/sentry.go` (+ test moved); `server.go` + `cmd/server/main.go` call sites
  repointed (`observe.InitSentry` et al., same names); `internal/handlers/{auth,catalog,entries}.go` 500 sites unified.
- No OpenAPI change (envelopes unchanged), no config/env/compose/workflow change, no iOS change, no on-disk format change.

## Non-goals

- Root-causing the three historical thin issues from Sentry alone (impossible — payloads predate this change; needs prod container logs, human step).
- iOS Sentry SDK, uptime watch, log rotation, quiet-health (other `observability` requirements — separate).
- Traces/performance monitoring (`EnableTracing` stays off), OTel/dashboards/SLOs (Stage 1).
- PII expansion: route templates only (never raw paths/IDs), op, error string — no emails, tokens, bodies, entry text (scrub backstop unchanged).

## External docs

- ctx7 `/getsentry/sentry-go` — queries: "initializing SDK via DSN from environment and Flush on shutdown", "net http middleware panic recovery
  request context sentryhttp", "manually capturing handled errors with extra context SetContext tags fingerprint", "testing with mock transport"
  (weak hit → hand-written fake `Transport` per `go doc Transport`: `Flush`/`FlushWithContext`/`Configure`/`SendEvent`/`Close`). Gotchas applied:
  per-request Hub clone (never global capture in handlers), `Flush` bounded to fit compose stop grace, empty DSN = silent noop.
- HIG N/A — backend-only diff, no UI. Apple API N/A — no Apple SDK involved.

## Affected baselines

- `observability` ("Crash and error reporting via Sentry" — enriched, spec untouched).
