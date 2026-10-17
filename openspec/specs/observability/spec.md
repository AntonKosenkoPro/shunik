# Observability Specification

## Purpose

The Stage-0 observability contract: the staging deployment is watched by an off-box uptime ping, container logs stay bounded and quiet for health traffic, and backend panics/5xx plus iOS crashes arrive in Sentry with symbols and without PII. Heavier telemetry (OTel pipeline, dashboards, SLOs) is Stage 1.

## Requirements

### Requirement: Off-box uptime watch

The staging deployment MUST be watched by an external uptime ping that lives
off the app VM, alerting after consecutive `/health` failures.

#### Scenario: backend stops, alert arrives

- GIVEN the backend container is down on the VM
- WHEN three consecutive 1-minute `/health` checks fail
- THEN an alert arrives in the Telegram channel within 5 minutes
- AND a recovery notice arrives after the backend returns.

### Requirement: Bounded VM log retention

All compose services MUST rotate container logs so VM disk usage stays bounded.

#### Scenario: sustained traffic, disk stays bounded

- GIVEN a week of staging traffic including uptime pings
- WHEN container log files reach `max-size`
- THEN the oldest file rotates out and total log disk stays under the
  configured cap.

### Requirement: Quiet health endpoint

Uptime-ping traffic MUST NOT emit per-request access log lines.

#### Scenario: ping arrives, no log line

- GIVEN the uptime monitor pings `/health`
- WHEN the request is served 200
- THEN no access-log line is written for it
- AND the health-check counter increments instead.

### Requirement: Crash and error reporting via Sentry

Backend panics/5xx and iOS crashes MUST arrive in Sentry with symbols and
without PII in tags.

#### Scenario: staging crash, symbolicated issue

- GIVEN a staging iOS build with the Sentry SDK
- WHEN the app crashes
- THEN a Sentry issue appears with symbolicated stack
- AND no tag carries user identifiers, entry text, or tokens.

#### Scenario: backend panic, context attached

- GIVEN the backend with `SENTRY_DSN` set
- WHEN a handler panics
- THEN Sentry captures it with route template + status class context
- AND an empty `SENTRY_DSN` disables reporting without breaking the server.

### Requirement: Handled backend 500s carry the underlying error

Every handled `internal_error` 500 MUST report to Sentry (when enabled) with the route template, the operation name, the `5xx` status class, and the underlying error string. The HTTP response MUST stay the generic envelope (no error internals leak to clients).

#### Scenario: store failure on an authed route

- GIVEN `SENTRY_DSN` is set
- WHEN `GET /api/v1/categories` fails in the store
- THEN one Sentry event arrives with route template `/api/v1/categories`, the operation name, and that error string
- AND the client still receives `{error: {code: internal_error}}` with status 500.

### Requirement: Same-operation failures group together

Handled-500 events MUST fingerprint on the operation so repeats of one failing operation group into one issue while different operations stay separate issues.

#### Scenario: shared dependency outage

- GIVEN `SENTRY_DSN` is set
- WHEN `GET /api/v1/auth/me` and `GET /api/v1/categories` fail together with different errors
- THEN two issues appear (one per operation), each carrying its own error string.

### Requirement: Client-disconnect 500s stay out of Sentry

A handled 500 whose error (or request context) is `context.Canceled` MUST NOT report to Sentry: the requester went away mid-flight, so there is no server fault. The `slog` line remains the record. `context.DeadlineExceeded` still reports — saturation is actionable.

#### Scenario: app abandons requests mid-flight

- GIVEN `SENTRY_DSN` is set
- WHEN requests fail only with `context canceled` (client disconnected)
- THEN no Sentry events arrive for them
- AND the client responses and server log lines are unchanged.

### Requirement: No PII in enriched error payloads

Sentry tags and error contexts MUST NOT carry user identifiers, emails, entry text, tokens, or request bodies — only route templates, operation names, status class, and bounded store error strings (truncated, valid UTF-8).

#### Scenario: 500 on a user-specific route

- GIVEN `SENTRY_DSN` is set
- WHEN `GET /api/v1/auth/me` fails for a user
- THEN the Sentry event contains no user id, no email, and no token material.
