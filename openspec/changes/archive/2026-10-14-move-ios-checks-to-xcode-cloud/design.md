## Context

See proposal.md — Why. Current state: `ios.yml` (`lint-build-test` on `macos-15`) runs `brew install xcodegen swiftlint` → `xcodegen generate` (plus `postGenCommand: normalize-system-capabilities.py`, required by yonaskolb/XcodeGen#1637) → `swiftlint lint --strict` → warnings-as-errors `xcodebuild build` (per-target flags in `project.yml`; CLI flags forbidden — GRDB `-suppress-warnings` conflict) → simulator-resolved `xcodebuild test | xcpretty`. The generated `.xcodeproj` is gitignored, so any clean-clone CI (Cloud included) MUST generate before building. `release.yml: verify` reuses `ios.yml` via `workflow_call` (GITHUB_TOKEN pushes trigger no workflows). Constraints: LocalStore chokepoint, XcodeGen-managed project, per-config signing (Debug unsigned — Cloud PR builds must stay on Debug/simulator, never Release signing), S6 mandatory checks stay green-or-blocked.

## Goals / Non-Goals

**Goals:**
- Zero GitHub macOS billed minutes for PR verification; iOS signal comes from Xcode Cloud inside the 25h/mo pool.
- Bit-for-bit check parity: same generate → lint → build → test semantics, same failure modes block merge.
- Reviewable rollout: every stage leaves `main` protected by exactly one required iOS signal (never zero, never double-billed).

**Non-Goals:**
- No TestFlight, archiving, or signing changes; no paid Cloud tier; no self-hosted runners (see proposal.md).

## Decisions

1. **Cloud owns the full PR check (generate+lint+build+test), not a split.** Alternative (GH keeps swiftlint, Cloud does build+test) was considered: it leaves residual macOS billing and two required signals to coordinate. Full move kills the 10× meter in one cut; the `ci_pre_xcodebuild.sh` lint step fails the build early, preserving fast feedback.
   - ctx7: `/websites/developer_apple_xcode` — `Xcode Cloud custom build scripts ci_scripts xcodegen swiftlint` (three script types, `ci_scripts/` beside the project, `zsh` default, no `sudo`, created files deleted after run).
2. **Extend `ci_post_clone.sh`, add `ci_pre_xcodebuild.sh` (repo-owned, reviewable).** The repo already runs Cloud tag-archives with a `ci_post_clone.sh` that brew-installs xcodegen and generates (Sep 30 commits: shared scheme + `Package.resolved` tracked for Cloud) — this change extends it with a fail-closed `XCODEGEN_PIN=2.46.0` assert and a `.xcodeproj` existence check, and adds `ci_pre_xcodebuild.sh` running pinned `SWIFTLINT_PIN=0.65.0` + `lint --strict` so PR builds fail fast. Lint also gates tag archives (no-op: tags build from lint-green main). Neither script is added to any Xcode target; `ci_scripts/` sits beside the generated `.xcodeproj` per Apple's layout.
   - ctx7: `/websites/developer_apple_xcode` — same query as above (post-clone/pre-xcodebuild/post-xcodebuild conventions, executable + shebang requirements). Re-verified 2026-10-12 at implementation time (task 1.1): conventions unchanged.
   - Pins recorded 2026-10-12 (task 1.1; local toolchain that day): `xcodegen 2.46.0`, `swiftlint 0.65.0`, `Xcode 27.0 (27A266a)`, iOS 18 simulator, `python3` present. `ci_post_clone.sh` installs via brew then asserts these exact versions fail-closed (no silent drift); Cloud Xcode selection pinned to the nearest 27.x at workflow creation (task 2.2). **2026-10-12 spike finding (PR #147 advisory build): Cloud brew serves `swiftlint 0.65.1` — pin bumped to `0.65.1`, local toolchain upgraded to match, `lint --strict` re-verified 0 violations. Second finding: Test-action VMs replay `ci_pre_xcodebuild.sh` from clone-root (`<clone-root>/ci_scripts`), not its repo location — the script now resolves the project via the `.swiftlint.yml` marker (adjacent, else `<git-root>/ios/TimeOfLife`) and skips exit-0 when sources are absent.**
3. **Start conditions mirror today's path filters.** Xcode Cloud workflow: **Pull Request Changes** (source: any, target: `main`) + **Branch Changes** (`main`), with file filters scoped to `ios/**` + `.github/workflows/ios.yml` equivalents. Prevents `backend/`-only PRs from burning Cloud hours, mirroring `on: pull_request paths:`.
   - ctx7: `/websites/developer_apple_xcode` — `Xcode Cloud workflows GitHub pull request checks` (PR Changes merges source+target in temp env; source/target branch settings; custom file conditions).
4. **GitHub status check becomes the S6 gate.** Connect App Store Connect ↔ GitHub (Checks/Statuses write perms), require the Cloud build (or its test action) in branch protection. `ios.yml` loses `pull_request`/`push` triggers but keeps `workflow_call` so `release.yml: verify` is untouched.
   - ctx7: `/websites/developer_apple_xcode` — `Xcode Cloud workflows GitHub pull request checks` → `configuring-requirements-for-merging-a-pull-request` (GitHub status checks, require build or action).
5. **Stay on Debug/simulator, Xcode pinned.** Cloud workflow uses the `TimeOfLife` scheme, Debug configuration, iOS Simulator destination, `OS=latest` matching today's `steps.sim` resolution. No Release signing, no device builds, no entitlements beyond what Debug already carries.

## Risks / Trade-offs

- [Risk] App Store Connect workflow config is UI-managed, not PR-reviewable → Mitigation: `ci_scripts/` + this design are the reviewed source of truth; screenshot/record workflow settings in the PR; any reconfiguration repeats the verify task.
- [Risk] `brew install` on Cloud is slow/uncached and version-drifts vs local → Mitigation: pin versions in `ci_post_clone.sh`; spike measures install time; fallback: vendor binaries or `mint`-pinned SwiftLint.
- [Risk] Xcode version on Cloud ≠ local 16+/27.0 (warnings-as-errors surface differs, GRDB suppress-warnings interplay) → Mitigation: pin Cloud Xcode version to nearest matching; record in `docs/ci.md`; mismatch failures are fixed by pinning, not by relaxing `--strict` or per-target flags.
- [Risk] Usage exceeds 25h/mo at higher cadence (Cloud parallelization bills differently from wall time) → Mitigation: measure in transition (usage CSV export in App Store Connect); file filters + advisory→required staging cap waste; paid tier is a separate future decision.
- [Risk] Double-signal or zero-signal window during migration → Mitigation: staged rollout (Migration Plan); at most one required iOS signal at any commit.
- [Risk] `release.yml: verify` still burns one GH macOS run per release → Accepted: infrequent (manual dispatch only), keeps release verification independent of Cloud; documented as intentional residue.
- Trade-off: `xcpretty` output and GH log ergonomics are lost; Cloud logs + App Store Connect build links replace them. AI-review log parsing (if any) must read Cloud links.

## Migration Plan

1. Land `ci_scripts/` + Cloud workflow in **advisory** mode (status posts, not required). GH `ios.yml` unchanged. Verify a test PR shows both signals green.
2. Flip branch protection: Cloud build **required**, GH iOS still present but non-required (one commit window).
3. Remove `pull_request`/`push` triggers from `ios.yml` (keep `workflow_call`); update `docs/ci.md`. Confirm next PR shows only the Cloud signal and zero GH macOS minutes accrue.
4. Soak one week: compare Cloud usage CSV vs prior GH billed minutes; report in the PR/issue.
5. Rollback: revert the `ios.yml` trigger deletion (one-commit revert restores GH checks); Cloud workflow stays advisory until deleted in App Store Connect.

## Open Questions

None — usage-pool headroom (25h vs ~1.4h wall/day) was asserted by the owner in the issue thread; the soak step (task 4.2) verifies it empirically rather than blocking the design.
