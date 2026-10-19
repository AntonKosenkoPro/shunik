## Why

Entry-form Name and Notes cards only push their editor when the value text itself is tapped. Caption, chevron, blank space, and card padding fall through to the `FormCard` background tap-away, so CREATE/EDIT users hit dead zones on the two primary push rows.

## What Changes

- Name card (CREATE/EDIT): the whole card — caption row (label + chevron), value line, blank space, and padding — pushes the existing `NamePicker`; visual layout unchanged.
- Notes card (CREATE/EDIT): the whole card — caption row, preview text/placeholder, blank space, and padding — pushes the existing `NotesEditorPage`; visual layout and copy unchanged.
- LOCKED (imported, read-only) cards stay inert: no navigation, no chevron, dimmed via existing `.disabled` + opacity.
- Keeps native `NavigationLink` push (edge-back, scroll, tap-away semantics preserved); no change to `FormCard` global behavior, no custom gestures swallowing scroll/back.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `entry-editor`: Name/Notes push-row hit-target requirement — full-card tap pushes editor on CREATE/EDIT, inert when LOCKED.

## Impact

- iOS only: `ios/TimeOfLife/TimeOfLife/Features/ManualEntry/Views/LogTimeView.swift` (`nameCard`, `notesCard` label structure + `contentShape`).
- No `FormCard.swift` global change, no ViewModel/store changes, no strings, no API/backend changes.
- Research: SwiftUI `/websites/developer_apple_swiftui` — `NavigationLink full-row hit target contentShape Rectangle plain button style`, `NavigationLink destination label buttonStyle back gesture ScrollView interaction` (pin: iOS 18 SDK via Xcode 16+); HIG `/websites/developer_apple_design_human-interface-guidelines` — `navigation push row chevron disclosure tappable area minimum touch target`; best-practice/setup waived — pure system SwiftUI, no external lib/service (diff touches only `LogTimeView.swift` label structure).
