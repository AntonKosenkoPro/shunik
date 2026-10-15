---
description: "Process a PR after implementation — template PR, green CI, AI-review loop, human handoff (never merge)"
---

Take an implemented branch to **human-review-ready**. You open/fill the PR,
green the mandatory checks, sweep AI review (fixing only proven findings),
then STOP for a human. You never merge.

Full workflow lives in the `process-pr` skill
(`.opencode/skills/process-pr/SKILL.md`) — follow it end to end.
The summary below is the invocation contract; the skill is authoritative
on steps, commands, and guardrails.

**Two-stage context (read before starting):** `docs/review-process.md`
(AI stage 1 = advisory `ai-review.yml` via `/review` comment; human stage 2
via PR-template checklist), `docs/ci.md` (mandatory `backend.yml` +
`ios.yml` + `openspec.yml`; advisory `ai-review.yml`), PR template
`.github/pull_request_template.md`, rules `.opencodereview/rule.json`.

**Input**: Optionally specify a branch name, PR number/URL, and/or OpenSpec
change name after `/opsx-pr` (e.g., `/opsx-pr`, `/opsx-pr 42`,
`/opsx-pr my-branch my-change`). If omitted, check if it can be inferred
from conversation context. If vague or ambiguous you MUST prompt (show
`gh pr list --author @me` + `openspec list --json` candidates).

**Steps**

0. **Preconditions** — `gh auth status` green; clean tree (commit/stash
   first); current branch is NOT `main`; base is `main` unless told
   otherwise. Resolve the linked OpenSpec change (explicit arg >
   branch-name match > single active change > ask).

   Always announce: "Using change: <name|none>", "Using PR: <#|none yet>"
   and how to override (e.g., `/opsx-pr <other>`).

1. **Open or reuse the PR (handle both)** — reuse the branch's open PR if
   one exists (verify base; fill empty template sections); else
   `git push -u origin <branch>` and `gh pr create --draft --base main`
   with `.github/pull_request_template.md` filled truthfully (check only
   verified S5/non-negotiables boxes; leave stage-2 boxes for the human).
   Announce `PR: <url> (draft)`.

2. **Wait for mandatory checks** — `gh pr checks --watch --fail-fast`;
   blocking = `backend` + `ios` + `openspec`. Advisory `ai-review` never
   blocks. On stall (~20 min) report the stuck run and ask.

3. **Resolve red checks (auto-fix + push)** — pull logs
   (`gh run view <id> --log-failed`), reproduce locally first
   (backend `gofmt`/`vet`/`test`, iOS `xcodegen`/`swiftlint`,
   `openspec validate --all --strict`), one clean rerun for flakes, then
   minimal fix → commit → push → back to step 2. Infra failures
   (runner/secrets/signing): report + stop, don't code around them.

4. **Run AI review** — `gh pr comment <PR#> --body "/review"`, wait for the
   sticky summary + inline comments, collect every finding.

5. **Triage — fix only what is proven** — reproduce or confirm each finding
   against code + `.opencodereview/rule.json` (linters own style);
   fix proven ones (regression test where automatable), waive the rest
   in-thread with `Waived: <reason + evidence>`. Never edit code to
   silence an unproven finding. Resolve threads only after fix/waive.

6. **Loop until clean (bounded)** — fixes → step 2 (CI stays green) →
   step 4 (`/review` again, checkpoint covers only new commits).
   **Max 3 fix→review rounds**, then hand off with a fixed-vs-waived ledger.

7. **Handoff to human (STOP — never merge)** — `gh pr ready <PR#>`,
   post + print the `Ready for human review (stage 2)` highlights
   (PR url, what changed, fixed, waived with reasons, stage-2 pointers).
   End the turn. No `gh pr merge`, no push to `main`, no archive yet.

8. **After human approval only — archive + merge ask** — on explicit human
   OK only (follow-up, never assumed): invoke the `/opsx-archive` workflow
   for the linked change (skip with a note when docs/tooling-only),
   then reply `Archived <change> to <path>. Green + approved — please
   merge when ready: <url>.` The human merges.

**Guardrails**

- Never merge. Never archive before human approval.
- Mandatory checks gate; AI review advises (a quiet review is not validation).
- Prove before fixing; bound the loop at 3 rounds.
- Template honesty; diff > ~400 lines → propose stacked PRs in the handoff.
- No passwords/plaintext tokens anywhere; `otp/request` stays 202-always.
- Agent attribution (§Agent attribution in the `process-pr` skill): trailer
  on every commit, footer on every authored PR/comment, `/review` first line.
