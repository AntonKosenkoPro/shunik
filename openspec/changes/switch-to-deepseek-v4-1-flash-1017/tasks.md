## 1. Default model switch

- [x] 1.1 Set `opencode.json` top-level `model` to `ollama-cloud/deepseek-v4.1-flash:1017`
- [x] 1.2 Replace `opencode.json` → `provider.ollama-cloud.models` entry: key `deepseek-v4.1-flash:1017` with limits `context 1000000, input 262144, output 131072`; remove the `glm-5.3-flash` entry
- [x] 1.3 Validate `opencode.json` parses and the model resolves (catalog shows `ollama-cloud/deepseek-v4.1-flash:1017` active); grep that no other default-model reference changed unintentionally

## 2. Slash-command params

- [x] 2.1 Add a parse step (after Resolve PR refs) extracting `effort`/`budget`/`model`/`think`/`full` key=value tokens from the trigger comment; ignore all other text; export normalized values with today's defaults (medium / 20000000 / glm-5.3-flash / max / false)
- [x] 2.2 Enforce allowlists in the parse step: effort low|medium|high, think max|medium|off, full true|false, budget integer with k/m suffix clamped to [1M, 100M]; model accepts any Ollama Cloud ID (charset `^[A-Za-z0-9._:/-]+$`), default `deepseek-v4.1-flash:1017`; fail the job with usage text on recognized-key-invalid-value; anchored to the /review line (first-wins + displaced/duplicate notices); params restricted to OWNER/MEMBER/COLLABORATOR (bare /review open to all)
- [x] 2.3 Build `llm_extra_body` as `{"think": value}` from the parsed think level; wire effort/budget/model/extra_body/full_review inputs into the Run OpenCodeReview step
- [x] 2.4 Confirm default (bare `/review`) reproduces today's inputs except the intended model cutover (glm → DeepSeek rotates the fingerprint once → one fail-closed full review post-merge); extra_body byte-identical

## 3. Checks observability

- [x] 3.1 Set `stream_progress: 'true'` on the Run OpenCodeReview step
- [x] 3.2 Add an `always()` summary step writing params used, `range_summary`, finding counts (`comments_total`/`inline`/`failed`/`routed`), `summary_comment_url`, and checkpoint state to `$GITHUB_STEP_SUMMARY` (params line gated on parse outcome; action outputs via `env:`)
- [x] 3.3 Confirm no permission changes are needed (summary needs none; no Check Run API used)

## 4. Docs

- [x] 4.1 Update `docs/review-process.md`: param syntax table with defaults/allowlist, bare-`/review` compatibility note, checkpoint-invalidation-on-params note, Checks summary section
- [x] 4.2 Update `ai-review.yml` inline comments to match the new behavior

## 5. Verification

- [x] 5.1 Parser simulation matrix (16 cases, stubbed core/context): bare + free text → defaults byte-identical; each valid param applies (last-wins on duplicates); invalid values and out-of-range budgets fail with usage
- [ ] 5.2 Post-merge live runs (deferred: `issue_comment` workflows execute the file from `main`, so new params only take effect after merge): bare `/review`, free text, each param once, `full=true` (expect `full (manual_full_review)`), one invalid value (expect usage error), confirm summary content on the run page
- [x] 5.3 Run `openspec validate` for the change and confirm green
