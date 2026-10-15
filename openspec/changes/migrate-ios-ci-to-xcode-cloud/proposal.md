## Why

Issue #159 asks for all macOS work on Xcode Cloud. The archived `move-ios-checks-to-xcode-cloud` (#155) moved PR verification to Cloud, but a GitHub macOS residue remains: `ios.yml` (now `workflow_call`-only) runs `lint-build-test` plus a `sentry-dsym` job on every release via `release.yml`'s `verify` job — two `macos-15` runners per release. The lint-build-test half is pure duplication (Cloud's tag workflow already runs Test → Archive on the pushed tag). The `sentry-dsym` half is load-bearing: it archives Release and uploads dSYMs to Sentry (staging + release projects). Deleting `ios.yml` outright would silently drop crash symbolication. This change completes the migration without losing it — by uploading from Cloud's own signed archive instead of a separate unsigned GH archive.

## What Changes

- Add `ios/TimeOfLife/ci_scripts/ci_post_xcodebuild.sh` (executable, `#!/bin/sh`, `set -e`): after archive actions, uploads `$CI_ARCHIVE_PATH/dSYMs` via `sentry-cli debug-files upload` to the staging and release projects. Preserves today's skip-gracefully semantics: absent archive (PR Test-only builds), absent secrets, or absent project each skip with a warning, never a failure — and secret values never echo (Cloud redacts secret env vars in logs).
- Thread Sentry secrets through Xcode Cloud shared **secret** environment variables (operator step in App Store Connect, applied to the tag workflow): `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT_STAGING`, `SENTRY_PROJECT_RELEASE`, plus the archive DSN (`SENTRY_DSN`, sourced from today's `SENTRY_IOS_DSN` value) consumed via process-environment fallback of the `$(SENTRY_DSN)` build setting.
- Delete `.github/workflows/ios.yml` (both jobs go away: verification as duplication, symbolication as migrated).
- Strip `release.yml`: remove the `verify` job, its `secrets: inherit` threading, and the Summary's verify line. `bump-and-tag` (`ubuntu-latest`) is untouched.
- Confirm the redundant `Build – iOS` action is gone from both Cloud workflows (Test compiles on its own; Archive builds + signs on its own).
- Verify GitHub branch protection for `main` no longer requires the GH `ios` check (expected already handled by #155 — verify, don't assume).
- Update docs that describe the GH lane: `docs/ci.md` (workflow list, secrets table GH→Cloud, new-target checklist), `README.md` (CI + release paragraphs), `docs/project-context.md` (CI + deployment paragraphs), `AGENTS.md` (workflow listing), `docs/review-process.md` (mandatory-checks line).
- Non-goals: no Sentry project/DSN/auth-token changes (same values, new home); no sentry-cocoa SDK or `.swiftlint.yml` changes; no Cloud Environment/Xcode upgrades; no TestFlight group changes; no versioning/signing changes; no SwiftLint/XcodeGen pin changes (fail-closed pins stay as landed).

## Capabilities

### New Capabilities

None — CI provider move with preserved behavior, no product behavior changes.

### Modified Capabilities

None — no baseline spec requirements change (the `observability` baseline's symbolication requirement is preserved, not altered). This change keeps `skip_specs: true` in its `.openspec.yaml` (validated: zero deltas expected).

## Impact

- Affected systems: `ios/TimeOfLife/ci_scripts/` (+1 file), `.github/workflows/` (−`ios.yml`, `release.yml` loses `verify`), App Store Connect (workflow actions + shared secret env vars — manual operator steps), branch protection (verify-only), docs listed above.
- Affected baseline capabilities: `observability` (behavior preserved) and `release-versioning` (release flow description changes, requirements untouched) — docs-adjacent only.
- Authoritative docs / research bundle: `/websites/developer_apple_xcode` — "Xcode Cloud custom build script ci_pre_xcodebuild" (script naming, `ci_scripts/` discovery, `chmod +x`, shebang, automatic execution, no `sudo`); `/realm/swiftlint` — "command line lint strict mode exit code" (prior art, unchanged); `/websites/developer_apple_xcode` — "Xcode Cloud environment variables custom secret archive path" (secret env vars redacted in logs, shared vars across workflows, `CI_ARCHIVE_PATH` for archive actions); `/getsentry/sentry-docs` — "sentry-cli debug-files upload dSYM manually" (`debug-files upload --org/--project PATH`). Pin: iOS 18 SDK via Xcode 16+; SwiftLint 0.65.1 / XcodeGen pins as landed (untouched). HIG N/A — CI-only diff, no UI (waiver: no user-facing surface changes). Apple app-framework API N/A — diff is CI scripts + workflow YAML + docs + ASC settings (waiver: no app code touched).
- Risk: dSYM upload silently skipping (secret-name mismatch) ships unsymbolicated crashes — mitigated by echoing per-project uploaded/skipped-with-reason lines and a Sentry-dashboard proof step gating the cutover. Direct pushes to `main` (release-bot bump commits) lose the GH `verify` gate and rely on the tag workflow's `Test → Archive`; accepted (same coverage, Cloud-owned, already the case for PRs since #155).
