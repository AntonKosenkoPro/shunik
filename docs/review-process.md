# Two-Stage Review Process

Every PR passes two review stages: **stage 1 — AI review** (automated, advisory) and **stage 2 — human review** (self-review against a checklist). The design follows evidence-based review practice: small diffs (~<400 changed lines; defect detection collapses above ~400 LOC per sitting), AI delegated mechanical findings while humans keep intent/architecture judgment, and AI findings are advisory so they can never silently gate a merge.

## Stage 1 — AI review (automated)

**Workflow:** `.github/workflows/ai-review.yml` — **OpenCodeReview** (`alibaba/open-code-review`, pinned `v1.12.9`), Alibaba's review-specialized agent: deterministic file selection/bundling + a review agent with tool use, posting inline comments with line precision plus one sticky summary comment. Model — `deepseek-v4.1-flash:1017` on Ollama Cloud (OpenAI-compatible endpoint `https://ollama.com/v1`, `OLLAMA_API_KEY` secret, `llm_protocol: openai`), thinking at max (`llm_extra_body: {"think": "max"}` — the only thinking knob Ollama Cloud honors; `reasoning_effort` is ignored there), review effort `medium`. Default moved from `glm-5.3-flash` on pilot evidence (AACR-Bench P 0.179/R 0.40 pooled, faster per finding, neutral cost); `glm-5.3-flash` remains one comment away via `model=`.

- **Manual trigger: comment `/review` on the PR.** Nothing runs on push — you decide when the AI looks. A comment that *contains* `/review` (e.g. "/review focus on SyncController") starts a run; bot comments are ignored; a running review is cancelled and restarted if you comment again. Per-run params (below) are optional `key=value` tokens — bare `/review` keeps today's behavior exactly.
- **Per-run params (trusted roles only; anyone else's `/review` runs at CI defaults):** `/review [effort=low|medium|high] [budget=<n>[k|m]] [model=<ollama-cloud-id>] [think=max|medium|off] [full=true|false]`. Defaults: `effort=medium`, `budget=20000000` (clamped to 1M–100M), model `deepseek-v4.1-flash:1017` (any Ollama Cloud model ID works, e.g. `glm-5.3-flash`), `think=max`, incremental range. `full=true` re-reviews merge-base..head and records a new checkpoint. Only the `/review` line is read (first occurrence of a key wins; ignored tokens get a notice, not silence); all other text is ignored, so free-form notes keep working. A bad value fails the run with usage text. Any param use invalidates the checkpoint by design (fail-closed full review; the summary shows the reason).
- **Checks observability:** every run publishes a job summary (params used, reviewed range + reason, finding counts, sticky-summary link, checkpoint) on the run page linked from the Checks tab, plus live `[ocr]` progress streamed into the log. The `ai-review` check itself stays pass/fail-advisory — green tells you the review ran, the summary tells you what it did.
- **Why this engine:** its published benchmark (AACR-Bench, 200 real PRs) shows the same-model quality of a general-purpose agent at **~1/9 of the tokens** and faster wall-clock — precision-favored by design (lower recall, near-zero noise). That trade fits this process: stage 1 is a cheap pre-clean, stage 2 (human + OpenSpec reasoning) catches the gaps.
- **Advisory by design:** the job never blocks merge — findings are review comments only. The human decides what to fix and what to waive.
- **What it checks:** repo-specific rules from `.opencodereview/rule.json` (committed, per-path): LocalStore chokepoint, OpenAPI contract sync, Theme colors / L10n en+ru / XcodeGen, Keychain-only tokens, test validity, CI hygiene — plus OCR's built-in language rules for Go/Swift/YAML. Note: unlike the opencode-agent stage 1 it replaces, OCR reviews diffs per file with targeted rules, not the whole OpenSpec change — OpenSpec compliance stays a stage-2 responsibility (PR template + `openspec.yml` gate).
- **What it skips:** style/formatting (golangci-lint + swiftlint already gate it); `openspec/changes/archive/**` and `.pbxproj` are excluded in `rule.json`.
- **Behavior across runs:** each `/review` reviews the PR diff; the first run covers `merge-base..head` in full and records a **checkpoint**; a later `/review` (after more commits) covers only `<checkpoint>..<head>` (fail-closed: any doubt → full review). The sticky summary comment is updated in place; **all** findings post inline (`route_severity_below` empty — no severity routing). Rapid re-comments: the concurrency group cancels the in-flight run and restarts.
- **Tuning:** rules live in `.opencodereview/rule.json` (path-scoped `rule` strings + `exclude` globs); knobs are action inputs (`review_concurrency`, `effort` low/medium/high, `max_tokens_budget`, `route_categories`); model/endpoint are `llm_model` / `llm_url` (any OpenAI-compatible endpoint works).
- **Anti-rubber-stamping rule:** a quiet AI review is *not* validation. Stage 2 runs regardless of how clean stage 1 looks.

## Stage 2 — Human review (you)

Runs after stage 1 findings are addressed or consciously waived. Use the checklist in the PR template (`.github/pull_request_template.md`) — it encodes the S5 iteration rules and the repo non-negotiables. Principles behind it:

1. **Review as a reader, not the author** — read the whole diff top-to-bottom once with fresh eyes before approving; self-review catches most issues before any reviewer.
2. **Humans keep what AI is weak at:** intent/spec fit, architecture fit (LocalStore chokepoint, OpenAPI contract), concurrency, product behavior. **Verify UI changes by running the app**, not by reading code.
3. **Tests must be valid, not just present** — would they fail if the code broke? Watch for deleted/skipped tests, especially in AI-written chunks.
4. **Optimize for the reader in 6 months:** names communicate, comments explain *why* not *what*; `git log` + PR description are the historical record (what + why + linked OpenSpec change).
5. **Code health over perfection:** approve when the change definitely improves the codebase; mark non-blocking remarks as nits and defer or do them explicitly.
6. **Size discipline:** ≤ ~400 changed lines per PR; split refactors from features; tests ride with the code they test.

## Flow

```
implement on branch
  → open PR as DRAFT
  → comment /review (stage 1): AI posts inline findings + sticky summary
  → fix 🔴 findings, push, /review again if needed
  → mark ready
  → stage 2: self-review with the PR-template checklist,
    verify behavior by running the app where it matters
  → all CI checks green (backend/ios/openspec) → merge
  → update OpenSpec tasks.md / advance the change as part of the merge commit's context
```

Draft PRs are the sequencing mechanism; `/review` is the switch — AI sweeps the diff when you ask, so pushes mid-development stay un-reviewed.

## Supporting checks

- **`openspec.yml`** — spec-integrity gate: `openspec validate --all --strict` (CLI pinned `@1.8.0`) on every PR and push to `main`. Fails broken OpenSpec structure; protects the spec-driven contract.
- **PR template** — OpenSpec linkage + S5 + non-negotiables + stage-2 checklist checkboxes.
- **Existing mandatory checks** — `backend.yml` (gofmt/vet/golangci-lint/race tests/coverage floor 45%/OpenAPI contract gate) and the Xcode Cloud `iOS PR Checks` workflow (xcodegen/swiftlint --strict/warnings-as-errors build/tests). See `docs/ci.md`.

## Metrics (lightweight, optional)

- **AI-finding acceptance rate** — share of inline findings actually fixed (grep PR review threads); the core quality signal for tuning `.opencodereview/rule.json`.
- **Noise trend** — inline comments per review; if it grows, tighten rules or set `effort: low`.
- **Defect escape** — post-merge bugs the diff introduced; note them in the OpenSpec change when archived; quarterly skim of `openspec/changes/archive/` gives the rate with no tooling.

## Cost

OCR is the low-cost engine: deterministic file bundling means each review is a few single-shot LLM rounds per file group, not a long agent loop. On `deepseek-v4.1-flash:1017` ($0.15/$0.60 per 1M tokens) a typical diff costs cents per run (re-measure post-cutover; the glm-era figure was ~$0.09 at think-max + effort low); checkpoint mode keeps follow-up pushes proportionally small. A generous `max_tokens_budget` guard is set in the workflow as runaway protection (tune after measuring typical usage). The concurrency group cancels superseded runs on rapid pushes. Test files are included via `rule.json` `include` (otherwise the test-validity rules could never fire); project rules merge with built-in language rules (`merge_system_rule`).

## References

- OpenCodeReview: https://github.com/alibaba/open-code-review (config: https://open-codereview.ai/docs/configuration, rules: https://open-codereview.ai/docs/review-rules)
- Google eng-practices (reviewer standard, small CLs): https://google.github.io/eng-practices/review/
- SmartBear/Cisco review best practices (~400 LOC rule, checklists): https://smartbear.com/learn/code-review/best-practices-for-peer-code-review/
- GitHub on reviewing AI-generated code: https://docs.github.com/en/copilot/tutorials/review-ai-generated-code
- OpenSpec review workflow: `openspec/README.md`, https://github.com/Fission-AI/OpenSpec