## 1. Reproduce on the current tree

- [x] 1.1 Record day-tap death on the unmodified tree (simulator screen recording + steps): CREATE sheet Start date picker → taps on 16th/20th dead (pill frozen); pushed EDIT → 16th dead too. Videos: `.argent/recordings/screen-recording-F132A44E-4F25-45E9-9092-990139466F4E-1792062845005.mp4` (CREATE) and `...-1792063022793.mp4` (EDIT, under `/Users/antonkosenko/work/timeOfLife/`).
- [x] 1.2 Differential in the same session: pills expand/collapse, wheel drag commits (14→20, End auto-push 15:10→21:10 — binding path healthy), chips/rows respond. Failure isolated to graphical-calendar interactions.
- [x] 1.3 Record stepper snap-back (frame-by-frame): Next tap → November renders → ~0.6s later tears back to October with zero interaction. Video: `screen-recording-F132A44E-4F25-45E9-9092-990139466F4E-1792085758233.mp4`.

## 2. Fix

- [x] 2.1 `FormCard`: tap-away from whole card to background layer (`FormCard.swift`); doc comment rewritten; `LogTimeView` header comment aligned.
- [x] 2.2 Picker containers: always-mounted, zero-height-collapsed, `GeometryReader`/opacity-transition removed (`LogTimeView.swift` `timeRow`); `.onTapGesture(count: 99)` FB9614392 guard on the graphical picker.
- [x] 2.3 `AppShellViewModel.startTicker()`: assign `runningTimer` only on real change (Equatable dedup); compact timer verified independent (`TimelineView` in `CompactTimer`).
- [x] 2.4 Only the five entry-form cards use `FormCard`; single-open, highlight, gate, save/delete, LOCKED untouched. Diff: 3 files.

## 3. Verify the fix

- [x] 3.1 Identical repro re-run: day tap updates pill/subtitle/gate, End auto-pushes, picker stays open (CREATE + EDIT; EDIT save regroups History). Videos: `...-1792063244858.mp4` (CREATE) + `...-1792066078435.mp4` (EDIT).
- [x] 3.2 Stepper verify: Next → November persists 5s+ untouched; Previous back; cross-month day tap (Nov 13 → Start + End auto-push, 1h kept); six-week November fully visible, no clipping.
- [x] 3.3 Full sweep: pills, chips, wheel drags, padding tap-away no-op, scroll with picker open, Name/Notes pushes, X-discard, Back/X navigation.
- [x] 3.4 `swiftlint lint --strict` 0 violations (176 files); `xcodebuild build` SUCCEEDED; full `xcodebuild test` — 660 tests / 64 suites passed; `go test ./...` all packages ok (no backend touch); FURPS F13 re-checked — aligned, no conflicts.
- [x] 3.5 Release device build + `devicectl` install + launch on physical iPhone; day/stepper verified on-device by user.

## 4. Docs and follow-through

- [x] 4.1 `FormCard`/`LogTimeView` comments updated; `docs/project-context.md` untouched (no architecture/contract change).
- [x] 4.2 `openspec validate --all --strict` green; repro videos attached to the PR.
