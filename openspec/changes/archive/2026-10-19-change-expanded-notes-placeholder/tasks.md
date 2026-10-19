## 1. Localized strings

- [x] 1.1 Add `notes.editorPlaceholder` key to `String+Localized.swift` (`L10n.notesEditorPlaceholder`)
- [x] 1.2 Add EN "Dear diary..." and RU "Дорогой дневник..." to `en.lproj` / `ru.lproj` `Localizable.strings`
- [x] 1.3 Point `NotesEditorPage` empty-state overlay at the new key; update its doc comment

## 2. Regression coverage

- [x] 2.1 Extend `LocalizationTests` (or notes placeholder test) to assert exact + distinct copy per locale: collapsed `entry.notesPlaceholder` vs expanded `notes.editorPlaceholder`
- [x] 2.2 Confirm collapsed presenters (`LogTimeView`, `TrackContent`) and accessibility summaries still use `entryNotesPlaceholder`

## 3. Verification

- [x] 3.1 `openspec validate --all --strict` green
- [x] 3.2 `swiftlint lint --strict` green (from `ios/TimeOfLife`)
- [x] 3.3 Full iOS build green — parent-verified: `xcodebuild` TEST SUCCEEDED on iPhone16Pro sim F132A44E (log `/private/var/folders/8c/pwh55jk140g1shxfnwm7zxf80000gn/T/opencode/verify-notes.log`)
- [x] 3.4 Full iOS test suite green incl. new `notesPlaceholders` regression — parent-verified: 689 Swift-Testing passes, 0 failures (same log)
- [x] 3.5 Visual verification of the expanded editor empty state (EN + RU) and collapsed presenters — parent-verified: user acceptance of all four fixes on physical iPhone from combined Release build

## 4. Backend (no backend changes in scope — recorded for the parent verifier)

- [x] 4.1 Backend verifier PASS on base `f5aa180` (backend tree `cda3b835947ae847a6282e56f120f7a96aee588d`): full `gofmt`/`go vet`/`golangci-lint`/`go test -cover`/`go build` green — log `/private/var/folders/8c/pwh55jk140g1shxfnwm7zxf80000gn/T/opencode/backend-verify-change-expanded-notes-placeholder.log`. Expected: iOS-only diff touches no Go code.
