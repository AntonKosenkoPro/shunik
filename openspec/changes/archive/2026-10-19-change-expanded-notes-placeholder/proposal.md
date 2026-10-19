## Why

The shared expanded notes editor (`NotesEditorPage`) currently reuses the collapsed-form placeholder copy ("Optional notes" / "Необязательные заметки"). The expanded page is a free-writing surface and deserves its own inviting prompt: "Dear diary..." / "Дорогой дневник...".

## What Changes

- Add a dedicated localization key for the expanded notes editor placeholder (`notes.editorPlaceholder`): EN "Dear diary...", RU "Дорогой дневник...".
- `NotesEditorPage` empty-state overlay uses the new key instead of `L10n.entryNotesPlaceholder`.
- Collapsed presenters (entry forms, running Track notes row) keep `entry.notesPlaceholder` ("Optional notes" / "Необязательные заметки") unchanged, including accessibility summaries.
- Add/extend tests asserting the two placeholders are exact and distinct per locale.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `entry-editor`: the Notes editor page empty-state placeholder copy changes; collapsed presenter copy unchanged.

## Impact

- iOS only: `NotesEditorPage.swift`, `String+Localized.swift`, `en.lproj/Localizable.strings`, `ru.lproj/Localizable.strings`, `LocalizationTests.swift` (+ notes placeholder coverage).
- No backend, API, sync, or storage changes.
- Research: ctx7 SwiftUI `/websites/developer_apple_swiftui` — `TextEditor placeholder` (TextEditor has no native prompt; overlay pattern confirmed); HIG `/websites/developer_apple_design_human-interface-guidelines` — `placeholder text` (hint text that vanishes on typing; separate label retained — here the nav-bar title + counter serve as the persistent label). Version pin: iOS 18 SDK via Xcode 16+. No new dependencies.
