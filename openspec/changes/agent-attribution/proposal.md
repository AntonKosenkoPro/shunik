## Why

Issue #161: agent work is invisible. The repo's git identity is a single
`Anton Kosenko <me@antonkosenko.pro>` (global `~/.gitconfig`) and a single
`gh` token (`AntonKosenkoPro`), so every agent commit, PR, issue, and comment
renders as the human. History proves the blur: ~520 commits carry the human
identity, 2 carry `opencode <opencode@local>`, and no commit carries any
trailer (`git log --grep='Co-Authored|Assisted-by|opencode|agent'` finds only
incidental subject matches). Where an agent commits — or posts anything with
an identity — it must be clear it is an agent, and one agent must be
distinguishable from another.

## What Changes

A marker convention (not a credential change) for every agent-produced,
identity-bearing surface:

- **Commits**: human stays Author/Committer; agent joins via a
  `Co-Authored-By` trailer carrying role, model, and session:
  `Co-Authored-By: opencode/<role> (<model>, ses_<id>) <opencode@local>`.
- **GitHub entities** (PRs, issues, comments, review replies): same single
  `gh` identity, plus a uniform footer —
  `> Agent: opencode/<role> · <model> · ses_<id>` with an invisible
  `<!-- lifio-agent: <role>/<model>/ses_<id> -->` twin for API grep.
- **Agent-vs-agent**: the `role · model · ses_<id>` triple is the separator;
  no per-session accounts.
- **Forward-only**: existing history untouched (no SHA rewrite); convention
  applies from this change's cutover date.
- **Enforcement v1**: convention in `AGENTS.md` + `process-pr` skill +
  `opsx-pr` command (the files agents actually read). No hooks, no new CI
  check in v1.

## Capabilities

- None — no REQUIREMENT changes. No baseline spec moves: this change alters
  no product behavior, no API, no UI. Validation opts out via
  `skip_specs: true` in `.openspec.yaml` (precedent:
  `2026-09-22-fix-running-tags-title-spacing`).

## Impact

At implement time: `AGENTS.md` (attribution rule), 
`.opencode/skills/process-pr/SKILL.md` (footer on PR bodies, `/review`
trigger compatibility, waive-reply footers), `.opencode/commands/opsx-pr.md`
(same, condensed). Untouched: `ai-review.yml` (no bot credential, so the
`sender.type != 'Bot'` guard at `ai-review.yml:18` keeps working), branch
naming, `backend/`, `ios/`, `backend/api/openapi.yaml`, all baseline specs.
No external dependency: git-core trailer parsing verified by execution
(`git interpret-trailers --parse`, git 2.54.0) — no ctx7 fetch; no version
pin involved.

## Non-Goals (explicit)

- No second GitHub identity (no machine user, no PAT/App, no avatar
  separation) — decided in explore ("header enough").
- No branch namespace (`agent/...`) — current `feat/*` / `fix/*` stays.
- No history rewrite of the ~520 mixed commits.
- No commit signing (out of scope per owner).
- No blame/`--oneline` visibility: `Co-Authored-By` shows in
  `log`/`show`/commit page, never in `blame`. Accepted.
- No CI lint enforcing markers in v1 (deferred follow-up).
