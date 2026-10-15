## Context

See proposal.md (Why) for motivation. Current state on `origin/main`: PR verification is Cloud-owned (`iOS PR Checks`: Build + Test on PRs touching `ios/`, SwiftLint via `ci_pre_xcodebuild.sh` pinned fail-closed at 0.65.1, `ios.yml` triggerless). The remaining GH macOS lane is release-only: `release.yml`'s `verify` job (`ubuntu` bump + tag, then `workflow_call` into `ios.yml` with `secrets: inherit`) runs `lint-build-test` (duplicates Cloud tag Test → Archive on the same content) and `sentry-dsym` (unsigned GH archive purely for dSYMs + `sentry-cli debug-files upload` to staging/release, all secrets optional with graceful skip). The iOS app links `sentry-cocoa` via SPM; `project.yml` sets `SENTRY_DSN: "$(SENTRY_DSN)"`; GH threads `SENTRY_IOS_DSN` in as an `xcodebuild` CLI setting. Constraints: S6 mandatory-check coverage must survive; the `observability` baseline's symbolication must survive; Debug stays unsigned / Release signed with team `7923U48U87`; XcodeGen-managed project; `release.yml` bump stays on `ubuntu-latest`.

## Goals / Non-Goals

**Goals:**
- Zero GitHub macOS minutes with zero loss: verification already Cloud-covered; symbolication moves to Cloud's own archive.
- Upload dSYMs that match the shipped binary exactly (same signed archive TestFlight receives), replacing the separate unsigned GH archive.

**Non-Goals:**
- No Sentry-side changes (projects, tokens, DSN values, SDK) — same secrets, new home (ASC shared secret env vars).
- No lint/build/test bar changes; no `Analyze` outcome mandates (owner-controlled, as before).

## Decisions

- **D1 — Lint half: no work, kept as landed.** `ci_pre_xcodebuild.sh` (fail-closed `SWIFTLINT_PIN=0.65.1`, Test-VM path-robustness from the #147 spike) supersedes this change's original unpinned sketch. The prior design's "pinning deferred" is withdrawn — the tree already pins; the new script follows the same fail-closed convention where cheap (see D3).
- **D2 — dSYM source is Cloud's own signed archive (`$CI_ARCHIVE_PATH/dSYMs`).** Strictly better than GH's separate unsigned archive: identical binary to what TestFlight ships, debug-ID match guaranteed rather than relied upon. `/websites/developer_apple_xcode` — "Xcode Cloud environment variables custom secret archive path": `CI_ARCHIVE_PATH` is provided for archive actions; secret env vars are redacted in logs. Alternative (keep GH unsigned-archive upload) rejected: it is the very macOS residue #159 asks to remove, and it symbols a binary nobody ships.
- **D3 — New `ci_post_xcodebuild.sh`, skip-gracefully, sentry-cli unpinned.** Runs after every Cloud xcodebuild action; uploads only when an archive exists (PR Test-only builds skip — no archive, nothing to symbolicate) and per project only when token+org+project are all present, echoing `uploaded <name>` / `skipping <name> (<reason>)` without values. `sentry-cli` installs via Homebrew when missing with a version echo; unlike linters, no fail-closed pin — a leaf uploader's version skew cannot change pass/fail correctness (upload API stable), and pinning would couple every sentry-cli release to a repo edit. `/getsentry/sentry-docs` — "sentry-cli debug-files upload dSYM manually": `debug-files upload --org/--project PATH_TO_DSYMS`. Alternative (fail-closed pin like SwiftLint) rejected per above.
- **D4 — Secrets live in ASC shared secret env vars, same names.** `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT_STAGING`, `SENTRY_PROJECT_RELEASE` (names identical to today's GH secrets so the skip-logic reads the same), applied to the tag workflow; documented as a manual operator step with a verification read-back. Alternative (per-workflow vars) rejected: shared vars survive workflow renames and cover any future archive workflow.
- **D5 — Archive DSN via process-environment fallback.** GH passes `SENTRY_DSN` as an `xcodebuild` CLI setting; Cloud archive actions have no CLI, so the value comes from a Cloud env var of the same name, resolved through the `$(SENTRY_DSN)` build-setting reference (`project.yml` already declares it). The proof task verifies SDK enablement from the archive log; if the fallback does not propagate, the ordered fallback is a `ci_pre_xcodebuild.sh`-written temporary `SENTRY_DSN.xcconfig` include — proof task covers both outcomes, so no open question remains.
- **D6 — Atomic cutover, proof gates deletion.** Order: script lands → Cloud proof (manual ASC build on the branch + Sentry dashboard shows the debug files; versions recorded) → only then `ios.yml` deletion + `release.yml` strip + docs. `main` is never without a proven symbolication path. `release.yml`'s `secrets: inherit` goes with `verify` (nothing left to thread secrets into).

## Risks / Trade-offs

- [Risk] Secret-name mismatch → script skips silently, crashes ship unsymbolicated → Mitigation: per-project uploaded/skipped-with-reason echoes (values never printed) + Sentry-dashboard proof step with debug-ID match gates the cutover.
- [Risk] `SENTRY_DSN` env fallback does not reach the archive build → SDK disabled in shipped builds → Mitigation: D5 ordered fallback verified in the proof task before deletion.
- [Risk] Proof needs a Cloud archive build without publishing to TestFlight → Mitigation: proof task uses a manually-started ASC build (post-actions observed, TestFlight step coordinated with owner) or rides the next real release — owner's call, recorded in the task.
- [Risk] `sentry-cli` Homebrew install adds ~1 min to archive builds → Accepted: tag builds only, far cheaper than two `macos-15` GH runners per release.
- [Risk] Branch protection may still reference the GH `ios` check → Mitigation: verify-only task (`gh api` read-back); #155 is expected to have handled it.
