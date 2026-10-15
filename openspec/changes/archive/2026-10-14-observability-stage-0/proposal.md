# Observability Stage 0 — be alive, be notified, stop flying blind

## Why

The relay backend runs on a single e2-micro VM with JSON logs that die with the
container, no uptime watch, no crash reporting on iOS, and no alert routing.
Every recent incident (Supabase repoint crash-loop, pooler misconfiguration) was
discovered by a human staring at logs. Stage 0 buys "is it alive + what crashed"
in days, with zero architecture lock-in, before the real pipeline (Stage 1) lands.

## What changes

- **External /health watch**: Healthchecks.io free tier (dead-man's-switch:
  a VM cron pings on every healthy minute, missed pings page Telegram via the
  native integration); the watchdog brain lives off-box, never on the VM.
- **Docker log rotation**: `max-size`/`max-file` on all compose services so the
  10 GB VM disk cannot fill from unbounded json-file logs.
- **Quiet /health**: exclude the uptime ping from request access logs (keep a
  counter instead) to protect future log quota.
- **Sentry pillar**: Go SDK in the backend + Sentry SDK in the iOS app, DSNs via
  env/secrets only, dSYM upload wired into `ios.yml`. Sentry is both the
  Stage-0 crash reporter and the Stage-1 errors pillar (same SDK self-hosts
  later — DSN flip only).
- **One Telegram channel**: deploy results, ping failures, and tripwire alerts
  land here. Interrupt-vs-digest routing rule documented (see design.md).
- **Tripwire table**: quota guards for every free tier in use (Sentry events,
  future Grafana Cloud series/logs, Supabase 500 MB — already specced).

## Scope

Stage 0 ONLY. Explicitly out: OTel Collector, OTel SDKs, Grafana dashboards,
SLO numbers, MetricKit pipeline, log shippers. Those are Stage 1
(tracked as a GitHub issue referencing this change's design.md).

## Constraints (from exploration)

- $0: free tiers only, no card-where-possible, spending caps where a card exists.
- Monitoring storage never lives on the app VM (forwarding may; storage may not).
- No PII in telemetry: identifiers in payloads, aggregates in labels (R1).
- iOS strings (if any user-facing text is added) go to both `en`/`ru` + `L10n`.
