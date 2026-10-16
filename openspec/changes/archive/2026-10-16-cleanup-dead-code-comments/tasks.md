## 1. Baseline

- [x] 1.1 `git fetch origin` + rebase onto `origin/main`; re-run affected linters/tests after the rebase.

## 2. iOS dead-code deletions (zero-reference proof per item)

- [x] 2.1 Delete `Core/Design/Components/EditorSheetScaffold.swift` after confirming `measuredBottomBar` has no other callers; if `Core/Utilities/BottomBarMeasurement.swift` and `PresentationMetrics.swift` are reference-free, delete both, otherwise leave them and note why.
- [x] 2.2 TRIAGED — both keys have live callers (`WelcomeView:107`, `ProfileView:180`); the explore-time zero-use claim was wrong. Kept, no change.
- [x] 2.3 Remove write-only `APIClientHolder.client` (`AppContainer.swift:340`) + its single write (`:330`).
- [x] 2.4 Delete `TimeOfLifeTests/TrackLayoutSpike.swift` (retired harness, test-bundle-only).
- [x] 2.5 Fix the `SectionHeader` editor-usage example in `Design/COMPONENTS.md` (no production editor caller; `CategoryEditorView:63` renders plain `Text`).

## 3. Config deletions

- [x] 3.1 Merge the duplicated `backend.yml:63-69` coverage summary + gate steps into one.
- [x] 3.2 Extend `backend/Makefile:2` `.PHONY` with the real targets and make `lint` fail on `gofmt -l` output.
- [x] 3.3 Drop the per-target `deploymentTarget` layer in `ios/TimeOfLife/project.yml`, fix the stale `0.1.4/5` version comment, run `xcodegen generate`, and confirm the `.pbxproj` diff is empty.
- [x] 3.4 Drop the dead `apk add gcc musl-dev` layer in `backend/Dockerfile` and verify `go build ./...`.

## 4. Prevention gate (#168 acceptance)

- [x] 4.1 Append the commented-out-Swift grep to `ios/TimeOfLife/ci_scripts/ci_pre_xcodebuild.sh` (scoped to Swift source dirs, code-token heuristics, `MARK:`/`///`/URLs excluded); verify it passes on the tree and trips on a temporary planted violation (removed afterwards).

## 5. Comment compaction (keeps in design.md §Decisions-3 stay untouched)

- [x] 5.1 Backend: delete restatement one-liners (`cmd/server/main.go`, `handlers/auth.go:365-396`, `db_test.go:456,463`, `sqlite.go:76`, `config.go:62`); compact `config.go:59-60`; cull banners (`handlers/auth.go`, `db/store.go:175,197,232`, `catalog_validators.go:165,199`, `server.go:216,295`) keeping ≤3 per file. EXCEPTION: `revive` exported-rule doc headers on exported symbols (`store.go` ×3, `sender.go` ×5) restored byte-identical — the linter mandates them.
- [x] 5.2 iOS: compact `AppleSignInButton.swift:5-19`, `ActiveAccountFileResolver.swift:3-21`, `AppleSignInService.swift:7-11,48-52`, `TrackViewModel.swift:8-14`; cull micro-group `MARK:` splits (`TagSelector.swift:61,83`, `RecentActivitiesChips.swift:68,97`, `TrackContent.swift` to ≤3, duplicate `Helpers` in `SyncControllerTests` + `TrackSyncReloadTests`).
- [x] 5.3 Spot-check the diff to confirm the five keeps are byte-identical.

## 6. Docs truth fixes (assert code/spec truth only, no new claims)

- [x] 6.1 Correct baseline counts to 24 + fix "no active change" and "`ios.yml` deleted" claims (`docs/project-context.md`, `README.md`, `AGENTS.md`, `openspec/config.yaml`, `openspec/README.md`).
- [x] 6.2 Convert partial archive enumerations to pointers at `openspec/changes/archive/`.
- [x] 6.3 Read the Recents limit constant in code, align all five doc sites to it (flag, don't change, if ambiguous).
- [x] 6.4 Fix `openapi.yaml` `servers:` example to `http://127.0.0.1:8080`.
- [x] 6.5 Drop delivered-but-listed bullets (`via <Source>`, UndoToast-as-missing, Live Activities conflation, shipped History paragraph under Deferred); fix the pre-gate Enable Sync paragraph in `Requirements/Usecases/Sign-up_and_Sign-in.md`; trim `docs/history-roadmap.md` to live deferred content.

## 7. Verification and hand-off

- [x] 7.1 Backend green: `gofmt -l .` empty, `go vet ./...`, `golangci-lint run`, `go test ./... -cover`.
- [x] 7.2 iOS green (serialized, one `xcodebuild` at a time): `swiftlint lint --strict`, warning-free build, full `xcodebuild test` on a booted sim.
- [x] 7.3 `openspec validate --all --strict` green; re-check relevant `Requirements/FURPS/` rows.
- [x] 7.4 File follow-up issues for the non-goals (prod compose env wiring, `timeoflife-net` creation, letsencrypt bootstrap, `analyzer_rules`/`--analyze` decision, suspicious API triage).
