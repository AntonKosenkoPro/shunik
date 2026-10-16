## Why

History day-group headers render as an opaque slab (`Theme.backgroundPrimary`) directly under a transparent Liquid-Glass navigation bar. On iPad the pinned slab spans the full pane width, so the nav→content transition reads as two competing "tops" and the entire History layout feels broken (issue #35). iPhone shows the same mismatch at smaller scale.

## What Changes

- History sticky day headers stop being opaque: pinned and in-list headers share one continuous translucent treatment with the navigation bar (system material + scroll-edge effect), Calendar-Agenda-like.
- The exact winning treatment (material, soft-vs-hard edge style, header typography scale) is decided by three throwaway spikes run on-device (iPhone + iPad landscape, light + dark, Reduce Transparency) before implementation.
- Elevation-gated day total ("2h 35m tracked" only when pinned) is preserved unless the spikes prove the native-`List` option wins, in which case the total moves to an always-visible home (decision recorded in design.md).
- History list content returns under the glass tab bar (rows blur beneath it mid-scroll, TestFlight parity): bottom-edge handling of the `HistoryListTable` bridge only — top pinning/occlusion (design.md D6) untouched (follow-up 2026-10-15, design.md D7). Per user verdict the bleed applies on iOS 26+ only; iOS 18 keeps the default bar (design.md D7 gating, tasks §6).
- DEBUG harness seeds ~264 History entries across 12 day groups for realistic scroll testing (tasks §6; seeds only, no production behavior).
- Final implementation (2026-10-16, user verdict on the `List(.plain)` spike, design.md D8): native `List(.plain)` with bare two-line headers — the UIKit bridge (`HistoryListTable`, measured inset, OS gate) is deleted. Pinned-header bleed (row text crossing beneath pinned headers on all OS versions) is explicitly accepted; the tab-bar split is kept via bar visibility (opaque bar on iOS 18, glass on iOS 26+) instead of frame games.
- No new strings, no data or API changes, no behavior changes outside History headers.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `history-entry-list`: day-group header background/material requirement changes (opaque → translucent material + scroll-edge effect, continuous with the nav bar); iPad pane-width continuity requirement added. All other requirements (relative-then-absolute labels, elevation-gated total, column alignment) unchanged.

## Impact

- iOS only: `Features/AppShell/Views/HistoryView.swift` (header background + edge-effect style), `Core/Design/Components/SectionHeader.swift` (only if the Calendar-grammar typography option wins), `Design/SCREENS/History.md` + `Design/COMPONENTS.md` docs.
- Tab-bar follow-up (2026-10-15): `Features/AppShell/Views/HistoryListTable.swift` (table frame/bottom inset; `HistoryView.swift` only if an inset modifier is needed). No backend, OpenAPI, or persistence impact.
- No backend, OpenAPI, or persistence impact. No new dependencies.
- External docs fetched (ctx7 `/websites/developer_apple_swiftui`): `scrollEdgeEffectStyle`, `Material ultraThinMaterial toolbar background`, `pinnedViews LazyVStack section headers`; iOS 18 floor, Liquid-Glass behavior observed on iOS 26.
- External docs fetched for the tab-bar follow-up (ctx7, pin: iOS 18 SDK via Xcode 16+): `/websites/developer_apple_uikit` — "UITableView contentInset safe area translucent tab bar" (`contentInset` auto-adjusts for overlapping bars; `insetsContentViewsToSafeArea` governs cell/header content, not the table frame); `/websites/developer_apple_swiftui` — "UIHostingConfiguration UITableView cell SwiftUI content", "Liquid Glass glassEffect scroll edge toolbar background iOS 26". HIG tab-bar translucency waived: ctx7 fetch failed twice for the HIG library, so the OS-chrome behavior is verified via the before/after screen-recording repro instead.

## Non-goals

- Per-header `.glassEffect()` capsules (glass is the controls layer, never the content layer; re-samples every scroll frame).
- Migrating History to native `List` unless the spikes justify it (tracked as spike B, decision-gated).
- Readable-width (`maxContentWidth`) iPad reflow — secondary to the material break, deferred to a follow-up.
- New localization keys or VoiceOver grammar changes.
- Entry-twitch-on-scroll fix (pre-existing: reproduces on the TestFlight build with the old container — separate change, not this PR).
- `UICollectionView` list-layout migration (revisit only if swipe actions or animated batch updates land).
- Glass effects on History headers or rows (the bare-type verdict stands).
