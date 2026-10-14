## Why

iOS PR checks run on `macos-15` GitHub runners (10× billing multiplier). One `ios.yml` run measures ~7.5 min wall (~75 billed min); at the current agent-driven cadence (~11 iOS runs/day on Oct 10–11) the free monthly Actions quota burns in ~2 weeks (issue #136). The owner holds 25 Xcode Cloud compute hours/month and judges that sufficient — moving iOS PR verification to Apple-native CI removes the quota blocker while keeping mandatory checks (Requirements S6).

## What Changes

- Add an Xcode Cloud workflow that owns iOS PR verification: `xcodegen generate` → `swiftlint lint --strict` → warnings-as-errors `build` → `test`, triggered by **Pull Request Changes** (and **Branch Changes** on `main`), scoped to `ios/**` file filters.
- Add `ios/TimeOfLife/ci_scripts/` (`ci_post_clone.sh`, `ci_pre_xcodebuild.sh`) reproducing the `ios.yml` steps on Cloud (pinned `xcodegen` + `swiftlint`, `normalize-system-capabilities.py` post-generate hook).
- Strip the expensive triggers from `.github/workflows/ios.yml`: remove `pull_request` (and `push`) triggers, keeping `workflow_call` so `release.yml: verify` still reuses it for release verification. `backend.yml` and `openspec.yml` are untouched.
- Register the Xcode Cloud build as a required GitHub status check (branch protection) so PRs stay blocked on red iOS signal (S6 preserved, different provider).
- Update `docs/ci.md` (+ `docs/project-context.md` CI section if wording drifts) to document the new split: GitHub = backend/openspec/release-verify; Xcode Cloud = iOS PR checks.
- Roll out in stages: Cloud advisory → Cloud required → GH iOS triggers removed, with billed-minutes measured before/after.

## Capabilities

### New Capabilities

None — CI provider move, no app behavior change.

### Modified Capabilities

None — no baseline spec requirement changes. This change sets `skip_specs: true` (pure tooling, per precedent `2026-10-02-fix-101-manage-list-plus-animation`).

## Impact

- Affected: `.github/workflows/ios.yml` (triggers), `.github/workflows/release.yml` (`verify` wiring — no logic change, still `uses: ios.yml`), `ios/TimeOfLife/ci_scripts/` (new), `ios/TimeOfLife/project.yml` (only if Cloud needs scheme/test-plan adjustments — avoid), `docs/ci.md`, App Store Connect workflow config (UI-managed, not in repo) + GitHub branch-protection settings.
- Not affected: app code, `LocalStore`/sync/auth behavior, OpenAPI contract, backend deploy, `openspec` gate, AI review.
- External dependency: Xcode Cloud (Apple Developer Program team `7923U48U87`, free 25 compute-hours/mo).
  - ctx7 library ID: `/websites/developer_apple_xcode`
  - Queries used: `Xcode Cloud workflows GitHub pull request checks`; `Xcode Cloud custom build scripts ci_scripts xcodegen swiftlint`; `Xcode Cloud pricing compute hours free subscription`
  - Version pin: pin at implementation time to the repo's current toolchain (Xcode 16+, iOS 18 simulator, `xcodegen`/`swiftlint` versions matching local `brew` at implementation; record exact pins in design.md §Decisions when the spike lands).
- Cost model after: ~0 GitHub macOS billed minutes for PRs; iOS verification meters against the 25h/mo Xcode Cloud pool (measured ~1.4h wall/day at current cadence — inside the pool; overage needs a paid plan, explicitly out of scope now).

## Non-goals

- No TestFlight/upload automation, no release-flow redesign beyond keeping `verify` green.
- No backend/openspec/AI-review CI changes.
- No self-hosted macOS runner.
- No purchasing an Xcode Cloud paid tier in this change (revisit only if usage exceeds 25h/mo).
- No branch-protection redesign beyond requiring the Cloud check; repo currently has no protection (API returns 404) — this change adds the minimum, not a full ruleset.
