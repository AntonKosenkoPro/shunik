# Design — observability direction (Stage 0 + Stage 1)

This design records the decisions from exploration so Stage 1 stays portable.
Stage 0 implements only the proposal.md slice; everything else is direction.

## Pillars

```
Sentry (errors + crashes, SaaS free now → self-hosted later, same SDK)
OTel pipeline (metrics + traces + logs → Collector seam → SaaS now → ELK later)
Off-box ping (uptime, always external)
```

## The seam

Apps emit OTLP to an OTel Collector we control. Migration day = change the
Collector's exporter address; no app deploys, no SDK swaps. Same-VM is
acceptable for the Collector (forwarding with seconds of buffer) and never
acceptable for storage (history must survive the box dying).

## Label allowlist (metrics + Loki labels)

`service.name`, `service.version`, `environment`, `http.method`,
`http.route` (**templated** — `{id}`, never raw UUIDs), `http.status_class`
(2xx/4xx/5xx), `operation` (`sync_push`, `otp_verify`, …).

Identifiers (`user_id`, `device_id`), route params, category names, entry text,
emails, tokens ride **inside payloads** (span attributes, log lines) — never in
labels. Identifiers-in-payloads doubles as the privacy rule. Loki labels ≈ 5,
boring. ES later: strict dynamic mapping / templates with `ignore_above`.

Guardrail (Stage 1): CI check failing on unknown labels; chi route templating
configured in the OTel middleware (one-line config, million-series consequences).

## Log pipeline

```
app logs (slog) ──OTel bridge──▶ Collector ──▶ SaaS Loki ──▶ ES later
infra (nginx/pg/sys) ──shipper──▶ same Collector (or direct) ──▶ same
panics/crash-loops ──shipper (catches what OTel can't emit)
```

Trace correlation (`trace_id` on every record) is the reason app logs go OTel
rather than file-tail. Overlap rule: shipper covers infra + app stderr/panics;
OTel covers app stdout. `/health` excluded from access logs everywhere.

## iOS telemetry (Stage 1)

Session-level spans, not event-level: one `sync.session` span per sync
(outcome, offline_duration_s, pushed/pulled/conflict counts, outbox depth
before/after). Distress signals (crashes, N consecutive sync failures, store
open failures) travel a separate channel from volume telemetry — piggybacking
on `/v1/sync` is fine for volume, fatal for distress (correlated blindness:
telemetry fails exactly when the API fails). Buffer-and-forward on-device;
telemetry must cost less than the feature it observes.

## Tripwires (70% alert → 90% shed load → 100% migrate)

| Tier | 70% | 90% shed |
|---|---|---|
| Sentry events/mo | Telegram ping | errors-only, drop breadcrumbs/perf |
| Grafana series (10k) | Telegram ping | cut `operation`, coarsen status |
| Grafana logs GB | Telegram ping | retention 30→7d, drop DEBUG |
| Supabase 500 MB | already specced | already specced |

## Alert routing (solo-dev, anti-fatigue)

INTERRUPT: /health failing 3×, Sentry NEW issue type, Supabase 350 MB,
VM disk > 80%. DIGEST (morning): deploy results, 70% tripwires, daily
uptime/error/DB-size numbers, weekly quota trend. Anything interrupting more
than twice a month gets demoted.

## Stage 2 note (not planned, just priced)

Self-hosted ELK (+ Sentry) gets its **own box** — ELK's JVM appetite would eat
the e2-micro. Dashboards do NOT migrate (Grafana ≠ Kibana): keep Stage-1
dashboards ≤ ~5, built from stable semantic attributes, so the rebuild is
bounded. Alert intent lives in repo-kept files, not SaaS click-ops.
