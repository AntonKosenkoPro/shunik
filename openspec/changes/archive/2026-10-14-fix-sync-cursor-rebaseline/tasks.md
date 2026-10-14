## 1. Reproduction (repo rule S5 — no fix without a recorded repro)

- [x] 1.1 Write a failing `SyncControllerTests` upgrade test first: seed a poisoned `entry` cursor (partial-page max) with a multi-page mock relay history, run a cycle, and record that the tail never merges and the cursor never heals
- [x] 1.2 Confirm the failure on the current tree (expect: last-page rows missing locally, cursor stuck at the poisoned value)

## 2. Re-baseline primitive (LocalStore chokepoint)

- [x] 2.1 Add `LocalStore.rebaselineEntryCursorIfNeeded() -> Bool`: single write that, when no `entry_rebaseline` row exists in `sync_state`, deletes the `entry` cursor row and inserts `entry_rebaseline` = now (returns true); otherwise no-ops (returns false)
- [x] 2.2 Cover it in `LocalStoreTests`: first call with a cursor clears + flags, second call no-ops, nil-cursor file still flags without error

## 3. Cycle integration (SyncController)

- [x] 3.1 Call the re-baseline at `runCycle` entry after the account binding and before the first pull reads the cursor; leave the per-page guards, merge rules, and cursor advance untouched
- [x] 3.2 Turn the 1.1 repro green: poisoned cursor → full paged pull → all rows merged, cursor at the global max, flag set; assert `deletions` cursor, outbox, and categories unaffected
- [x] 3.3 Assert exactly-once: a second cycle after healing runs a normal delta (no cursor discard, `modified_since` = global max)

## 4. Contract + docs touch-up

- [x] 4.1 No `openapi.yaml` change (pagination contract already covers this) — verify the contract gate still passes
- [x] 4.2 Re-check the relevant `Requirements/FURPS/*.md` rows (F7 delta pull-sync) and extend for the one-time re-baseline

## 5. Verification (S5)

- [x] 5.1 Re-run the 1.1/1.2 repro on the fixed tree and record full convergence from a poisoned cursor
- [x] 5.2 Backend green (unchanged code, but the gate must stay green): `gofmt -l .` empty, `go vet ./...`, `golangci-lint run`, `go test ./... -cover`
- [x] 5.3 iOS green: `swiftlint lint --strict`, warning-clean `xcodebuild` build, `xcodebuild test` full suite green
- [x] 5.4 `openspec validate --all --strict` green on the change
