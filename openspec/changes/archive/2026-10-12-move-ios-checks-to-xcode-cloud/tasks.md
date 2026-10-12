## 1. Grounding and baseline

- [x] 1.1 Re-run ctx7 fetch at implementation time (`npx ctx7@latest library` → `docs` for `/websites/developer_apple_xcode`: PR-check workflows, `ci_scripts` conventions, Cloud usage/subscription) and record exact `xcodegen`/`swiftlint`/Xcode pins in design.md §Decisions
- [x] 1.2 Measure baseline: export last-30d `ios` workflow wall-minutes via `gh run list` + jobs API, compute billed minutes (×10), paste figure into the PR body for #136
- [x] 1.3 Re-read Requirements/FURPS S6 rows (mandatory PR checks) and confirm the Cloud-check substitution keeps the requirement satisfied; file any wording conflict as a requirements fix in the same PR

## 2. Cloud workflow spike (advisory mode)

- [x] 2.1 Add `ios/TimeOfLife/ci_scripts/ci_post_clone.sh` (pinned `xcodegen` + `swiftlint` install, `xcodegen generate`, generated-project drift assert) and `ci_pre_xcodebuild.sh` (`swiftlint lint --strict`); `chmod +x`, both with shebangs, no `sudo`
- [x] 2.2 Create the Xcode Cloud workflow (Debug config, `TimeOfLife` scheme, simulator destination): Pull Request Changes (target `main`) + Branch Changes (`main`) start conditions, file filters for `ios/**`; leave GitHub-side non-required (advisory)
- [x] 2.3 Open a test PR touching `ios/**` plus a control PR touching only `backend/**`; verify Cloud runs only on the former and both GH + Cloud signals post on the former

## 3. Cutover

- [ ] 3.1 Flip branch protection: Xcode Cloud build (or its test action) set to required required status check
- [x] 3.2 Strip `pull_request`/`push` triggers from `.github/workflows/ios.yml`, keeping `workflow_call` for `release.yml: verify`; validate YAML parses and `release.yml` still references it
- [x] 3.3 Update `docs/ci.md` (new provider split, Cloud workflow settings, pin table, log locations); update `docs/project-context.md` CI wording only if it drifted

## 4. Verify and soak

- [x] 4.1 Local parity: `xcodegen generate` diff clean, `swiftlint lint --strict` green, simulator `build` + full `test` green per `docs/ios-test-loop.md` (one `xcodebuild` at a time, booted-sim-by-ID)
- [x] 4.2 `openspec validate --all --strict` green on the change
- [ ] 4.3 Soak one week on `main`: export Xcode Cloud usage CSV vs GitHub macOS billed minutes for the same window; post the comparison on #136 and confirm usage sits inside the 25h/mo pool
- [x] 4.4 Rollback drill (dry): confirm reverting the `ios.yml` trigger deletion restores GH checks as the required signal; document the revert commit shape in the PR body
