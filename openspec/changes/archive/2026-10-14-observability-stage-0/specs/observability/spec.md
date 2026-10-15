# Observability (Stage 0) — delta

## ADDED Requirements

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
