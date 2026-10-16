## Context

See proposal.md (Why) for motivation. Current state: post-#158 tree at `49435b5`, verified by a six-area read-only sweep — zero commented-out code blocks repo-wide, Go surface clean under installed `unused`+`staticcheck`, ~35 comment-bloat samples catalogued with `file:line` dispositions, docs contradictions pinned to exact lines. Constraints: zero behavior change; `LocalStore` chokepoint untouched (no store edits at all); app/test warnings-as-errors via `project.yml`; one `xcodebuild` at a time; single-writer files (`project.yml`, `openapi.yaml`, `Localizable.strings` pairs, `ci_pre_xcodebuild.sh`) serialized at apply time.

## Goals / Non-Goals

**Goals:** remove only provably-unused code (evidence standard below); compact comments without touching rationale; fix docs where they contradict code; land a green-day-one prevention gate.

**Non-Goals:** no test-fixture extraction (struct-CRUD overloads stay), no prod-deploy semantics, no lint-rule tuning beyond the gate, no docs restructuring (enumerations become pointers, not rewrites).

## Decisions

1. **Cut line: repo-wide zero-reference proof.** An item is deletable only if `grep` finds no reference in app, tests, previews, widget targets, and docs examples. This standard is why `EditorSheetScaffold`, the two `L10n` cases, `APIClientHolder.client`, and `TrackLayoutSpike` qualify — and why `OtpCodeField.length`, `waitForCycleEnd`, and struct-CRUD overloads do not (test/preview callers exist).
2. **Prevention: POSIX grep in `ci_pre_xcodebuild.sh`, not a SwiftLint `custom_rules` entry.** The pre-build script is the every-PR gate (Xcode Cloud; `ios.yml` has no triggers). A `custom_rules` regex is noisier (`://` URLs, `// MARK:`, commented JSON examples need an allowlist) while grep with code-token heuristics (`func |let |var |class |struct |if |for |return ` after `//`) passes with zero hits today — green day one, non-noisy. Backend needs nothing (`unused`+`staticcheck` already gate Go).
3. **Comment triage in four dispositions.** Delete restatement one-liners (`// Load configuration`); compact signature-repeating doc headers to one line (keep only the non-obvious half, e.g. "All fields required"); cull banners to ≤3 `MARK:`/`-----` per file, deleting per-micro-group splits and duplicate `Helpers` sections; keep all five `why/contract/invariant` keeps verbatim (revocation ordering, GRDB deadlock, `TRUSTED_PROXIES`, cycle-attach race, file-first cfprefsd).
4. **Docs: fix contradictions in place, convert rotting enumerations to pointers.** Baseline counts (`20`→`24`, README `19`→`24`), "no active change" / "`ios.yml` deleted" claims, `servers:` URL, delivered-but-listed bullets, and the pre-gate Enable Sync paragraph are truth fixes. The partial archive enumerations (`project-context.md:69`, `openspec/README.md:14`, `AGENTS.md:14`) become a pointer at `openspec/changes/archive/` — enumerations rot on every archive, pointers don't.
5. **Recents cap: code constant is source of truth.** The task reads the code limit first and aligns all five doc sites to it; if the code is ambiguous the value is flagged, never changed.
6. **`project.yml`: drop the per-target `deploymentTarget` layer only**, keeping base `IPHONEOS_DEPLOYMENT_TARGET` + `options.deploymentTarget`. Proof of no behavior change: `xcodegen generate` followed by an empty `git diff` on the `.pbxproj`.
7. **`LocalizationTests` shrinks with the keys.** The two removed `L10n` cases have key-list pins; both pins go in the same edit or the suite fails. `.strings` edits always land as en+ru pairs (U4).
8. **Apply-time ownership.** Disjoint file sets per worker; `project.yml`, `openapi.yaml`, `ci_pre_xcodebuild.sh`, and each `.strings` pair have exactly one writer; verification (`swiftlint`, build, test) runs serialized after all edits.

## Risks / Trade-offs

- [Risk] A "provably-dead" item has a caller the grep missed (e.g. stringly-typed reference) → Mitigation: full backend + iOS suites green after every deletion batch; deletions land as one commit per area for bisectable revert.
- [Risk] Grep gate false-positives on a future legitimate comment → Mitigation: scoped to Swift source dirs with code-token heuristics; any hit is reviewed, not auto-fixed, and the pattern allows `// MARK:`, `///`, URLs by construction.
- [Risk] Docs truth-fixes drift from baselines → Mitigation: `openspec validate --all --strict` on the PR; edits only assert what code/spec already says, never new claims.
- [Risk] `xcodegen generate` produces diff noise → Mitigation: the empty-diff check in task 3 fails the change if the project edit alters generated output.
- [Trade-off] Suspicious-but-unproven items stay, so a second sweep will still find candidates → Accepted: recorded as follow-ups; a wrong deletion costs more than a leftover.
