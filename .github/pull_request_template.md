<!--
Two-stage review process: docs/review-process.md
Stage 1 (AI review) runs automatically on this PR. Stage 2 is your self-review below.
-->

## What & why

<!-- One paragraph: what this PR does and why. Link the OpenSpec change if there is one. -->

## OpenSpec

- [ ] Behavior change is covered by an OpenSpec change (`openspec/changes/<name>/`), or this PR is docs/tooling-only
- [ ] Baseline specs (`openspec/specs/`) untouched; deltas live under the change
- [ ] `tasks.md` updated for the work done in this PR

## Required on every iteration (S5)

- [ ] Research bundle recorded (ctx7 IDs + queries + pins, or waiver reasons) — `docs/project-context.md` → "External docs first (ctx7)"
- [ ] Work done in an isolated worktree (`timeOfLife.wt/<change>`, one branch per worktree); rebased on `origin/main` before implementing AND before opening this PR, affected suites re-run after each rebase
- [ ] Both linters green (`golangci-lint run`, `swiftlint lint --strict`), `gofmt -l .` empty, no build warnings
- [ ] Both test suites green (`go test ./...`, `xcodebuild test`)
- [ ] Relevant `Requirements/FURPS/*.md` rows re-checked
- [ ] Docs updated if architecture/contract/design changed (`docs/project-context.md`, `Design/*.md`, `backend/api/openapi.yaml`)
- [ ] Bugfix: reproduced on the current tree before fixing and re-verified after (evidence linked); regression test added where automatable

## Repo non-negotiables

- [ ] All mutations via `LocalStore` — no raw GRDB writes outside it
- [ ] Tokens/OTP codes: Keychain/hashes only, no plaintext; `otp/request` stays 202-always
- [ ] New iOS strings in **both** `en.lproj` and `ru.lproj` + `L10n`
- [ ] `Theme` semantic colors only — no raw `Color` literals
- [ ] If `openapi.yaml` changed: handlers + iOS client + spec all moved together
- [ ] `project.yml` + `xcodegen generate`, never hand-edited `.pbxproj`

## Stage 2 checklist (human review)

- [ ] UI changes verified by running the app in the simulator (not just read)
- [ ] New tests would actually fail if the code broke
- [ ] AI review findings addressed or consciously waived (resolve threads)
- [ ] Diff ≤ ~400 changed lines, or split into stacked PRs
- [ ] Dead code removed; existing utilities reused where possible