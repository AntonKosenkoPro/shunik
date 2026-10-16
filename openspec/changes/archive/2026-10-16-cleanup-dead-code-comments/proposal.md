## Why

`SectionHeader` carried two dead knobs plus commented-out runtime lines across many changes without anyone noticing (issue #168, precedent fixed in PR #158 §9). A read-only sweep of the post-#158 tree (`49435b5`) found the same rot class in a few more places — dead component API, write-only properties, retired harnesses, stale config comments — plus bloated restatement comments and docs that contradict the code. Dead API invites misuse and slows readers; fix it in one scoped pass with a cheap prevention gate.

## What Changes

- **iOS dead-code removal (provably-unused only):** delete `EditorSheetScaffold.swift` (zero instantiations); remove `L10n.authGateTitle` + `L10n.profileOnDeviceFooter` (+ their `.strings` lines and `LocalizationTests` key-list pins); remove write-only `APIClientHolder.client` (+ its single write); delete retired test-harness `TrackLayoutSpike.swift`.
- **Config dead-code removal:** merge the duplicated `backend.yml` coverage steps; extend `backend/Makefile` `.PHONY` and make `lint` fail on unformatted output; drop one duplicated `IPHONEOS_DEPLOYMENT_TARGET` layer + fix the stale `0.1.4/5` version comment in `project.yml`; drop the dead `apk add gcc musl-dev` layer in `Dockerfile` (`CGO_ENABLED=0`).
- **#168 prevention gate (agreed, not skipped):** a ~5-line POSIX grep in `ios/TimeOfLife/ci_scripts/ci_pre_xcodebuild.sh` rejecting commented-out Swift code (`^\s*//` + code tokens) over the Swift source dirs. Backend needs no gate (`golangci-lint` `unused` + `staticcheck` already cover Go; sweep found zero hits).
- **Comment compaction:** delete restatement one-liners, compact signature-repeating doc headers to one line, cull per-micro-group `MARK:`/`-----` banners (keep ≤3 per file). The five `why/contract/invariant` keeps (refresh-revocation ordering, GRDB deadlock, `TRUSTED_PROXIES` rationale, cycle-attach race, file-first cfprefsd note) are explicitly out of touch.
- **Docs truthfulness fixes (bounded):** correct baseline counts (`20`→`24`, README `19`→`24`); fix "no active change" and "`ios.yml` deleted" claims; align the Recents cap to the code constant; fix `openapi.yaml` `servers:` to `127.0.0.1:8080`; drop delivered-but-listed bullets (`via <Source>` rows, UndoToast-as-missing, Live Activities conflation, shipped History paragraph inside Deferred); fix the pre-gate "Enable Sync" paragraph in `Requirements/Usecases/Sign-up_and_Sign-in.md`; fix the `SectionHeader` editor-usage example in `Design/COMPONENTS.md` (no production editor caller — `CategoryEditorView:63` renders plain `Text`).

## Capabilities

### New Capabilities

- None — no product behavior changes.

### Modified Capabilities

- None — no spec-level requirement changes. This change sets `skip_specs: true` in `.openspec.yaml` (pure refactor, tooling, and docs).

## Impact

- **iOS app + tests:** 4 dead-code deletions; comment-only edits elsewhere; `LocalizationTests` key-list shrinks by 2 (coverage unchanged — the pinned keys had no production users).
- **CI:** one additive grep step in the Xcode Cloud pre-build script (fails PR builds with commented-out Swift); `backend.yml` step merge (no pipeline semantics change); local-only `make lint` becomes fail-closed.
- **Docs:** `docs/project-context.md`, `README.md`, `AGENTS.md`, `openspec/config.yaml`, `openspec/README.md`, `docs/history-roadmap.md` (live-content only), `Design/COMPONENTS.md`, `backend/api/openapi.yaml` (`servers:` example only), one FURPS-adjacent Usecases paragraph.
- **No API, schema, on-disk, or user-visible changes.** Backend Go needs zero edits (sweep-verified clean).

## Non-goals

- No behavior changes of any kind; suspicious-but-unproven items stay (`SyncController.waitForCycleEnd`, `LocalStore` struct-CRUD/test-fixture overloads, `OtpCodeField.length`, `ClearButtonVisibility(isLocked:)`, `BottomBarMeasurement`/`PresentationMetrics`, `swiftlint` disabled-rules/`analyzer_rules`, `backend.yml` deploy semantics, action/image version upgrades).
- No prod-deploy wiring changes (compose `CORS_*`/TTL/timeout gaps, `timeoflife-net` creation, letsencrypt bootstrap) — recorded as follow-up issues, not this change.
- No full docs restructure (Requirements/Usecases archaeology, `DECISIONS.md` annotations, `Entry_Catalog_API.md` contract-copy dedup stay as-is).
- No Recents product decision: docs align to the code constant; if the code is ambiguous, the value is flagged, not changed.

## Research bundle (waivers with evidence)

- HIG N/A — no UI or behavior change (deletions + comment/docs edits only).
- Apple API N/A — no SDK involved; the gate is POSIX `grep`, no library semantics.
- Topic/best-practice N/A — repo-internal refactoring; detection evidence is the six-area read-only sweep on `49435b5` (zero commented-out blocks repo-wide, Go covered by installed `unused`+`staticcheck`).
