## Why

Tapping a day in the entry form's graphical month picker did nothing (CREATE Log Time sheet and pushed EDIT): the date never changed. Diagnosis on the current tree showed `FormCard` attaching `.onTapGesture { resignFocus() }` to the whole card, pickers included — the calendar grid is the only UIKit-backed control (`UICalendarView` inside `DatePicker.graphical`) and lost the tap race to the parent recognizer, while SwiftUI `Button`/`NavigationLink` children kept working.

A second defect surfaced in the same picker: month steppers (`<` `>`) and swipe paging navigated and then snapped back to the selection month within ~1s (caught on frame-by-frame screen recording). Root cause is different: `AppShellViewModel.startTicker()` re-assigned `runningTimer` every second, and `@Published` fires on every set even when the value is unchanged — a 1 Hz whole-shell re-render that reset the calendar's transient visible month. Day taps survived (selection is persistent state); month browsing (transient UI) could never outlive the tick.

A third defect: opening the picker flashed an empty tall card before the month grid popped in (conditionally-mounted calendar renders asynchronously).

## What Changes

- `FormCard` tap-away dismissal moves from the whole card to the card background layer: empty card area still resigns focus, while interactive children — graphical calendar grid, wheel picker, pills, chips, links — receive their taps.
- Start/End picker containers stay mounted and collapse to zero height (disabled + hidden + clipped) instead of conditional insertion: the calendar grows in smoothly, pre-rendered, with no blank flash; fixed 360pt height keeps every month (4–6 weeks) the same size.
- Graphical picker carries `.onTapGesture(count: 99) {}` (FB9614392 guard: an unfulfillable tap count restores the calendar's internal gesture precedence against the parent tap-away without ever firing).
- `AppShellViewModel.startTicker()` publishes `runningTimer` only on real change (`RunningTimerDraft` is `Equatable`); the compact timer keeps ticking via its own `TimelineView`, so nothing depended on the 1 Hz republish.
- Non-goals: no new pickers or date UI, no ViewModel/binding logic changes, no wheel-picker behavior change, no new strings, no backend/OpenAPI changes.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `entry-editor`: the tap-away dismissal requirement gains a day-cell carve-out — calendar-grid taps must select the date (and must not be swallowed by the card), while label/padding/background taps still resign focus. All other entry-editor behavior unchanged.
- `manual-entry`: the inline graphical month picker requirement gains selectability and month browsing — tapping a visible day must update the draft date, and month steppers/swipe must page months and stay there. Picker expansion, single-open, locale/calendar behavior unchanged.

## Impact

- iOS only: `Features/ManualEntry/Views/FormCard.swift` (shared card chrome, five entry-form cards only), `Features/ManualEntry/Views/LogTimeView.swift` (Start/End picker containers), `Features/AppShell/ViewModels/AppShellViewModel.swift` (ticker dedup).
- No API, backend, OpenAPI, localization, or on-disk format changes.
- External-docs notes: ctx7 library `/websites/developer_apple_swiftui` (query "onTapGesture gesture priority child controls") corroborates the parent-gesture mechanism; Apple radar FB9614392 (GraphicalDatePickerStyle vs parent TapGesture) documents the stepper symptom class and the `count: 99` guard. Simulator recordings are the acceptance evidence per the repo's reproduce-before-fixing rule.
