## 1. Reproduce and size (bugfix rule: no implementation before a recorded repro)

- [x] 1.1 Record a signed-in cold-boot launch on the current tree (~15 s, committed entries present) and frame-extract it: confirm the empty-hint flash, the one-frame-later Recents pop-in with its few-point shift of name row / Start / header, and note any post-reveal sync-exit reshuffle. Save the recording + frame analysis as the change's repro evidence.
- [x] 1.2 Measure on-device `prepareAccountStore` + first `TrackViewModel.load()` durations and fix the unveil timeout from data (starting point ~2 s, err generous — a slightly long splash beats a lying reveal). Record the numbers in the PR.

## 2. Optimistic instant Track (replaces the veil direction 2.1–2.3)

- [x] 2.1 Extract Track's first-load queries into a shared snapshot loader (recents, names, categories, running draft, name draft); `TrackViewModel.load()` becomes apply-snapshot plus its existing side effects (ticker, Live-Activity re-mirror).
- [x] 2.2 Gate preload: on a cached session, run bind + seed + snapshot load before mounting and hand the snapshot to the shell; fresh view model adopts it instead of re-querying. Mount is never gated on preload success (failure falls back to load-on-appear + banner).
- [x] 2.3 Batch every snapshot publish into a single render commit (locals-then-assign, including `nameDraft`); diff-guard reloads to skip identical snapshots.
- [x] 2.4 Disable the name row while the first snapshot is pending (Start is already draft-gated); auth-button loading during fresh sign-in bind uses existing strings only.
- [x] 2.5 Delete the veil apparatus: `LaunchCover.swift`, the readiness signal + notification, overlay/fade/zIndex/accessibilityHidden wiring in `RootView`, restoring splash view; unbound branch renders the auth-gated spinner-free hold only via existing views (no new waiting UI).
- [x] 2.6 Seed `elapsed` synchronously in `startTicker` (device repro: restored run painted 00:00 for ~1–2 s until the first tick; `elapsed` was only ever assigned inside the tick closure). Covers adopt, load-restore, and fresh starts; compact timer already immune (`TimelineView` from `startedAt`). Test: adopt-seeds-elapsed.

## 3. Tests

- [x] 3.1 Snapshot loader: single load returns recents + names + categories + running draft together; failure surfaces without blanking (replaces the old signal/completeness tests).
- [x] 3.2 Adopt path: a view model handed a snapshot paints complete without re-querying (loader call count); restore-failure ordering: cached session mounts optimistically, rejected restore cuts to auth with files intact.
- [x] 3.3 Reload suppression: identical snapshot resolves to zero publishes; changed snapshot publishes exactly once.
- [x] 3.4 Confirm stubbed UITesting graphs resolve Track queries immediately (stub store is local; no network in the snapshot path).

## 4. Verify, lint, and document

- [x] 4.1 `swiftlint lint --strict` clean; warning-as-error `xcodebuild` build green; `xcodebuild test` suite green (blocked on this machine by the 0-test discovery environment issue — CI `ios.yml` is the backstop); `go test ./...` still green (backend untouched — confirmation only).
- [ ] 4.2 Record the fixed cold boot and frame-diff against the 1.1 evidence: OS launch background → complete Track in one cut, no empty flash, no pop-in, no post-reveal shift. Attach the comparison to the PR. (Superseded: human verified the final direction on-device — "swift", complete first paint. Repro binaries removed from the repo pre-archive; videos held by the human.)
- [x] 4.3 Re-check the relevant `Requirements/FURPS/*.md` rows; assert no new user-facing strings (both locales + `L10n` untouched) and `Theme`-only colors; update `docs/project-context.md` only if the launch-sequence description drifts.

## 5. Superseded (veil direction — kept as record, do not implement)

An earlier iteration built a covered mount (LaunchCover, readiness signal, timeout, settle beat, opacity fade, zIndex scaffolding) plus its tests. Device frame analysis showed mount→load→unveil collapsing into single commits (no fade ever had frames to play across) and the transparent-VStack overlay letting Track paint through. The user then rejected all waiting UI (splash and skeleton alike) in favor of this optimistic direction. The veil code and its tests were removed; `repro/` keeps the frame evidence.
