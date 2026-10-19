## Context

`RunningBannerFace.content` (`ios/TimeOfLife/LifioLiveActivities/RunningBannerFace.swift`) currently applies symmetric breathing room: `.padding(.vertical, 8)` + `.padding(.horizontal, 8)`. See proposal.md — Why. The widget target already uses literal point values throughout (8pt banner/expanded insets, 4pt trailing slot), so a literal follows the file's existing pattern; no `Theme` spacing token exists in the widget target (`LiveActivityTheme` covers only Stop control colors). The system card behind the content is untouched (transparent content rule stands).

## Goals / Non-Goals

**Goals:**
- 12pt effective leading inset for the banner icon, everything else pixel-identical.

**Non-Goals:**
- No Dynamic Island face changes, no Stop/timer geometry changes, no glass/solid-card rendering changes, no tap-target or accessibility changes (see proposal.md non-goals).

## Decisions

- **Split `.padding(.horizontal, 8)` into `.padding(.leading, 12)` + `.padding(.trailing, 8)`** (vertical stays 8) rather than adding an inner `.padding(.leading, 4)` on the icon: one inset site, no nested padding to reason about, matches the per-edge `.padding(_:_:)` API (SwiftUI `/websites/developer_apple_swiftui` — `padding` layout query).
- **Literal `12`, not a shared token**: the banner and all sibling Island insets are literals; introducing a token for one edge would be the only indirection in the file. No dead code, no new utilities (repo rule: prefer existing patterns).
- **No snapshot/unit test**: no harness covers widget-extension SwiftUI layout (verified: no test references `RunningBannerFace`); verification is on-device visual by the parent session. Adding a first-of-kind widget snapshot harness for a 4pt nudge is disproportionate.

## Risks / Trade-offs

- [HIG concentric-margins guidance] → HIG (`/websites/developer_apple_design_human-interface-guidelines` — `Live Activities lock screen layout content margins`) advises even, concentric margins; a 12/8 asymmetry is a deliberate, user-requested deviation of +4pt. Mitigation: scoped to the leading edge only; still compact and well inside the card curve.
- [Device rendering differs from Previews/simulator] → the file's own comments record that tint/glass render wrong off-device. Mitigation: no visual sign-off here; parent session verifies on device.

## Open Questions

None — the value (12pt) and scope were fixed by the request.
