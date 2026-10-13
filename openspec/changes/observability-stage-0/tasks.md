# Tasks — Observability Stage 0

## 1. Off-box uptime watch

- [x] 1.1 Pick free-tier ping (UptimeRobot or BetterStack): 1-min `/health`
  checks, alert after 3 consecutive failures.
  (DECIDED 2026-10-13: Healthchecks.io — native Telegram, dead-man's-switch;
  check created user-side, cron pinger installs from `HC_PING_URL` secret on
  deploy. BetterStack dropped: no native Telegram, relay would live on the
  watched VM. UptimeRobot dropped: no Telegram + 5-min free polls.)
- [ ] 1.2 Create Telegram channel + bot; ping failures route here (sound on).
- [ ] 1.3 Verify: stop backend on VM, confirm alert arrives; restart, confirm
  recovery notice.

## 2. VM log hygiene

- [x] 2.1 Add `max-size`/`max-file` rotation to all `docker-compose.prod.yml`
  services; deploy and verify bounded growth.
  (DONE code: json-file 10m×3 on postgres/backend/nginx; deploy-verify pending with 5.2.)
- [x] 2.2 Exclude `/health` from request access logs (counter instead);
  verify ping traffic no longer logs lines.
  (DONE code + `TestHealthExcludedFromAccessLogs`; live-verify pending with 5.2.)

## 3. Sentry pillar

- [x] 3.1 Backend: add Sentry Go SDK (env `SENTRY_DSN`, empty = disabled);
  panics + 5xx with context; no PII in tags (allowlist applies).
  (DONE: `sentry-go v0.45.1` — NOT v0.50.0: v0.46+ requires Go 1.25 but the
  repo toolchain is pinned to Go 1.24 (CI `setup-go 1.24`); v0.50.0 broke CI
  with `no such tool "covdata"` under `-race -coverprofile`. `go.mod` stays
  `go 1.24.0`, x/* deps re-pinned to main's versions. Lesson: new Go deps must
  declare `go < repo toolchain` or the toolchain bump becomes its own change.)
  7 tests green; needs `SENTRY_DSN` secret value — user-side, see 3.4.)
- [x] 3.2 iOS: add Sentry SDK via SPM; crashes + backend-bridged errors;
  verify a test crash from a staging build arrives symbolicated.
  (DONE code: sentry-cocoa 8.58.4, `SentryReporter`, user-id-only context,
  distress breadcrumbs; build + 662 tests green; live crash arrival needs
  `SENTRY_IOS_DSN` — user-side, verified in 5.2 drill.)
- [x] 3.3 CI: dSYM upload wired into `ios.yml` (staging + release).
  (DONE: `sentry-dsym` job, skips gracefully without secrets; needs
  `SENTRY_AUTH_TOKEN`/`SENTRY_ORG`/`SENTRY_PROJECT_*` — user-side.)
- [x] 3.4 Secrets: DSNs in GitHub `stage` env secrets / VM `.env` only;
  never in chat or committed files.
  (DONE plumbing: `backend.yml` renders `SENTRY_DSN` into VM `.env`,
  `.env.example` documents it, iOS uses `SENTRY_IOS_DSN` build setting;
  secret VALUES pending user-side account setup.)

## 4. Routing + tripwires on paper

- [x] 4.1 Document interrupt-vs-digest routing + anti-fatigue ratchet
  (demote anything paging > 2×/month) in `docs/project-context.md`.
- [x] 4.2 Tripwire table (Sentry quota 70/90%, future Grafana quotas,
  Supabase 500 MB) with shed-load actions; wire 70% alerts to Telegram.
  (DONE on paper; Telegram wiring pending task 1.2.)
- [x] 4.3 Daily digest contents defined (uptime %, Sentry count, DB size).

## 5. Verification + close-out

- [x] 5.1 `backend.yml` + `ios.yml` green; linters strict-clean.
  (DONE 2026-10-13: backend lint-and-test pass, openspec validate pass,
  Xcode Cloud Build + Test pass on PR #151.)
- [ ] 5.2 End-to-end drill: failing /health → Telegram in < 5 min;
  test crash → Sentry issue with symbols.
- [x] 5.3 Stage 1 GitHub issue exists and references this change's design.md.
  (DONE: issue #150, body references design.md — verified via gh API.)
