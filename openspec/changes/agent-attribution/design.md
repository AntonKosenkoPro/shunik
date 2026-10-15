## Context

Single git identity (`Anton Kosenko <me@antonkosenko.pro>`, repo has no local
`user.*` overrides) and single `gh` identity (`AntonKosenkoPro`, keyring
token) are shared by human and agents. `release.yml` already sets
`github-actions[bot]` identity per task (lines ~350, ~374) — the precedent
for scoped identity — but agent dev work has no equivalent. `ai-review.yml:18`
ignores `sender.type == 'Bot'`, so any design introducing a bot credential
would need a workflow change; this design avoids that. `/review` triggers on
`contains(body, '/review')`, so footers appended after the trigger line keep
working. Trailer parsing verified: `git interpret-trailers --parse` accepts
`Co-Authored-By: opencode/build ses_9f3a <opencode@local>` (spaces in Name,
`<opencode@local>` reuses the email already present in history).

## Goals / Non-Goals

**Goals:**
- Any reader can tell human vs. agent on commits, PRs, issues, comments.
- One agent run is distinguishable from another via `role · model · ses`.
- Zero new credentials, zero workflow changes, zero history rewrite.
- Convention lives where agents read: `AGENTS.md`, `process-pr`, `opsx-pr`.

**Non-Goals:** see proposal.md (second identity, branch namespace, rewrite,
signing, blame visibility, v1 CI lint).

## Decisions

- **D1 — markers, not identity.** Keep one git Author default and one `gh`
  token. Rationale: owner decision ("header enough"); avoids PAT storage
  (R1), `gh auth` switching per session, and the `ai-review` Bot-guard
  change. Alternative (machine user) rejected for v1; design does not block
  upgrading later (footer format already carries what an avatar cannot:
  session).
- **D2 — commit trailer.** `Co-Authored-By: opencode/<role> (<model>,
  ses_<id>) <opencode@local>`, footer block, blank line above. Human stays
  Author/Committer, so no `git -c user.*` overrides and no persistent config
  that could leak onto human commits in the shared workdir. `Co-Authored-By`
  chosen over `Assisted-by` because GitHub renders it natively; without a
  registered agent email it shows as text (grey/unlinked) — accepted per D1.
- **D3 — GitHub footer (uniform).** Visible line
  `> Agent: opencode/<role> · <model> · ses_<id>` + invisible twin
  `<!-- lifio-agent: <role>/<model>/ses_<id> -->` (render-silent, API
  grep-able for future automation). Applies to PR bodies (appended after the
  filled template), issues, all agent comments including `/review` triggers
  (`/review` first line, footer after blank line) and waive replies.
- **D4 — taxonomy + fallbacks.** Role from `opencode.json` agent names
  (`explore`/`build`/`general`/`plan`), else `main`. Model as
  `provider/model` short id when known, else omitted (never `unknown`).
  Session as short `ses_<id>` (4–8 chars), else `YYYY-MM-DD` date. Role +
  session required; model best-effort — preserves every future query
  (non-human commits via `--grep`, per-class via role, exact run via ses)
  without deciding granularity now.
- **D5 — forward-only.** Cutover = this change's merge date; prior history
  stays mixed. Documented in the implementing PR, not rewritten.
- **D6 — convention-only enforcement (v1).** `AGENTS.md` rule + skill text.
  Hooks are local-only/bypassable; CI lint deferred — discipline + human
  review (template honesty already gates PRs) is proportionate for a
  process marker.
- **D7 — no product-spec touch.** Process-only: `skip_specs: true`,
  no baseline deltas, no FURPS/OpenAPI/Design updates at implement time
  (only the three instruction files above).

## Risks / Trade-offs

- Discipline-dependent: a forgetful agent (or human on an agent branch)
  omits the marker silently until a human notices. Mitigation: rule sits in
  `AGENTS.md` instructions (auto-loaded per `opencode.json`) and in both
  PR-path skill files; CI lint remains the follow-up escape hatch.
- `blame`/`--oneline` stay human-only (accepted non-goal); queries must use
  `--grep` / footers, documented in the rule text.
- Unregistered `<opencode@local>` never links a profile; if GitHub ever
  tightens trailer rendering, format may need revisiting — single canonical
  string keeps that change trivial.
