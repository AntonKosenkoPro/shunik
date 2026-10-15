## 1. Research bundle (ctx7, gates implementation)

- [x] 1.1 Complete the ctx7 research bundle and record library IDs + queries + pins in the task evidence: `/websites/developer_apple_xcode` — "Xcode Cloud custom build script ci_pre_xcodebuild" (script names, `ci_scripts/` discovery, `chmod +x`, shebang, automatic execution, no `sudo`); `/realm/swiftlint` — "command line lint strict mode exit code" (prior art, unchanged); `/websites/developer_apple_xcode` — "Xcode Cloud environment variables custom secret archive path" (secret vars redacted in logs, shared vars across workflows, `CI_ARCHIVE_PATH` for archive actions); `/getsentry/sentry-docs` — "sentry-cli debug-files upload dSYM manually" (`debug-files upload --org/--project PATH_TO_DSYMS`). Pin: iOS 18 SDK via Xcode 16+; SwiftLint 0.65.1 pin as landed (untouched). Waivers: HIG N/A — CI-only diff, no user-facing surface; Apple app-framework API N/A — diff is CI scripts + workflow YAML + docs + ASC settings.

## 2. Lint script (superseded — kept as landed)

- [x] 2.1 `ios/TimeOfLife/ci_scripts/ci_pre_xcodebuild.sh` already exists on `origin/main` (fail-closed `SWIFTLINT_PIN=0.65.1`, `100755`, Test-VM path handling from the #147 spike) — superset of the original sketch. No work; retained as-is.
- [x] 2.2 Local sanity green on the worktree tree: `sh -n` passes; `swiftlint 0.65.1 lint --strict` passes (0 violations in 180 files) from `ios/TimeOfLife/`.

## 3. Sentry upload script

- [x] 3.1 Add `ios/TimeOfLife/ci_scripts/ci_post_xcodebuild.sh` (`#!/bin/sh`, `set -e`, sibling-style comments): when `$CI_ARCHIVE_PATH/dSYMs` exists, install `sentry-cli` via Homebrew when missing (version echo, no fail-closed pin per design D3), then per project (staging, release) upload when `SENTRY_AUTH_TOKEN` + `SENTRY_ORG` + project var are all present, else `warning`-echo skip with reason (never values). No archive → quiet skip (PR Test-only builds). Committed mode `100755` (verify with `git ls-files -s`). (Done: extended the #156 single-project variant to staging+release parity with the GH job; restored the never-fail-the-archive invariant on upload error; verified below.)
- [x] 3.2 Local sanity: `sh -n` passes; simulate the skip paths locally (no `CI_ARCHIVE_PATH` → quiet skip exit 0; archive dir present but secrets absent → warning-skip exit 0). Full upload path cannot run locally (no Cloud archive/secrets) — covered by 4.1. (Done: all sims exit 0; real `sentry-cli 3.8.0` brew install proved the version echo.)

## 4. Cloud proof (gates the cutover — owner + ASC access required)

- [ ] 4.1 Manually start the tag-workflow Cloud build on this branch's head (coordinate TestFlight post-action with owner — disable/duplicate or ride the next real release): record build number, `sentry-cli` version echo, per-project uploaded/skipped lines (redacted), and confirm the new debug files in the Sentry dashboard (staging + release) with matching debug IDs. Paste all evidence into the PR.
- [ ] 4.2 Confirm `SENTRY_DSN` reached the archive build (SDK enabled, D5): read the archive log for the threaded DSN/build-setting expansion. If the env fallback did not propagate, implement the ordered fallback (`ci_pre_xcodebuild.sh`-written temporary `SENTRY_DSN.xcconfig` include) and re-prove before proceeding. Tasks 5.x stay blocked until 4.1–4.2 are green.
- [ ] 4.3 Record the `Test – iOS` action config in the PR workflow (scheme `TimeOfLife`, `TimeOfLifeTests`, simulator destination) and confirm the redundant `Build – iOS` action is gone from both Cloud workflows. Set the five shared secret env vars in ASC (`SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT_STAGING`, `SENTRY_PROJECT_RELEASE`, `SENTRY_DSN`) and read back their names/scopes (not values).

## 5. Cutover (GH macOS lane removal)

- [ ] 5.1 Delete `.github/workflows/ios.yml` (verification duplicated by Cloud tag Test → Archive; symbolication migrated per §3).
- [ ] 5.2 Strip `release.yml`: remove the `verify` job + `secrets: inherit` threading + the Summary's verify line; fix the header comment naming `ios.yml`. `bump-and-tag` (`ubuntu-latest`) is untouched.
- [x] 5.3 Verify (not assume) GitHub branch protection for `main` no longer requires the GH `ios` check (`gh api` read-back of required checks; expected handled by #155 — update only if stale, or every PR blocks post-merge). (Done: `gh api .../branches/main/protection/required_status_checks` → 404 "Branch not protected" — no required checks configured at all, nothing to update.)

## 6. Docs (reconcile with the Sentry-preserving premise)

- [x] 6.1 Update `docs/ci.md` (workflow list, secrets table GH-secrets → Cloud shared secret env vars + dSYM upload now from Cloud's signed archive, new-target checklist), `README.md` (CI + release paragraphs), `docs/project-context.md` (CI + deployment paragraphs), `AGENTS.md` (workflow listing), `docs/review-process.md` (mandatory-checks line) to describe Cloud-owned iOS CI with Sentry symbolication preserved. No baseline spec edits (skip_specs change). (Done via two passes: initial Cloud-ownership edits + Sentry-premise reconcile; reviewed.)

## 7. Verification

- [ ] 7.1 `grep -rn "ios\.yml\|workflow_call\|lint-build-test\|sentry-dsym" .github/ docs/ README.md AGENTS.md` returns only intentional historical mentions (note why each is kept); otherwise empty.
- [x] 7.2 `openspec validate --all --strict` green on the PR. (Done: 26 passed, 0 failed.)
- [x] 7.3 Backend suite green (`go test ./...` from `backend/`; `gofmt -l .` empty) plus a local iOS build + test pass (`xcodegen generate`, `swiftlint lint --strict`, `xcodebuild` build and `test` per `docs/ios-test-loop.md`) proving the tree is green without the deleted GH runner. (Done: gofmt empty, vet clean, all backend packages ok; xcodegen + swiftlint 0 violations + BUILD SUCCEEDED + 669 tests passed.)
