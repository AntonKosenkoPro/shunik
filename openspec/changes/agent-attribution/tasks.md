## 1. Verify marker mechanics (no product code)

- [x] 1.1 Record trailer verification: sample agent commit message through
  `git interpret-trailers --parse` on this tree (git 2.54.0) and paste the
  passing output in the implementing PR (explore already proved the shape;
  re-run here so evidence lives with the change).
- [x] 1.2 Dry-run the GitHub footer: render the PR-footer block
  (visible line + invisible twin) and confirm the `/review`-first-line form
  still satisfies `ai-review.yml`'s `contains(body, '/review')` guard by
  reading the workflow — no workflow edit.
- [x] 1.3 `openspec validate --all --strict` green on this change
  (expects `skip_specs: true` to hold; no delta specs).

## 2. Write the convention (instruction files only)

- [x] 2.1 `AGENTS.md`: add the attribution rule (commit trailer format,
  GitHub footer format, role/model/session taxonomy + fallbacks,
  forward-only cutover date, `blame` limitation note). Keep it short —
  point to the change for rationale.
- [x] 2.2 `.opencode/skills/process-pr/SKILL.md`: footer on PR create/fill,
  `/review` trigger with footer-after-first-line, waive-reply footers,
  trailer on every branch commit.
- [x] 2.3 `.opencode/commands/opsx-pr.md`: same, condensed to the
  invocation contract (skill stays authoritative).
- [x] 2.4 Re-check the relevant `Requirements/FURPS/*.md` rows and confirm
  no rows cover agent attribution (process-only); record the check in the
  implementing PR. No app/backend tests, linters, or builds affected —
  no code changes in this change.

## 3. Roll out

- [x] 3.1 Implementing PR links issue #161, states the cutover date, and
  shows one real trailer + one real footer as evidence (own dogfood).
- [x] 3.2 Note the deferred follow-up in the PR (CI lint enforcing markers)
  without implementing it.
