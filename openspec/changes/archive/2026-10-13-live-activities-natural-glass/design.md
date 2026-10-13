## Context

See proposal.md — Why. Current faces live in `LifioLiveActivities/TimerLiveActivityWidget.swift`; contract in `LifioLiveActivityCore/TimerActivityAttributes.swift`; app bridge is `TimerService` → `LiveActivityControlling.runStarted` (start, cold restore, mid-run retag rewrite). A runnable spike on `spike/live-activities-glass` proved every decision below on a real iPhone (iOS 27) and an iOS 18.6 simulator; this change ports the spike to main, never merging the spike branch.

Hard constraints carried over: real Liquid Glass refraction is impossible inside third-party activity views (frozen renders — no live-compositing engine); the glass must come from the system card, never our view. The appex cannot see the app asset catalog (bundle-free colors only). `LocalStore` stays the single mutation chokepoint; no backend change.

## Goals / Non-Goals

**Goals:**
- Ship the spike-proven banner (system glass) and expanded Island (chips + truncation fix) with full test + device proof.
- Keep iOS 18 behavior correct via an explicit version gate.

**Non-Goals:**
- Design-level scope is fixed by the proposal; no new faces, strings, or backend.

## Decisions

**D1 — `categoryChips` rides in `ContentState`, not attributes.** Categories mutate mid-run; attributes freeze at `request()`. State gains `categoryChips: [LiveCategoryChip]` (defaulted `[]`, `Codable`/`Hashable`; chip = verbatim name + pre-validated icon symbol from `CatalogIcon.displaySymbol`, shared via `LifioLiveActivityCore`). Alternative (re-request on retag) rejected: ends/reveals the Island and breaks the singleton contract. Consequence: first-position icon stays frozen at start — documented in the spec.

**D2 — Retag refresh reuses `runStarted`'s singleton guard (no new protocol method).** Same-text live activity gets `activity.update()` with refreshed state, skipped when chips are identical (no flicker). Alternative (new `runCategoriesChanged`) rejected: three call sites already funnel through `runStarted`, and restore-with-same-data updating is harmless.

**D3 — Banner is transparent content + gated clear tint.** No custom container ever: no `activityBackgroundTint` color, no fill, no gloss, no hairline (the spike built all three, then removed them — layered inside the system card they read as a card-in-a-card). iOS 26+: `.activityBackgroundTint(.clear)` summons the system Liquid Glass card (device-confirmed). Below 26: tint omitted via `#available` (unconditional `.clear` simulator-proven unreadable on iOS 18.6 — dark card, dark content). Alternative (WWDC26 `showsWidgetContainerBackground` custom gradient) rejected: branding the banner is not a goal; noted as the fallback if the glass verdict ever regresses.

**D4 — Expanded Island: big borderless timer + icon chips.** Leading: timer alone at `.title` monospaced; size from a hidden static twin in the same format filled exactly via `overlay` (overlay takes no layout part), one trailing figure space (`\u{2007}`) as digit-width slack covering every single-digit phase crossing, `.lineLimit(1)` + `.minimumScaleFactor(0.8)` as the clip-instead backstop. Bottom: name (`lineLimit(1)`) + chip row (cap 2 + `+n`, hairline capsules — the island is always black, so the hairline language survives here). Trailing Stop unchanged. Alternatives (fixed-point timer size; third clipped chip) rejected for Dynamic Type safety and overflow.

**D5 — Stop always renders, dimmed and inert when dimmed.** The archived AoD-blank postmortem showed a device setting (Allow Access When Locked), not rendering — hiding the control removes a working lock-screen action. `.disabled(isLuminanceReduced)` + reduced opacity; pocket-stop protection preserved. Alternative (hide per baseline) rejected by device evidence.

## Risks / Trade-offs

- [Simulator/Preview cannot verify the tint] → Device proof is acceptance criteria (tasks 5.x); simulator only proves plumbing and the fallback branch.
- [`.clear` glass is OS behavior, not ours] → If a future iOS changes the mapping, the `#available` gate + WWDC26 pattern give a two-line migration; tasks pin re-verification per major iOS.
- [`update()` on retag could flicker] → Guarded by chips-differ check; device-verified silent.
- [Glass contrast on light wallpapers] → System card owns contrast (adaptive material); acceptance includes a light-wallpaper lock-screen check.

## Migration Plan

No migration: additive state field (defaulted), no on-disk format change (pre-release rule anyways), no backend. Rollback = revert this change. Spike worktree/branch deleted after landing.
