## Why

The running-timer Live Activity looks flat next to competitors and has two proven defects: the Lock Screen banner draws its own fake-glass card inside the system's card (a card-in-a-card that reads unnatural), and the expanded Dynamic Island truncates the timer past width phase crossings (`9:59`→`10:00`) while hiding categories despite available room. A runnable spike (`spike/live-activities-glass`, OpenSpec `live-activities-glass-spike`) proved the fixes on a real iPhone and an iOS 18 simulator — this change ships them.

## What Changes

- Lock Screen banner becomes transparent content (icon + exact name + live timer + Stop) over the system card: `.activityBackgroundTint(.clear)` on iOS 26+ summons the system Liquid Glass; below 26 the tint is omitted (`#available` gate) keeping the classic solid card. All custom smoke/gloss/hairline layers are removed.
- Expanded Island relayout: big borderless monospaced timer top-left (hidden-twin sizing + figure-space slack + scale backstop, never truncates), Stop top-right, full-width name plus validated-SF-Symbol category chips along the bottom (cap 2 + `+n`).
- Mid-run retag refreshes visible chips in place via the `runStarted` singleton guard (`activity.update()` only when chips differ); the first-position icon stays frozen at start (attributes immutable).
- Stop controls render always, dimmed and inert under reduced luminance (the AoD blank was a device setting, not rendering).
- No backend change; no new localizable strings (chips are verbatim user data).

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `live-activities`: banner glass treatment, expanded layout with chips + truncation guarantee, retag chip refresh, dimmed Stop rule.

## Impact

- `ios/TimeOfLife/LifioLiveActivityCore/TimerActivityAttributes.swift` (`LiveCategoryChip`, `ContentState.categoryChips`).
- `ios/TimeOfLife/LifioLiveActivities/` (`RunningBannerFace`, `TimerLiveActivityWidget`, theme tokens).
- `ios/TimeOfLife/TimeOfLife/Features/TimeTracking/Services/` (`LiveActivityService` update path, `TimerService` chip resolution).
- `ios/TimeOfLife/TimeOfLifeTests/LiveActivityLifecycleTests.swift` (chip assertions).
- External behavior pinned to current docs: Context7 `/websites/developer_apple_activitykit`, query "Live Activity lock screen banner transparent background Liquid Glass activityBackgroundTint clear" (Apple ActivityKit docs: default solid card, custom color via tint, `nil` = system default material), plus Apple HIG Live Activities, `activityBackgroundTint(_:)` API reference, and WWDC26 "Live Activities essentials" (`showsWidgetContainerBackground` pattern). iOS 26+ glass via `.clear` is community-proven (Dec 2025–Jan 2026) and device-confirmed in the spike.

## Non-Goals

- Compact/minimal face changes; Saved-card changes; ControlWidget toggle (still deferred); backend or OpenAPI changes; new strings/localization.
