# CI Pipeline Guide

Split-provider quality pipeline for Lifio. Mandatory PR checks (Requirements S6) come from two providers:

- **GitHub Actions** — `backend.yml` (Go), `openspec.yml` (spec gate), `release.yml` (manual version bump + `verify`), advisory `ai-review.yml`
- **Xcode Cloud** — iOS PR checks: `xcodegen` → `swiftlint --strict` → warnings-as-errors build → unit tests (replaces the old `ios.yml` PR/push triggers; see below)

GitHub workflows and their scope:

- **`backend.yml`** — Go: gofmt, go vet, golangci-lint, race tests, OpenAPI contract gate, coverage gate, deploy
- **`ios.yml`** — release verification ONLY (`workflow_call` from `release.yml: verify`; no `pull_request`/`push` triggers — PR verification lives in Xcode Cloud). Same steps as Cloud: xcodegen, swiftlint `--strict`, warnings-as-errors build, unit tests. Intentional residue: one macOS run per release.
- **`openspec.yml`** — spec-integrity gate: `openspec validate --all --strict` (CLI pinned 1.8.0) on every PR and push to `main`
- **`release.yml`** — manual `workflow_dispatch` marketing-version bump: validates semver on `main`, bumps every target's versions in `project.yml` in lockstep, mirrors every Release `Info.plist`, commits + tags `vX.Y.Z` (see checklist below — a new target MUST be wired in or the next release fails)

## Xcode Cloud — iOS PR checks

| Setting | Value |
|---|---|
| Workflow | PR-checks workflow in App Store Connect (UI-managed; `ci_scripts/` + this doc are the reviewed source of truth) |
| Start conditions | Pull Request Changes (target `main`) + Branch Changes (`main`) |
| File filters | `ios/**` (mirrors the old `on: pull_request paths:` — `backend/`-only PRs burn no Cloud hours) |
| Scheme / config | `TimeOfLife`, Debug, iOS Simulator destination, `OS=latest` (never Release signing on PR builds) |
| Post-clone | `ios/TimeOfLife/ci_scripts/ci_post_clone.sh` — brew-install `xcodegen`, fail-closed `XCODEGEN_PIN` assert, `xcodegen generate` (fires `postGenCommand normalize-system-capabilities.py`), `.xcodeproj` existence check |
| Pre-build | `ios/TimeOfLife/ci_scripts/ci_pre_xcodebuild.sh` — brew-install `swiftlint`, fail-closed `SWIFTLINT_PIN` assert, `swiftlint lint --strict` (also gates tag archives; no-op there since tags build from lint-green `main`). Resolves the project dir via the `.swiftlint.yml` marker (Test VMs replay the script from clone-root, not its repo location) and skips cleanly when no iOS sources are present — the Build action already gated lint |
| Post-build | `ios/TimeOfLife/ci_scripts/ci_post_xcodebuild.sh` — Sentry dSYM upload for Cloud-built archives (App Store Connect offers no downloadable dSYMs since Xcode 14, so the builder pushes). Skips quietly without an archive (PR checks) or without secrets; upload failures warn but never fail the archive (the GitHub `sentry-dsym` job stays the loud gate for local archives) |
| Logs | App Store Connect build page (replaces `xcpretty` GH logs); link the build in the PR when reporting iOS failures |

### Xcode Cloud workflow env vars (Sentry; Archiving workflow only)

| Variable | Value | Secret? |
|---|---|---|
| `SENTRY_DSN` | iOS DSN (same value as the `SENTRY_IOS_DSN` GitHub secret) | yes — flows into the built Info.plist via the `SENTRY_DSN = $(SENTRY_DSN)` xcconfig self-reference |
| `SENTRY_AUTH_TOKEN` | token with Project write (debug files) | yes — consumed by `ci_post_xcodebuild.sh` |
| `SENTRY_ORG` | org slug | no |
| `SENTRY_PROJECT` | project slug for this workflow's builds (staging) | no |

Toolchain pins (bump together with the local toolchain; version-skew failures are fixed by pinning, never by relaxing `--strict` or per-target warnings-as-errors):

| Tool | Pinned | Local (2026-10-12) |
|---|---|---|
| `xcodegen` | `2.46.0` (`XCODEGEN_PIN` in `ci_post_clone.sh`) | 2.46.0 |
| `swiftlint` | `0.65.1` (`SWIFTLINT_PIN` in `ci_pre_xcodebuild.sh`) | 0.65.1 |
| Xcode (Cloud selection) | nearest 27.x | 27.0 (27A266a) |

Cloud usage is metered in App Store Connect (Users and Access → Xcode Cloud tab; per-app tab; CSV export). The account holds 25 compute-hours/mo free — the Oct 2026 baseline (~11 GH iOS runs/day × ~7.7 min wall ≈ 1.4h wall/day) fits inside it; a paid tier is a separate future decision, not this change.

Plus the **advisory, on-demand** stage-1 AI review (`ai-review.yml`, OpenCodeReview on Ollama Cloud's `deepseek-v4.1-flash`; trigger: comment `/review` on a PR) — see `docs/review-process.md`; it posts review comments but never blocks.

## New-target checklist (extensions, widgets, watch apps)

Adding an Xcode target with its own `info.properties` versions or `Info.plist` (e.g. the `LifioLiveActivities` widget extension, which broke the `0.2.1` release with a duplicate-key guard failure) MUST update the pipelines in the same PR:

1. **`release.yml`** — add the target's Release `Info.plist` to `RELEASE_PLISTS` in the Bump step (the single source of truth — "Commit and push" consumes it via step outputs); keep its `CFBundleShortVersionString`/`CFBundleVersion` in `project.yml` equal to the app's (App Store rejects skewed bundles). A target with a *generated* plist (`GENERATE_INFOPLIST_FILE: YES`, e.g. the `LifioLiveActivityCore` framework) has no plist to mirror — wire `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` build settings instead (missing keys fail App Store validation with ITMS-90057); the workflow bumps them in lockstep. Debug (`Info-Debug.plist`, unmanaged) stays pinned — release bumps never touch it.
2. **`ios.yml` / Cloud scheme** — confirm the `TimeOfLife` scheme builds/tests cover the new target (the `verify` job in `release.yml` reuses `ios.yml` via `workflow_call`, and the Cloud PR-checks workflow builds the same scheme, so gaps weaken both release verification and every PR).
3. **Path filters** — if the target introduces a new top-level directory, extend the `on:` path filters of every affected GitHub workflow AND the Cloud workflow's file filters so PRs touching it still trigger CI.

## Stages (`backend.yml`)

| Stage | Trigger | What runs |
|---|---|---|
| `lint-and-test` | Backend PR + backend push to `main` + manual dispatch | gofmt, vet, golangci-lint, `go test ./... -race -coverprofile`, coverage gate (floor 45%, ratchets up) |
| `deploy` | Backend push to `main` + manual dispatch | requires `lint-and-test` green; builds/pushes the image and deploys to the selected environment |

The OpenAPI contract gate runs inside `go test ./...` (`internal/contract/openapi_test.go`) — a spec/handler drift fails every PR automatically.

## Running CI locally

The Makefile exposes the CI checks plus optional local diagnostics:

```bash
cd backend
make lint          # gofmt + vet + golangci-lint  (matches CI lint stage)
make test:race     # go test ./... -race          (matches CI test step)
make test:pg       # Optional PostgreSQL parity    (needs Docker; not currently a CI job)
make test:cover    # coverage + per-function report
```

## Secrets checklist

Required GitHub Actions secrets (configured in repo Settings → Secrets and variables → Actions):

| Secret | Used by | Required |
|---|---|---|
| `OLLAMA_API_KEY` | ai-review (stage-1 review, Ollama Cloud) | ✅ |
| `VM_HOST` | deploy | ✅ |
| `VM_USER` | deploy | ✅ |
| `VM_SSH_KEY` | deploy | ✅ |
| `DB_PASSWORD` | deploy | ✅ |
| `JWT_SECRET` | deploy | ✅ (≥32 bytes) |
| `AWS_ACCESS_KEY_ID` | deploy (EMAIL_BACKEND=ses) | only when SES |
| `AWS_SECRET_ACCESS_KEY` | deploy (EMAIL_BACKEND=ses) | only when SES |
| `APPLE_CLIENT_ID` | deploy (optional feature) | only when Apple enabled |
| `SENTRY_AUTH_TOKEN` | ios.yml sentry-dsym (dSYM upload auth) | only when Sentry wired; absent = upload skips with a warning |
| `SENTRY_ORG` | ios.yml sentry-dsym (Sentry org slug) | only when Sentry wired; absent = upload skips with a warning |
| `SENTRY_PROJECT_STAGING` | ios.yml sentry-dsym (staging project slug) | only when Sentry wired; absent = staging upload skips |
| `SENTRY_PROJECT_RELEASE` | ios.yml sentry-dsym (release project slug) | only when Sentry wired; absent = release upload skips |
| `SENTRY_IOS_DSN` | ios.yml sentry-dsym (threaded into the archive as `SENTRY_DSN`) | only when Sentry wired; absent = archived binary ships with the SDK disabled |
| `SENTRY_DSN` | backend deploy (rendered into VM `.env`; empty = SDK disabled) | only when Sentry wired; absent = backend ships with reporting off |
| `HC_PING_URL` | backend deploy (installs the every-minute dead-man's-switch cron pinger) | only when Healthchecks wired; absent = install skips with a warning |

Non-secret variables: `EMAIL_BACKEND`, `AWS_REGION`, `SES_FROM` (set as repository variables).

## Troubleshooting

- **PostgreSQL behavior needs verification** — run `make test:pg` locally after starting PostgreSQL; parity is not currently a CI job.
- **Coverage gate fails** — total coverage dropped below the floor; add/keep tests. Raise the floor in `backend.yml` as coverage grows.
- **Workflow not triggering** — workflow file paths must match the `on:` path filters (`backend/**`, `.github/workflows/backend.yml`); for iOS, the PR must touch `ios/**` or the Cloud file filter skips it by design.
- **Cloud build fails on version assert** (`expected XCODEGEN_PIN/SWIFTLINT_PIN`) — Homebrew drifted: confirm the new version locally (`xcodegen generate` diff clean + `swiftlint lint --strict` green), then bump the pin in `ci_scripts/` and the pin table above in the same PR.
- **Cloud status check missing on a PR** — the App Store Connect ↔ GitHub connection needs Checks/Statuses write permission; verify the workflow's start conditions still target `main` and the PR's base is `main`.
- **AI review missing after /review** — check the `OLLAMA_API_KEY` secret exists (Ollama Cloud key from ollama.com → Settings → Keys) and the job didn't skip (the comment must be on a PR, contain `/review`, and not come from a bot). Rules/tuning per `docs/review-process.md` and `.opencodereview/rule.json`.
