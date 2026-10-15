## Context

See `proposal.md` — Why for motivation. Current state constraining this design (from `docs/project-context.md`, `AGENTS.md`, `docs/review-process.md`, `docs/ios-test-loop.md`, `openspec/config.yaml`):

- Research is conditional: "External docs first (ctx7)" fires only when external-dep behavior is involved (`library` → `docs`, one concept per query, max 3, cite ID + query + pin; quota fail → `login` / `CONTEXT7_API_KEY`, never silent fallback). Pure logic/refactor/review explicitly do not fetch.
- Worktrees exist by convention (~35 live under `timeOfLife.wt/`, one branch each) but nothing requires them; `AGENTS.md` only serializes shared resources (one `xcodebuild`, one booted sim, one writer per single-writer file).
- No rebase rule exists: `review-process.md` flow and `process-pr` skill go straight from branch to draft PR. Stale bases are normal (recent tree: 3 ahead / 11 behind `origin/main`).
- Bugfix rule (repro-first on current tree, implement only after confirm, identical-repro verify-after, regression test where automatable, `tasks.md` first task = repro) is load-bearing precedent (`#101`/`#67`) and must keep stacking, not be replaced.
- `openspec validate --all --strict` checks structure, not cite presence — enforcement stays prose + review (auto-enforcement is an explicit non-goal).

ctx7 note (design-rules compliance): this change is process/docs-only and derives from repo docs, not from a versioned external API shape — no `library` → `docs` fetch constrains this design itself. The design *mandates* future fetches; the HIG library-ID probe is task 1 work, recorded in `tasks.md`.

## Goals / Non-Goals

**Goals:**

- Make research, isolation, and freshness the default path for every feature/bugfix with waiver-by-evidence instead of silence.
- Keep the repro-first bugfix invariant untouched while stacking the three mandates on top.
- Land as docs/process edits in one reviewable PR with zero runtime, contract, or baseline-spec impact.

**Non-Goals:**

- Design-level exclusions from the proposal (CI/CD revision, auto-enforcement in validate/CI, quota-handling changes, explore-agent worktrees) apply here unchanged — see `proposal.md` — Non-goals.
- No new runtime architecture, data model, or API surface is introduced by this design.

## Decisions

### D1: Mandatory-with-waiver, not blind-unconditional (research)

Require the bundle for every feature/bugfix, but allow waiving an inapplicable item with a one-line reason + evidence (e.g. "HIG N/A — `backend/`-only diff, no UI"). Alternative (truly unconditional, HIG fetch even for pure-Go changes) rejected: burns ctx7 quota and agent time with zero signal. Waiver-by-evidence keeps teeth while respecting the current "do not fetch for pure logic" wisdom.

### D2: Research bundle = topic + platform guideline + API + practice (max 5)

- Always: 1× topic/problem-space query.
- If UI: + 1× HIG query (pending task-1 probe for the exact ctx7 library ID; `/websites/developer_apple_*` family is the starting point).
- If Apple SDK involved: + 1× Apple API query with SDK pin (e.g. "iOS 18 SDK via Xcode 16+").
- If external lib/service involved: + 1× best-practice/setup query.
- Cap raised 3 → 5 for this bundle only (one concept per query retained); cites (ID + queries + pins) recorded in proposal/design/tasks, re-fetched at apply time with a "nothing changed since explore" note. Alternative (keep cap at 3) rejected: topic + HIG + API already exhausts it.

### D3: One worktree per unit of work, main stays clean

Convention: `timeOfLife.wt/<change-name>` (matches the existing 35), one branch per worktree, created from fresh `origin/main`; session moves into the worktree (`session_move`) so paths never leak back to main. Lifecycle: create → work → PR → archive → `worktree_remove`. Read-only explore and trivial docs-typo fixes may stay in place; all code work (including 1-line fixes under parallel sessions) uses a worktree. Alternative (`opencode worktree_create` default location) rejected: would split conventions and orphan the existing `.wt/` fleet. Preserved invariant: worktrees do NOT lift the `ios-test-loop.md` serialization (one `xcodebuild`, one booted sim by ID) nor the single-writer file discipline — they only isolate trees/branches.

### D4: Double rebase, linear history, re-verify after each

`git fetch origin` + `rebase origin/main` (1) before implementing and (2) before opening the PR; pushed branches move via `push --force-with-lease` only; `merge main` into the branch is forbidden for feature/bugfix flows. Each rebase is followed by re-running the affected subsystem's linters/tests (rebase can silently invalidate green). Alternative (merge-based sync) rejected: non-linear history complicates `Fixes #` reasoning, archive folding, and bisect. One-branch-per-worktree (D3) makes force-push coordination safe: two agents never rebase the same branch.

### D5: Enforcement via rules + template + skill, not via validator

Edit `openspec/config.yaml` rules (remove the conditional `when` from proposal/design/tasks/apply guidance), PR-template checkboxes (research cites / worktree+branch / rebased-twice + re-verified), `process-pr` skill steps 0–1 (fetch/rebase + worktree preconditions, dirty-tree guard stays), and `.opencodereview/rule.json` hints (reviewer checks cites/waivers). Alternative (CI job grepping cites) rejected per non-goals: brittle, gameable, and out of scope.

### D6: Bugfix stacking order — repro AND research gate implementation

`tasks.md` section 1 holds both: 1.x = repro on the fresh base (recorded evidence), 1.y = research bundle; every implementation task depends on both. Order between them is free (parallel where possible), but neither may be skipped: an unreproducible bug stops the change even with perfect research, and a reproduced bug without research may not implement. The final task stays identical-repro re-verification.

## Risks / Trade-offs

- [Quota burn] Mandatory bundle multiplies ctx7 calls (up to 5 per change + apply-time re-fetch) → Mitigation: waiver-by-evidence (D1), one-concept queries, HIG probe cached in tasks for reuse.
- [HIG coverage gap] ctx7 may lack a true HIG library; mandating it then forces theater → Mitigation: task 1 probes the ID first; if thin, record "HIG via Apple Developer docs (manual)" with link instead of a fake cite — never fabricate an ID.
- [Disk + build duplication] A worktree per change duplicates checkouts and cold DerivedData weight (35 already live) → Mitigation: remove-on-archive rule, warm-cache discipline from `ios-test-loop.md` (never `clean`), one `xcodebuild` at a time unchanged.
- [Rebase invalidates green CI] Gate ② can turn a green head red → Mitigation: re-verify-after-rebase is part of the rule (D4), not optional; `process-pr` loops CI after the final rebase.
- [Force-push coordination] Two agents on one branch + rebase = lost work → Mitigation: D3 makes it structurally impossible (one branch per worktree); skill forbids shared-branch writes.
- [Cross-worktree merge conflicts] Single-writer files (`openapi.yaml`, `project-context.md`, `project.yml`) edited in two worktrees still collide at merge → Mitigation: unchanged single-writer discipline + rebase-early (gate ① surfaces drift before work, not at merge).

## Migration Plan

Docs-only rollout, no runtime deployment:

1. Land the doc edits (config + `project-context.md` + `AGENTS.md` + PR template + `process-pr` skill + `rule.json` hints + `ci.md`/`ios-test-loop.md` clarifications) in one PR through the normal mandatory checks (`openspec` validate must pass with `skip_specs: true`).
2. Announce in the next change kickoff: new `tasks.md` section-1 shape (repro + research) and the worktree/rebase gates.
3. Rollback: revert the docs PR — no data, contract, or baseline-spec state to unwind.

## Open Questions

- Q1 (deferrable): exact ctx7 library ID(s) for HIG + SwiftUI best practice — answered by the task-1 probe inside implementation, recorded in `tasks.md`; does not change this approach.
- Q2 (deferrable): whether the 45%-floor coverage gate or `ios.yml` scheme coverage needs follow-up once worktree-local runs are the norm — belongs to the deferred CI/CD change, not this one.
