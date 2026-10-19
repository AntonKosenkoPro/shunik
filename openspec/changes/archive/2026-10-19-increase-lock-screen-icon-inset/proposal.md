## Why

On the Lock Screen Live Activity banner the category icon sits 8pt from the system card's leading edge — visually tight against the card curve. A slight +4pt leading inset (12pt effective) gives the icon breathing room without touching anything else.

## What Changes

- `RunningBannerFace` content row: leading padding 8pt → 12pt; trailing stays 8pt, vertical stays 8pt.
- No change to Dynamic Island faces (compact/minimal/expanded), Stop control, timer, glass/solid-card rendering, tap targets, or accessibility labels.
- No new strings, no new files, no API changes.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `live-activities`: the Lock Screen banner leading inset requirement changes (8pt symmetric → 12pt leading / 8pt trailing + vertical).

## Impact

- Affected code: `ios/TimeOfLife/LifioLiveActivities/RunningBannerFace.swift` (padding modifiers + comment only).
- No backend, sync, storage, or API impact. No test changes (no unit tests cover widget padding; verification is on-device visual, owned by the parent session).
- Research bundle (ctx7, 5 commands): SwiftUI `/websites/developer_apple_swiftui` — `padding` API query; HIG `/websites/developer_apple_design_human-interface-guidelines` — `Live Activities lock screen layout content margins` (consistent/concentric margins guidance; this change keeps margins near-symmetric with a deliberate +4pt leading ease requested by the user); ActivityKit `/websites/developer_apple_activitykit` — `lock screen Live Activity banner layout presentation` (iOS 18 SDK via Xcode 16+ pin). Best-practice/service item waived: pure local SwiftUI layout tweak, no external service. SwiftUI layout reference consulted: `layout-best-practices.md` (no GeometryReader/depth concerns for a padding-constant change).

## Non-goals

- No Dynamic Island layout changes, no card-in-card/glass rendering changes, no timer/Stop inset changes, no alternatives exploration (user asked for this exact tweak directly).
