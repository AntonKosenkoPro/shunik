## Context

See proposal.md (Why) for motivation. Three defects, three independent root causes, all in/around the entry-form date pickers:

1. Dead day cells: `FormCard` (`ios/TimeOfLife/TimeOfLife/Features/ManualEntry/Views/FormCard.swift`) attached `.onTapGesture { resignFocus() }` to the whole card including expanded pickers. All working children are SwiftUI `Button`/`NavigationLink`; the calendar grid is the only UIKit-backed control and lost the tap race (ctx7 `/websites/developer_apple_swiftui`, "onTapGesture gesture priority child controls"; Apple FB9614392 for the symptom class).
2. Stepper snap-back: `AppShellViewModel.startTicker()` re-assigned `runningTimer` every second; `@Published` fires on every set, re-rendering the shell at 1 Hz and resetting the calendar's transient visible month. Proven by frame-by-frame recording (November renders, then tears back to October ~0.6s later with zero interaction).
3. Open flash: conditionally-mounted calendar renders asynchronously — empty 360pt box first, grid pops in after.

Constraints: entry-editor "All native gestures work" rule (no system gesture may be disabled); `Theme` colors only; no new strings (U4 — none needed); pre-release policy (view-only + one ViewModel line, no migration).

## Goals / Non-Goals

**Goals:**
- Day taps reach the graphical picker in CREATE and EDIT on first attempt.
- Month browsing persists until day-pick or collapse.
- Picker expansion shows the grid together with the growth, no blank flash.
- Whole-shell 1 Hz re-render eliminated without changing compact-timer behavior.

**Non-Goals:**
- No ViewModel/binding logic changes (bindings proven healthy by wheel-drag differential).
- No picker UI, sizing, locale, single-open, validity-gate, save/delete, or LOCKED-mode changes.
- No new tests for gesture routing (verified on-simulator per reproduce-before-fixing); unit-testable logic (ticker dedup) covered by existing `AppShellViewModelTests`.

## Decisions

### D1: Tap-away on the background layer, not the card

Move `.onTapGesture` into the card's `.background(...)` fill so hit-testing gives children first claim; only genuinely empty area falls through to resign. Chosen over removal (tap-away is spec'd) and over per-card gating (form may regain inline fields). Alternatives (hit-test surgery, `highPriorityGesture` inversions) fight the framework.

### D2: Always-mounted, zero-height-collapsed pickers

Replace `if expanded` insertion + `.transition(.opacity)` + `GeometryReader` width with permanently mounted pickers using animated height (0 ↔ 360/216), `opacity`, `disabled`, `accessibilityHidden`, `clipped`. Kills the mount flash; fixed height keeps 4–6-week months identical; collapsed pickers take no space and intercept nothing. `GeometryReader` removal also drops a layout-feedback suspect.

### D3: FB9614392 `count: 99` guard on the graphical picker

An unfulfillable tap count restores the calendar's internal gesture precedence against the (still present, one layer up) background tap without ever firing. Zero behavioral cost; day cells unaffected.

### D4: Dedup the shell ticker instead of touching the calendar for snap-back

`if draft != self.runningTimer` before assigning (`RunningTimerDraft: Equatable`). The calendar cannot distinguish "re-render with same data" from real change, so the only correct fix is to stop publishing when nothing changed. `CompactTimer` ticks via its own `TimelineView` — verified independent. Alternatives (custom `UICalendarView` representable owning `visibleDateComponents`) considered and rejected as disproportionate once the trigger proved to be our own 1 Hz hammer, not the wrapper.

### D5: Repro-first, on-simulator, recorded

Unmodified-tree repro (CREATE + EDIT dead day taps, 2 videos) → differential (pills/chips/wheel/rows all work) → identical-script verify after each fix (day select, End auto-push, stepper persistence past the snap-back window, cross-month select) → full control sweep. Recordings are the acceptance evidence.

## Risks / Trade-offs

- [Risk] Some other periodic publisher re-renders the form and browsing resets again → Mitigation: audited (`Ticker` helper unused by views; `TrackViewModel` ticker is Track-scoped; sync/monitor publish on events only). Residual resets only on real data change — semantically correct.
- [Risk] `count: 99` is a community workaround for an Apple bug, not API → Mitigation: empty handler, never fires; removal is a one-line revert if Apple fixes FB9614392.
- [Risk] Always-mounted calendars cost some memory/CPU → Mitigation: 2 small pickers per card × 2 cards, collapsed to zero height and disabled; negligible vs one `UICalendarView` screen.
- [No migration] View + one-line ViewModel change: no data, API, or rollout steps; rollback is a revert.

## Open Questions

None — repro-driven, all three mechanisms proven on-device/simulator before landing.
