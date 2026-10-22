## Why

Three related improvements to how this repo runs AI assistance, all stemming from the same evidence: a same-harness AACR-Bench pilot (OCR reviewer, `glm-5.3-flash` judge) scored DeepSeek V4.1 Flash 1017 at P 0.179 / R 0.40 pooled over 3 samples; head-to-head on `dotnet/aspnetcore` both models posted 6 findings at P 0.333, but DeepSeek covered 3/5 ground-truth notes vs 2/5 in less than half the time (5.3 vs 12.4 min), and GLM-5.3-flash blew a 35-minute cap on `waveterm` that DeepSeek finished in 19 min. DeepSeek V4.1 Flash 1017 is active on Ollama Cloud (variants low/high/max) at $0.15/$0.60 per 1M tokens — cost-neutral vs GLM-5.3-flash ($0.15/$0.50) with ~2x the measured 24h throughput (253 vs 136 TPS).

1. **Default dev model**: `opencode.json` still points at the weaker `ollama-cloud/glm-5.3-flash`. Switch it to the vetted model.
2. **Parametrized `/review`**: the CI review workflow hardcodes `effort=medium`, `max_tokens_budget=20000000`, `glm-5.3-flash`, `think=max`, incremental-only range. There is no way to ask for a cheaper/faster or deeper pass, a different model, or a whole-PR re-review per PR without editing the workflow. Allow `/review effort=low budget=5m model=deepseek think=max full=true` style overrides, parsed from the trigger comment (increment stays the default).
3. **Checks observability**: today the only place to see what an AI review did is the inline comments + sticky summary. The PR Checks tab shows just pass/fail. Publish a job summary (params used, range, finding counts, summary link) so the outcome is visible where reviewers already look, and stream live progress into the log.

## What Changes

- `opencode.json`: default `model` → `ollama-cloud/deepseek-v4.1-flash:1017`; provider limits entry replaced (context 1000000 per `ollama show`; keep input/output caps 262144/131072).
- `.github/workflows/ai-review.yml`: new parse step for `/review` params (`effort`, `budget`, `model`, `think`, `full`; CI defaults mirror the new DeepSeek default); wire parsed values into the `open-code-review` action inputs; new `always()` summary step writing params + action outputs to `$GITHUB_STEP_SUMMARY`; enable `stream_progress`.
- `docs/review-process.md`: document the param syntax, defaults, allowlists, and the Checks summary.
- Explicit non-goals: `small_model` and all pinned subagent models unchanged; no endpoint/secret params (URL and token stay fixed); no merge-blocking behavior (advisory stays advisory); no custom Check Run via the Checks API.
- No **BREAKING** changes: bare `/review` and free text (`/review focus on X`) behave exactly as today; invalid param values fail the run with a usage error rather than silently misconfiguring.

## Capabilities

### New Capabilities

- None — no product behavior changes.

### Modified Capabilities

- None — no baseline spec requirement changes. The CI workflow and dev-model default are tooling, not product contract; behavior is documented in `docs/review-process.md`. The change keeps `skip_specs: true` in `.openspec.yaml` (`openspec validate` accepts zero deltas with that marker).

## Impact

- Dev sessions: default model becomes DeepSeek V4.1 Flash 1017 (main session only); token cost roughly neutral.
- CI: `/review` gains optional params; any param use invalidates the review checkpoint by design (the action fingerprints model/effort/budget/think — fail-closed full review, already the action's behavior).
- Docs: `review-process.md` gains a params reference + Checks section.
- Verification is workflow-level (test-PR runs: bare, each param, invalid value, summary content) plus `openspec validate`; no app test suites affected.
