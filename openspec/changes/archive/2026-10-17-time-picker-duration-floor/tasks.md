## 1. Research bundle + picker spike

- [x] 1.1 Refresh the ctx7 research bundle (max 5 queries: SwiftUI `DatePicker in:` range semantics + HIG pickers + form-validation best practice) against the implementation-time SDK; record library IDs, queries, and pin (iOS 18 SDK via Xcode 16+). Baseline bundle with IDs/queries already lives in proposal.md — confirm or supersede it.
- [x] 1.2 Simulator spike: `.wheel` `DatePicker` with `in:` range — do out-of-range times grey out (unchoosable) or snap back? Record minute-quantization at the bound (e.g. Start 1:00:30 → effective bound 1:01 or 1:02) and same-day vs later-day behavior. Recorded evidence required; implementation tasks depend on it. If wheels do not actually prevent out-of-range selection, STOP and revisit the spec (VM clamp-back fallback) — do not implement around it silently.

## 2. View-model (`LogTimeViewModel`)

- [x] 2.1 Always-preserve `setStartsAt`: `endsAt += newStart − oldStart` for every Start write (earlier or later, date or time sourced); retire `lastValidDuration`'s collision role (keep only as CREATE-default source if still referenced).
- [x] 2.2 Untouched/touched tracking: add `timesTouched` flag (flips only in the time-picker setters) plus prefill snapshot; untouched sub-minute drafts keep the legacy gate (`endsAt > startsAt`); touched drafts require `endsAt − startsAt >= 60s` in both `isAddEnabled` and `save()`.
- [x] 2.3 Grandfathered save: untouched save writes back the original backing times (name/category/notes-only edits never alter times); touched save writes the draft.
- [x] 2.4 Subtitle helper: `durationSubtitleSeconds` returns true draft seconds for grandfathered drafts (e.g. 33s), nil only on the invalid path (confirm disabled by interval).

## 3. View (`LogTimeView`)

- [x] 3.1 End picker ranges: End date `in:` from Start day; End time `in:` from `start+60s` on the End day when End day == Start day, unbounded on later days; Start pickers unbounded. Bounds recompute live from the draft.
- [x] 3.2 Display mapping for untouched sub-minute drafts: Start pill `floor(start)`, End pill `floor(start)+60s`, pickers' `selection` getters return the mapped pair; setters mark `timesTouched` then write normally (adopt-then-apply order — no double-shift with always-preserve).
- [x] 3.3 No new strings unless review asks (reuse invalid-interval copy); any new copy goes to EN + RU `L10n` (U4); `Theme` colors only.

## 4. Tests

- [x] 4.1 VM unit tests: start-earlier preserves (2:35→1:00 shifts end 3:35→2:00), start-later preserves, end move never moves start, untouched 33s draft enabled + saves originals, touched draft requires ≥60s, first-touch adoption order, floor-not-round mapping (0:00:15–0:00:25 → pills 0:00/0:01).
- [x] 4.2 Run full iOS suite (`xcodebuild test -scheme TimeOfLife`, one simulator, per `docs/ios-test-loop.md`) and `swiftlint lint --strict` green.

## 5. Verification + docs

- [x] 5.1 Re-check FURPS `Timetracking.md` F13 against the new gate/floor wording; update the row.
- [x] 5.2 Confirm no other baseline/spec, OpenAPI, or `docs/project-context.md` surface is affected (no store/sync/API change by design); `gofmt`/`go vet` untouched (no backend diff).
- [x] 5.3 Manual smoke on simulator per `README.md` checklist: CREATE preserve-both-directions, end-floor unpickable, legacy 33s EDIT category-only save + first-touch adopt.

## 6. Second-dropping on first touch (follow-up corner)

- [x] 6.1 Generalize normalization: `displayStartsAt` unconditional minute floor, `displayEndsAt` floor except grandfathered (+60s rule); `adoptDisplayValuesIfNeeded` triggers on any untouched draft with pre-touch snapshot (provably floor-safe for ≥60s drafts).
- [x] 6.2 Tests: seconds-draft display mapping, both first-touch examples (2m24s→2m, 2m29s→3m), move-after-normalize delta path.
- [x] 6.3 Artifact updates: entry-editor display-mapping requirement, design touch-to-adopt, F13 seconds sentence; re-validate the change.
