# AGENTS.md

Agent entrypoint for this repo. **Read [`docs/project-context.md`](docs/project-context.md) first** — it holds the durable, accurate architecture and context (S7). This file only orients you and enforces the non-negotiables; it is deliberately short.

## What this is

**Lifio** — a personal time-tracking iOS app (SwiftUI, iOS 18+, local-first **account-bound**: mandatory sign-in, per-account data files, per-device sessions) with a Go backend acting as **identity + sync relay**. Current scope: auth MVP (passwordless email-OTP + Sign in with Apple) and the Track experience (three-tab shell, numeric timer, plain-text capture + Recents, running tag selector, Profile, compact cross-tab timer). There is no activity entity — entries own their text, ordered categories, and notes.

## OpenSpec routing (read this before touching behavior)

The repo is spec-driven (`openspec/config.yaml`, `schema: spec-driven`). See `openspec/README.md` for the workflow; the essentials:

- **Baseline specs** (`openspec/specs/<capability>/spec.md`): current contract (20 baselines incl. `app-shell`, `timer-capture-experience`, `apple-signin`, `live-activities`). Never edit directly — behavior changes go through a change.
- **Active deltas**: none — umbrella archive of 8 changes (`separate-notes-editor`, `extend-notes-limit`, `fix-sync-entry-truncation`, `fix-track-empty-after-reinstall`, `fix-track-visual-glitches`, `fix-tab-bar-return-jump`, `category-chip-order-numbers`, `live-activities`) landed 2026-10-10 and folded into the baselines. Check `openspec list` before starting new behavior work.
- **Archives** (`openspec/changes/archive/`): history (e.g. `redesign-track-experience`); their deltas are already folded into the baselines.

## Non-negotiables

- **LocalStore is the single mutation chokepoint** (GRDB in App Group `group.com.antonkosenko.timeoflifeapp`) — no raw GRDB writes outside it.
- **Incomplete UI surfaces — do not claim they are done**: UndoToast/shake-to-undo, "via <Source>" labels, and the iOS 18 lock-screen ControlWidget itself (a widget extension target exists for Live Activities; the Control toggle is still deferred). Device quota + picker (#46) is a pre-release blocker. Full list: `docs/project-context.md` → "Incomplete / deferred".
- **OpenAPI is the authoritative API contract** (`backend/api/openapi.yaml`, S10). Endpoint changes update both sides + the spec.
- **External docs first (ctx7)**: before implementing anything that depends on external library/framework/SDK/API/CLI/cloud-service behavior, fetch current docs via `npx ctx7@latest library` → `docs` and cite library ID + query in proposal/design; never rely on training data alone. Procedure: `docs/project-context.md` → "External docs first (ctx7)".
- **No backward compat for on-disk formats** (pre-release): edit `Codable` shapes in place, no legacy branches.
- **No passwords, no plaintext secrets** (R1); tokens in Keychain only; user-enumeration closed (`otp/request` always 202).
- **iOS strings** go to both `en.lproj` and `ru.lproj` + `L10n` (U4).
- **XcodeGen-managed** — edit `project.yml`, run `xcodegen generate`; never hand-edit the `.pbxproj`.
- **Signing is per-config**: Debug unsigned (simulator/CI), Release signed with team `7923U48U87` (SIWA entitlement live; backend needs `APPLE_CLIENT_ID`). Manual smoke checklist: `README.md`.
- **SwiftUI views use `Theme` semantic colors only**; no raw `Color` literals.
- **No binaries in git without explicit user permission** — never commit screenshots, videos, IPAs, xcresults, or other binaries (including OpenSpec evidence); keep captures in `/tmp` or attach them directly.

## Agent attribution (issue #161, forward-only from 2026-10-15)

Every agent commit and every agent-authored GitHub entity (PR, issue, comment, review reply) carries the marker `opencode/<role> (<model>, ses_<id>)`. Role from `opencode.json` agent names else `main`; model short id when known else omitted; session short id else `YYYY-MM-DD`.
- **Commits**: human stays Author/Committer; append a `Co-Authored-By: opencode/<role> (<model>, ses_<id>) <opencode@local>` footer. Visible in `log`/`show`/commit page, never in `blame` — query via `git log --grep`.
- **PRs/issues/comments**: append `> Agent: opencode/<role> · <model> · ses_<id>` plus `<!-- lifio-agent: <role>/<model>/ses_<id> -->`. `/review` triggers keep `/review` on the first line (the workflow matches `contains`). No second GitHub identity, no branch-namespace change, no history rewrite. Rationale: `openspec/changes/agent-attribution/`.

## Repo layout (short)

```
backend/                 Go (chi + pgx/Postgres; sqlite for tests) — relay: auth + categories/entries
ios/TimeOfLife/          SwiftUI app (iOS 18+), XcodeGen-managed
  TimeOfLife/Features/{Auth,AppShell,TimeTracking,Catalog,Sync,AppleSignIn}
  TimeOfLife/Core/Storage/   LocalStore.swift (GRDB), UndoBufferStore.swift, SessionCache.swift
  TimeOfLife/Core/           networking, keychain, reachability, theme, navigation, DI, components
docs/                    project-context.md (canonical context), ci.md, ios-test-loop.md (fast xcodebuild loop)
openspec/                specs + changes (see above)
Requirements/FURPS/      FURPS+ table (Common.md, Timetracking.md, Sign-up_and_Sign-in.md, Activity_Catalog_and_Categories.md)
Design/                  text design system — see Design/README.md
.github/workflows/       backend.yml + openspec.yml (mandatory GH checks) + Xcode Cloud `iOS PR Checks` (mandatory iOS checks), release.yml (manual version bump — multi-target, see ci.md checklist when adding a target), ai-review.yml (advisory stage-1 review — docs/review-process.md)
```

## Build, test, run

### Backend (Go 1.24) — from `backend/`
```bash
go build ./...
go test ./... -cover            # tests use SQLite — no Docker needed
golangci-lint run && gofmt -l . && go vet ./...
docker-compose up -d postgres && cp .env.example .env && go run ./cmd/server
```

### iOS (Xcode 16+, xcodegen, swiftlint) — from `ios/TimeOfLife/`
```bash
xcodegen generate
swiftlint lint --strict         # --fix autocorrects
xcodebuild -scheme TimeOfLife -destination 'generic/platform=iOS Simulator' build
```

## Required on every iteration (S5)

1. Linters + build green; app/test target warnings are errors via `project.yml`; `gofmt -l .` empty.
2. Both test suites green (`go test ./...`; `xcodebuild test -scheme TimeOfLife -destination '<available simulator>'` — agent loop rules + timings: `docs/ios-test-loop.md`).
3. Re-check the relevant `Requirements/FURPS/*.md` rows; fix conflicts.
4. Update docs if architecture/contract/run steps or visual design changed: `docs/project-context.md`, `README.md`, `openspec/` artifacts + `openspec/config.yaml` guidance, relevant `Design/*.md` (new component → `COMPONENTS.md` first; new/changed screen → `SCREENS/<Screen>.md` + re-check its Implementation checklist — see `Design/README.md`), `backend/api/openapi.yaml`. Keep `AGENTS.md` short — point to `docs/project-context.md`.
5. Prefer existing utilities; remove dead code.
6. Reproduce bugs before fixing and re-verify after: no implementation without a recorded repro on the current tree — rule: `docs/project-context.md` → "Per-iteration revising process".

## Flow recommendations

- Plan every not obvious task (that will consume over 100k tokens per session)
- Isolate code work in a separated git worktree (`timeOfLife.wt/<change-name>`, one branch per worktree, created from fresh `origin/main`); the main checkout stays clean — move the session into the worktree (`session_move`) and remove it after archive. Read-only explore stays worktree-free. Worktrees do not lift the serialization rules below.
- Rebase twice on `origin/main`: `git fetch origin` + rebase before implementing and again before opening the PR; re-run affected linters/tests after each rebase; pushed branches move via `push --force-with-lease`; never `merge main` into a feature/bugfix branch.
- Research bundle first for every feature/bugfix (topic + applicable HIG + Apple API + best practice via ctx7, max 5, cites or waiver reasons) — rule: `docs/project-context.md` → "External docs first (ctx7)".
- Parallelism budget (OpenCode Zen Muse Spark 1.3 Free: ~9–10 concurrent slots measured; local work overlaps the queue): default fan-out **6 agents**, hard ceiling **9**; explore-only work stays at **3**
- Delegate FIRST via the Task tool — no sequential fallback: any task touching 2+ of backend (`backend/`) / iOS (`ios/TimeOfLife/`) / specs-docs (`openspec/`, `docs/`, `Requirements/`, `Design/`) MUST fan out with one Task call per area in a single message before doing the work yourself; merge results yourself
- Subagent depth is **3** (`subagent_depth` in `opencode.json`): subagents may spawn nested subagents when needed — use nesting for fan-out inside an area (e.g., area worker splits per-file/per-item), but prefer flat fan-out, stay within the parallelism budget, and never nest to re-delegate a single unit of work
- Backend verify (`gofmt`, `go vet`, `golangci-lint`, `go test`) and iOS verify (`swiftlint`, build, test) are disjoint — always run them on separate agents in parallel
- Serialize single-writer resources: one `xcodebuild` at a time (DerivedData lock), one simulator per test run, never concurrent `xcodegen generate` with project edits, one writer for `openapi.yaml` / `tasks.md` / `project-context.md` / `project.yml` / `Localizable.strings`
- Ask the user to start a new session if the current context overwhelms 200k tokens
