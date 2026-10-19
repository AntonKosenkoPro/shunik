## Context

See proposal.md (Why). Current state: `TimerActivityAttributes.iconSymbol` is an immutable `ActivityAttributes` field rendered by the banner (`RunningBannerFace`), compact leading, and minimal faces. Mid-run retag calls `Activity.update()` with refreshed `ContentState.categoryChips` only — attributes cannot change without end+request, which would flicker and reset the visible run. The chips update already fires on reorder/removal (`[LiveCategoryChip]` equality covers order/content). Research: ctx7 `/websites/developer_apple_activitykit` — `ActivityAttributes immutable attributes vs mutable ContentState update` (static attributes, dynamic `ContentState` via `update()`; iOS 18 SDK via Xcode 16+).

## Goals / Non-Goals

Goals: live icon follows `categoryChips.first` with `"timer"` fallback on every face without restart/time reset; chips row and stopped Saved face untouched.
Non-goals: attribute-schema migration, restart-based refresh, new faces/strings, placeholder/padding/editor-tap work (other workers).

## Decisions

- **Derive the live icon from `ContentState.categoryChips` in the widget** (helper `ContentState.liveIconSymbol`: `categoryChips.first?.iconSymbol ?? "timer"`) over adding a parallel `iconSymbol` to `ContentState`. Rationale: single source of truth — chips already carry validated icons in draft order, so reorder/removal propagate with the existing chips-only `update()` and no service change; alternating: a duplicated state icon risks chips/icon skew and needs Codable back-compat for in-flight activities.
- **Fallback is literal `"timer"` (not `attributes.iconSymbol`)** when chips are empty. Rationale: attributes hold the stale start icon, so falling back to them would preserve the reported bug on category removal; `"timer"` matches the start-no-categories rule.
- **No `LiveActivityService` change**: the `categoryChips !=` guard already refreshes on reorder/removal; service tests assert the mirrored chips/icon inputs unchanged. Widget-only diff keeps the fix minimal and reviewable.
- **Pure helper in `LifioLiveActivityCore`** (`TimerActivityAttributes.ContentState.liveIconSymbol`) so `TimerServiceTests`-style SwiftTesting can regress it without ActivityKit or simulator.

## Risks / Trade-offs

- [Risk] Old in-flight activity started pre-fix renders via new widget: chips payload shape unchanged, helper reads the same array → no decode break; attributes icon ignored only when chips drive the faces. → Mitigation: no schema change; previews cover empty/non-empty chips.
- [Risk] Category icon validation drift (chip icon vs start icon resolve differently). → Mitigation: both resolve through `CatalogIcon.displaySymbol` at request time (`TimerService.firstIconSymbol` / `categoryChips`); helper never validates.

## Migration Plan

None — no persisted format, no API, no rollout steps. Rollback: revert widget call sites to `attributes.iconSymbol`.

## Open Questions

None.
