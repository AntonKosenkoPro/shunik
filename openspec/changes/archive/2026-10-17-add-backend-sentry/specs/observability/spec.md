# Observability — add-backend-sentry delta

## ADDED Requirements

### Requirement: Handled 500s carry the underlying error

Every handled `internal_error` 500 MUST report to Sentry (when enabled) with the route template, the operation name, the `5xx` status class,
and the underlying error string. The HTTP response MUST stay the generic envelope (no error internals leak to clients).

#### Scenario: store failure on an authed route

- GIVEN `SENTRY_DSN` is set
- WHEN `GET /api/v1/categories` fails in the store with `dial tcp: connection refused`
- THEN one Sentry event arrives with route template `/api/v1/categories`, op `list categories`, and that error string
- AND the client still receives `{error: {code: internal_error}}` with status 500.

### Requirement: Same-op failures group, cross-op failures do not collapse

Handled-500 events MUST fingerprint on the operation (`{{ default }}, <op>`) so repeats of one failing operation group into one issue while
different operations stay separate issues.

#### Scenario: shared dependency outage

- GIVEN `SENTRY_DSN` is set
- WHEN `GET /api/v1/auth/me` and `GET /api/v1/categories` 500 together (as in LIFIO-BACKEND-2/3)
- THEN two issues appear (ops `get user` and `list categories`), each carrying its own error string, instead of one shape-only message each.

### Requirement: Client-disconnect 500s stay out of Sentry

A handled 500 whose error (or request context) is `context.Canceled` MUST NOT report to Sentry: the requester went away mid-flight (nginx logs
499), so there is no server fault. The `slog` line remains the record. `context.DeadlineExceeded` still reports — saturation is actionable.

#### Scenario: app abandons a refresh, then a sync pair

- GIVEN `SENTRY_DSN` is set
- WHEN `POST /api/v1/auth/refresh` and later `GET /api/v1/auth/me` + `GET /api/v1/categories` fail only with `context canceled`
  (the LIFIO-BACKEND-1..3 shape)
- THEN no Sentry events arrive for them
- AND the client responses and server log lines are unchanged.

### Requirement: No PII in the enriched payload

The added error-string context MUST NOT introduce user identifiers, emails, entry text, tokens, or request bodies; route tags stay templated
and the BeforeSend scrub backstop stays in place.

#### Scenario: 500 on a user-specific route

- GIVEN `SENTRY_DSN` is set
- WHEN `GET /api/v1/auth/me` 500s for user `u-123` with a store error mentioning only constraint names
- THEN the Sentry event contains no `u-123`, no email, and no token material.
