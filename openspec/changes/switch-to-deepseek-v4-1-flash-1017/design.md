## Context

See proposal.md for motivation. Current state: `ai-review.yml` triggers on any non-bot comment containing `/review`, resolves PR refs via `actions/github-script@v7`, then calls `alibaba/open-code-review@v1.12.9` with hardcoded `effort: medium`, `max_tokens_budget: '20000000'`, `llm_model: glm-5.3-flash`, `llm_extra_body: '{"think": "max"}'`. Observability is inline comments + sticky summary + artifacts only. The action (primary source: `action.yml` at v1.12.9) already supports everything we need: `effort` / `max_tokens_budget` / `llm_model` / `llm_reasoning_effort` inputs with server-side validation, `stream_progress`, and outputs (`comments_total`, `comments_inline`, `comments_failed`, `comments_routed`, `summary_comment_url`, `range_summary`, `checkpoint_after`). Its checkpoint fingerprint covers model, extra_body, reasoning_effort, effort, and budget — any deviation fails closed to a full review. Research: ctx7 `/websites/github_en_rest` ("check runs create update output annotations") and `/websites/github_en_actions` ("job summaries GITHUB_STEP_SUMMARY markdown"); models verified live via the models catalog + `ollama show` (1M context).

## Goals / Non-Goals

**Goals:**
- `/review [effort=..] [budget=..] [model=..] [think=..]` overrides with today's behavior as the exact default.
- Review outcome visible in the Checks tab via job summary + streamed progress, with zero new permissions.
- Invalid input fails loudly with usage, never silently.

**Non-Goals:**
- Custom Check Run via the Checks API; endpoint/token parametrization; merge-blocking; changing CI defaults.

## Decisions

- **Parse in the existing `github-script` step style (new step, plain JS, no new action dependency).** The workflow already depends on `actions/github-script@v7`; parsing is string ops + allowlists, no external API behavior — no ctx7 lookup needed beyond what the workflow already uses.
- **Backward-compatible grammar, anchored to the /review line.** Only the first line whose first token is `/review` carries params, and the first occurrence of a key wins — free text anywhere else (including the same run's prose, e.g. `prefer effort=low.`) can neither inject params nor break the run. Ignored tokens are surfaced, not silent: `core.notice` for key=value tokens outside the line (grammar-shaped, case-insensitive) and for overridden duplicates. Unrecognized text on the line is ignored, so `/review focus on X` keeps working; recognized keys with bad values fail loudly with usage.
- **Allowlists for behavior knobs, open model IDs.** `effort ∈ {low, medium, high}` (action vocabulary); `think ∈ {max, medium, off}` merged as `llm_extra_body {"think": value}` (default `max` preserves the pre-params extra_body exactly); `budget` = integer with `k`/`m` suffix, clamped to [1M, 100M], default 20000000; `full ∈ {true, false}`, default `false` → the action's `full_review` input. `model` accepts any Ollama Cloud model ID (safe charset `^[A-Za-z0-9._:/-]+$`, lowercased), default `deepseek-v4.1-flash:1017`. Rationale: the endpoint is fixed, so a model name cannot redirect spend off Ollama Cloud; typos fail fast at the OCR step with the provider's error; expensive-model risk is bounded by the 100M token cap *and* the OWNER/MEMBER/COLLABORATOR trust gate on all params. No `0`/unlimited budget (the runaway guard must stay on), no endpoint params.
- **Params are a trusted-role feature; bare `/review` stays open.** Anyone who can comment can trigger a default review (unchanged), but `key=value` tokens from outside OWNER/MEMBER/COLLABORATOR fail with a restricted message instead of running. Rationale: budget (up to 100M) + `full=true` re-reviews are repeatable paid-provider spend behind a cancel-and-restart trigger — the pre-existing open trigger is fine at CI defaults, not at 5x ceilings.
- **CI default moves to DeepSeek with the merge.** The model axis is part of the checkpoint fingerprint, so the first post-merge run does a fail-closed full review everywhere and records fresh checkpoints — a one-time cost, then incremental behavior resumes. This is the intended cutover, not a regression.
- **Prefer `think` over the action's `llm_reasoning_effort` input.** Our `review-process.md` documents `think: max` as the only thinking knob Ollama Cloud honors (`reasoning_effort` ignored there); the action's `llm_reasoning_effort` targets OpenAI/GLM vocabularies. Using the verified knob avoids asserting unverified provider behavior. Default empty reasoning_effort + `{"think":"max"}` keeps the extra_body axis byte-identical to today.
- **`full=true` reuses the action's `full_review`, not a custom range.** It forces one merge-base..head review with reason `manual_full_review` and still records a new checkpoint, so the next incremental run continues normally. `full_review` is not a fingerprint axis, so using it neither requires nor destroys checkpoint comparability — it just widens that one run. Default `false` keeps increment-only behavior.
- **Checks = job summary + `stream_progress: true`, not a custom Check Run.** A summary step (`if: always()`) writing params, `range_summary`, finding counts, summary URL, and checkpoint state to `$GITHUB_STEP_SUMMARY` renders on the run page linked from the Checks tab — no `checks:write` permission, no 50-annotations-per-request friction, no duplication of the inline findings that already exist. Rejected the Checks API route for exactly that cost. The params line is gated on the parse step's outcome (blank envs would otherwise read as defaults on the main failure path), and third-party action outputs reach the shell only via `env:` (script-injection policy; the allowlist-validated params are safe inline).
- **Keep the action's own validation as defense in depth.** Parsed values flow through the action inputs, so its `Validate inputs` step re-validates (effort/budget/reasoning vocabularies) even if our parser drifts.

## Risks / Trade-offs

- [Param use invalidates checkpoints] → Expected: fingerprint covers all four axes, so a parametrized run does a full review. Mitigation: document it; the summary step reports `range_summary` so the full-review cost is visible, not silent.
- [Bare `/review` must not change behavior unexpectedly] → Mitigation: defaults reproduce today's inputs exactly *except* the intended model cutover (glm → DeepSeek rotates the fingerprint once → one fail-closed full review, then checkpoints resume); extra_body stays byte-identical; regression-test bare + free-text triggers.
- [`budget` suffix parsing bugs] → Mitigation: strict regex + clamp + action-side re-validation; invalid values fail the job with usage text before any spend.
- [Summary step masking failures] → Mitigation: `if: always()` but never alters job conclusion; advisory stays advisory.
- [Heavier `think`/budget runs cost more] → Mitigation: explicit opt-in per comment, allowlist caps, budget ceiling 100M, concurrency group still cancels superseded runs.

## Migration Plan

Workflow-only change: land, then exercise on a test PR — bare `/review` (checkpoint preserved), each param once, one invalid value (expect usage error), and confirm the summary content. No data migration. Rollback: revert the workflow commit; `opencode.json` revert is a one-line change with no state.

## Open Questions

None — all unknowns (action input vocabularies, fingerprint axes, summary mechanics) resolved from `action.yml` v1.12.9 and the ctx7 docs above before writing tasks.
