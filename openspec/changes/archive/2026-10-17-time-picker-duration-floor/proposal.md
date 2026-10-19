## Why

Manual start/end picking in the entry form is error-prone and lossy: moving Start only preserves duration on collision (moving it earlier silently stretches the entry), the End picker allows picking an end at or before start (surfacing only as a disabled Save), and there is no lower bound on durations users can pick. Tightening the pickers — duration-preserving start moves plus a 1-minute floor enforced in the picker itself — makes invalid intervals unreachable by hand instead of merely rejected at save time.

## What Changes

- **Start moves always preserve duration, both directions**: changing Start shifts End by the same delta (`end += newStart − oldStart`), whether Start moves earlier or later. Replaces the current collision-only rule (End moves only when Start lands at or past End).
- **End moves never move Start** (unchanged): duration changes, as today.
- **End pickers enforce a 1-minute floor via selectable ranges**: the End date and End time `DatePicker`s get an `in:` range so values before `start + 1 minute` cannot be chosen (start 1:00 → earliest end 1:01). The End time bound applies only when end-date equals start-date; on later days the wheel is unbounded. Start pickers stay unbounded (always-preserve makes collisions via Start unreachable).
- **Grandfathered sub-minute drafts**: an EDIT prefill with duration < 60s keeps its backing times untouched — saving without touching time writes the originals back, so category/notes-only edits are never forced to adjust time. Display mapping for such drafts: start pill shows `floor(start)`, end pill shows `floor(start) + 1 minute`, duration subtitle shows the true duration (e.g. `33s`). Touching any of the four time pickers adopts both display values into the draft, after which the floor and ranges apply.
- **BREAKING (UX-level, pre-release)**: freshly picked intervals below 1 minute and end-before-start choices become unpickable; previously they were pickable-but-unsavable (disabled Save). Stored data is untouched — no migration, no on-disk format change.

## Capabilities

### New Capabilities

- None — all behavior lands in existing capabilities.

### Modified Capabilities

- `manual-entry`: start-move rule changes from preserve-on-collision to always-preserve (both directions); end pickers gain selectable ranges enforcing the 1-minute floor.
- `entry-editor`: validity gate gains the touched/untouched distinction (untouched legacy sub-minute drafts remain savable; touched drafts require `end − start ≥ 60s`); duration subtitle shows true duration for grandfathered drafts; display-mapping rule for sub-minute drafts.

## Impact

- iOS: `Features/ManualEntry/Views/LogTimeView.swift` (picker `in:` ranges, display-mapped bindings), `Features/ManualEntry/ViewModels/LogTimeViewModel.swift` (always-preserve `setStartsAt`, touched flag, grandfathered save path). No new views; `Theme`/`L10n` reuse (U4 strings if new copy is needed go to both `en`/`ru`).
- Specs/docs: delta specs for `manual-entry` + `entry-editor`; FURPS `Timetracking.md` F13 row update.
- Explicit non-goals: no backend/OpenAPI change (`duration_seconds` stays derived, S10 untouched); no migration of stored sub-minute entries (history keeps showing true durations); LOCKED mode unchanged (read-only); timer-capture stop flow unchanged; no minute-interval granularity change; no auto-bump of legacy drafts on open.

## Research bundle

Pin: iOS 18 SDK via Xcode 16+.

- Apple API — `/websites/developer_apple_swiftui`, query "DatePicker selection in range bounds minimum maximum date": `init(_:selection:in:displayedComponents:)` selects a Date in a closed `ClosedRange<Date>` (inclusive selectable range). Constrains design: ranges compare full `Date` timestamps, so the end-time bound must be derived per same-day vs later-day.
- HIG — `/websites/developer_apple_design_human-interface-guidelines`, query "date pickers best practices selecting date time iOS": inline/wheels styles, time mode shows hours+minutes, keep pickers in context near the edited field (current inline single-open layout already complies).
- Best practice — same HIG pickers page ("Use predictable and logically ordered values", "Avoid switching views to show a picker"): disabled-out-of-range cells keep values predictable; no presentation change needed.
- ActivityKit — waived: no Live Activity or lock-screen surface involved (evidence: change touches only `LogTimeView`/`LogTimeViewModel`).
