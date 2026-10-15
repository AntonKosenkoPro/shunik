## Why

Feature and bugfix work lands with stale APIs, HIG violations, and avoidable merge pain: research is conditional ("only if external-dep"), agents share one checkout (dirty tree, single-writer conflicts on `openapi.yaml`/`tasks.md`/`project-context.md`, `xcodebuild` serialization), and PRs open from stale bases (example: a recent tree sat 11 commits behind `origin/main`). Raising the three disciplines to mandatory removes the most common rework causes before code is written.

## What Changes

- **Mandatory comprehensive research before implementing (features + bugfixes):** every change researches the topic, applicable HIG guidelines, Apple documentation, and best practices via `npx ctx7@latest library` → `docs` before coding, and re-confirms at apply time. Results (library IDs + queries + version pins) are cited in `proposal.md` / `design.md` / `tasks.md`. Pure non-UI / non-external work may waive a bundle item with a one-line reason + evidence (e.g. "no UI — HIG N/A; diff touches `backend/` only"), never by silence.
- **Mandatory isolated git worktree per unit of work:** all code work happens in a separated worktree (`timeOfLife.wt/<change-name>`, one branch per worktree); the main checkout stays clean and is the fetch source of truth. Lifecycle: create from fresh `origin/main` → work → PR → archive → remove worktree. Read-only explore stays worktree-free.
- **Mandatory double rebase on `origin/main`:** `git fetch origin` + rebase onto `origin/main` before implementing (fresh base) and again before opening the PR (mergeable head). After each rebase re-run the affected linters/tests; pushed branches update via `push --force-with-lease`; never substitute `merge main` into the branch.
- **Bugfix parity:** the existing repro-first / verify-after / regression-test rule is unchanged and stacks with the three mandates above (repro task + research task both gate implementation).

## Capabilities

### New Capabilities

- None — process/docs-only change, no product behavior.

### Modified Capabilities

- None — no baseline spec requirement changes.

> `skip_specs: true` is set in `.openspec.yaml` (docs/process/tooling-only; validation would otherwise reject a zero-delta change). Do not invent a requirement to satisfy validation.

## Non-goals

- CI/CD pipeline revision (original item 3: backend/ios/openspec/release/ai-review tuning, coverage floor, new-target checklist) — deferred to a separate change.
- Auto-enforcing ctx7 cites in `openspec validate` or CI — still honor-system + human/AI review.
- Raising the ctx7 quota handling beyond the existing `login` / `CONTEXT7_API_KEY` guidance.
- Mandating worktrees for read-only explore agents or changing the merge strategy beyond rebase-only for feature/bugfix branches.

## Impact

- Docs/process only: `docs/project-context.md` (S5 per-iteration + External-docs-first), `AGENTS.md` (flow recommendations), `openspec/config.yaml` (proposal/design/tasks/apply rules), `.github/pull_request_template.md` (new checkboxes), `.opencode/skills/process-pr/SKILL.md` (fetch/rebase + worktree preconditions), `.opencodereview/rule.json` (review hints), `docs/ci.md` + `docs/ios-test-loop.md` clarifications (worktree + rebase interaction with DerivedData/simulator/single-writer rules).
- No runtime code, no API/contract change, no baseline spec edits, no migration.
