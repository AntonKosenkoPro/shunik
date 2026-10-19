## Why

Mid-run retag updates the expanded Island chips but the Lock Screen banner and the compact/minimal Island icon stay frozen at the start icon: `iconSymbol` lives in immutable `ActivityAttributes` while chips live in mutable `ContentState`. Reported repro (provenance unverified — parent-supplied screenshots from an installed simulator build, not re-executed on this tree): start "Morning" with no categories, add "Sport" mid-run — expanded chip updates, banner/compact icon stays `timer`. No compile/run-before was executed by this worker; current-tree repro is recorded as a pending task below.

## What Changes

- Widget faces (banner, compact leading/minimal, expanded chips row unchanged) derive the live icon from `ContentState.categoryChips.first?.iconSymbol` with `"timer"` fallback when empty — no restart, no `startedAt` reset.
- `LiveActivityService` retag path unchanged (chips-only `update()` already fires on reorder/removal since `[LiveCategoryChip]` equality covers order and removal).
- Baseline `live-activities` delta: live icon follows the first ordered category; removal falls back to `timer`.
- Regression tests: reorder changes icon, removal falls back to `timer`, chips preserved, stopped face unaffected.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `live-activities`: live icon follows the first ordered category mid-run instead of staying as requested at start.

## Impact

- `ios/TimeOfLife/LifioLiveActivities/TimerLiveActivityWidget.swift` (banner/compact/minimal call sites), shared core helper + `TimeOfLifeTests` additions. `RunningBannerFace.swift` itself unchanged (its `iconSymbol` param is fed by the widget call site).
- No `ActivityAttributes` shape change, no service/DB/outbox change, no strings change, no other faces changed.
- Research: ctx7 `/websites/developer_apple_activitykit` — `ActivityAttributes immutable attributes vs mutable ContentState update` (attributes static, `ContentState` dynamic via `update()`; iOS 18 SDK via Xcode 16+). HIG waived: no new visual language — icon follows the existing recents-chip rule (one-line reason + evidence: widget-only diff).

## Non-goals

- No placeholder/padding/editor-tap work (other workers own those).
- No attribute-schema migration, no restart-based icon refresh, no new faces or strings.
