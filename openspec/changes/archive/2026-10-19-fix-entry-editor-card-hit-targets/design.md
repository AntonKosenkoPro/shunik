## Context

`LogTimeView` (`ios/TimeOfLife/TimeOfLife/Features/ManualEntry/Views/LogTimeView.swift`) rendered Name (`nameCard`) and Notes (`notesCard`) as `FormCard` cards containing a `NavigationLink` whose label covered only the value `Text`. The caption `HStack` (Name) lived outside the link, and the Notes label's `contentShape(Rectangle())` sat only on the preview `Text`. Taps on caption/chevron/blank/padding fell through to the `FormCard` background tap-away (resign-only) instead of pushing — confirmed by the parent verifier repro on clean `f5aa180` (EDIT: Name chevron `(0.903,0.160)` FAIL stayed Edit; Name caption `(0.121,0.160)` FAIL; Name blank value `(0.746,0.198)` PASS opened NamePicker; Notes chevron `(0.910,0.798)` FAIL stayed Edit; Notes body `(0.5,0.843)` PASS opened NotesEditor; build log `repro-issue4/build.log`, control screenshot `repro-issue4/notes-editor-open.png`; CREATE shares the same code path, not yet probed). See proposal.md Why. `FormCard.swift` background-tap placement stays untouched (fix-entry-date-picker-taps precedent). `TimeOfLifeApp.swift` + `AppContainer+UITesting.swift` provide the `UITEST_SCREEN` fixture harness the dedicated repro verifier uses; this change adds no new fixture.

## Goals / Non-Goals

**Goals:**
- Full-card push on Name and Notes in CREATE/EDIT via native `NavigationLink`, caption + chevron included, padding included, visuals unchanged.
- LOCKED cards remain inert (existing `.disabled` + opacity path, no link).
- Preserve scroll, edge-back, tap-away, and `FormCard` calendar-picker gesture precedence.

**Non-Goals:**
- No `FormCard.swift` global behavior change; no new gestures, no `simultaneousGesture`/`highPriorityGesture`.
- No notes copy change (owned by `change-expanded-notes-placeholder` worker), no placeholder/widget/icon work.
- No ViewModel, store, strings, or backend changes.

## Decisions

- **Decision: Move the caption row inside the `NavigationLink` label for both cards (Name: hoist caption `HStack` into the label `VStack`; Notes: keep structure, hoist `contentShape(Rectangle())` to the outer label `VStack` and add full-width frames).**
  - Rationale: label content defines the push hit-area; per SwiftUI `/websites/developer_apple_swiftui` (`NavigationLink full-row hit target contentShape Rectangle plain button style`) a `Rectangle` contentShape on the full label makes blank space tappable while `.buttonStyle(.plain)` keeps visuals flat. Caption `Text` claims hits, `Spacer` does not — the shape fills the gap.
  - Alternatives considered: wrapping `FormCard` in the link label (would capture padding but couples card chrome to navigation and risks double-padding hit semantics); `onTapGesture` + programmatic push (breaks native edge-back/push semantics and risks swallowing scroll — rejected per spec).
- **Decision: Capture card padding without touching `FormCard`.**
  - Rationale: `FormCard` applies `.padding` outside the caller's content, so a label confined inside cannot by itself claim the padding ring. Options are (a) link-outside-card, or (b) negative/overlapping hit expansion. Choice deferred to implementation within the constraint "no broad FormCard global change": either a per-card outer `NavigationLink` wrapping the `FormCard` (scoped, not global), or label `contentShape` + layout that extends into the padding zone while `FormCard` stays generic. Both keep `FormCard.swift` untouched.
  - Alternatives considered: editing `FormCard` to forward taps — rejected (broad global behavior change, risks calendar-picker regression).
- **Decision: Keep LOCKED path link-free.**
  - Rationale: existing `if vm.isLocked` branch renders plain `Text` with `.disabled` + `opacity`; no link means no push and VoiceOver reports static text. No chevron rendered there already.

## Risks / Trade-offs

- [Risk: outer-link wrapping changes accessibility grouping] → Mitigation: keep existing `.accessibilityLabel/.accessibilityValue` on the link and verify VoiceOver reads one row.
- [Risk: padding-capture approach interferes with `FormCard` background tap-away] → Mitigation: `Button` (link) wins hit-testing over background `onTapGesture`; verify tap-away still resigns on Start/End/Categories cards and scroll still works from the card.
- [Risk: over-broad hit area swallows scroll] → Mitigation: native `NavigationLink` + `contentShape` does not install drag recognizers; verify pull-to-scroll from the card in the repro session.

## Open Questions

None — pending the parent-scheduled recorded repro on the current tree (dedicated verifier owns xcodebuild/simulator); implementation starts after repro evidence is relayed.
