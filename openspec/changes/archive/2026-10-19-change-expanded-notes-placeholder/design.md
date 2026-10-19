# Design: expanded notes placeholder

## Context

`NotesEditorPage` (shared by entry forms and the running Track notes editor) overlaid `L10n.entryNotesPlaceholder` for its empty state — the same copy as the collapsed presenters. See proposal.md for motivation.

## Decisions

- **New `notes.editorPlaceholder` key instead of reusing `entry.notesPlaceholder`:** the expanded page is a free-writing surface ("Dear diary..." / "Дорогой дневник..."); the collapsed rows keep their functional label ("Optional notes" / "Необязательные заметки"). Separate keys keep the two surfaces independently localizable and testably distinct.
- **Overlay-only switch in `NotesEditorPage`:** one `Text(...)` line + doc comment; no layout, focus, counter, or navigation changes.
- Research: ctx7 SwiftUI `/websites/developer_apple_swiftui` (`TextEditor placeholder` — no native prompt; overlay pattern) and HIG `/websites/developer_apple_design_human-interface-guidelines` (`placeholder text` — hint vanishing on type; nav-bar title + counter persist as the label). Pin: iOS 18 SDK via Xcode 16+.

## Non-Goals

- Collapsed presenters (`LogTimeView`, `TrackContent`) and their accessibility summaries are untouched.

## Risks

- L10n key parity drift (en vs ru) → mitigated by `LocalizationTests` all-keys-resolve + sorted-keys snapshot + the exact-and-distinct `notesPlaceholders` test.
