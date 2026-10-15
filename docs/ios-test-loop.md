# iOS test loop (agent guide)

Fast, non-flaky `xcodebuild test` usage for this repo. All timings measured 2026-09-24 on this machine (Xcode 27.0, warm ~1.7 GB DerivedData, 463 tests / 44 suites in `TimeOfLifeTests`): **full suite <30s warm** (`build-for-testing` ~9s + test execution ~8–15s); filtered `SyncControllerTests`+`LocalStoreTests` (~110 tests) **~7s**; `swiftlint lint --strict` (~130 files) seconds. Anything warm taking longer than **~120s is stalled, not slow** — kill it and investigate; never just raise the timeout.

## The loop (from `ios/TimeOfLife/`)

```bash
# 0. Resolve a BOOTED simulator by ID (never by name — see below).
UDID=$(xcrun simctl list devices available -j | python3 -c \
  'import json,sys; ds=json.load(sys.stdin)["devices"]; print(next(d["udid"] for rt in ds for d in ds[rt] if d.get("isAvailable") and d["state"]=="Booted" and "iPhone" in d["name"]))')

# 1. Build once …
xcodebuild build-for-testing -scheme TimeOfLife \
  -destination "platform=iOS Simulator,id=$UDID"

# … then iterate with test-without-building + filters (slash form; dot form is rejected):
xcodebuild test-without-building -scheme TimeOfLife \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:TimeOfLifeTests/SyncControllerTests \
  -only-testing:TimeOfLifeTests/LocalStoreTests
```

Full suite only at milestones (same commands minus `-only-testing`). Run `xcodegen generate` only when `project.yml` changed; run `swiftlint` once per change-set, not per iteration.

## Rules (each earned by a real incident)

1. **One `xcodebuild` at a time, across all agents/subagents.** Concurrent runs serialize on the DerivedData lock and look like hangs. This is also in `AGENTS.md` → Flow recommendations.
2. **Destination = booted sim by ID.** `name=iPhone 17` matches 3+ devices across the iOS 26.4/27.0 runtimes (booted, shutdown, and unavailable-runtime entries); `generic/platform=iOS Simulator` is build-only, not for tests.
3. **Never pipe long runs to `tail`.** `xcodebuild … 2>&1 | tail -6` swallows all progress: on 2026-09-24 a full-suite run under parallel machine load (docker postgres + backend repro server + 3 booted sims) exceeded the 600s tool timeout and produced literally `(no output)` — a slow run was indistinguishable from a hang. Stream to a log file in background and poll instead:
   ```bash
   ( xcodebuild test -scheme TimeOfLife -destination "platform=iOS Simulator,id=$UDID" > /tmp/suite.log 2>&1; echo "EXIT=$?" > /tmp/suite.done ) &
   # poll: tail /tmp/suite.log; grep for TEST SUCCEEDED / error:; compare elapsed vs the 120s budget
   ```
4. **Do not use `-parallel-testing-enabled`** for this suite: measured 39s vs 7s for the filtered pair, and it powers down the shared booted simulator as a side effect.
5. **Keep DerivedData warm; never `clean`.** Warm cache is the entire reason runs take seconds (cold GRDB.swift builds take minutes). `test-without-building` only wins when the sim is already booted — otherwise boot time erases the saving (measured 26s vs 7s).
6. **Warnings-as-errors live in `project.yml` (target-scoped).** Do not pass them as CLI flags — they conflict with the `-suppress-warnings` flag Xcode adds to the GRDB SPM target.
7. **Worktrees isolate trees, not devices.** Running from `timeOfLife.wt/<change>` does not lift rules 1–2: still one `xcodebuild` at a time across all worktrees/agents, still the same booted sim by ID. After a rebase onto `origin/main`, re-run the affected suites — the base moved under you.

## If a run stalls (>120s warm)

1. Read the log tail: build phase vs test phase vs `error:` lines.
2. `ps aux | grep xcodebuild` (is it compiling or waiting?), `xcrun simctl list devices | grep Booted` (did the sim shut down? boot it by ID and retry).
3. Kill, retry once on the booted-by-ID destination. If it still hangs, bisect with `-only-testing` per suite/file — file the hanging test name as the bug, not "xcodebuild is slow".
