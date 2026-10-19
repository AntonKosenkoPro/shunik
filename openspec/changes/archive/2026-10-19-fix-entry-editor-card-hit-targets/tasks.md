## 1. Repro (parent-scheduled, DONE on clean tree)

- [x] 1.1 Record failing repro on current tree via dedicated verifier (`UITEST_SCREEN` fixture, DEBUG): tap Name caption/chevron/blank/padding and Notes caption/chevron/blank/padding in CREATE/EDIT pushes nothing; attach evidence relayed by parent
- [x] 1.2 Confirm LOCKED baseline: taps on Name/Notes cards push nothing

## 2. Implementation (repro received — applied)

- [x] 2.1 Name card: hoist caption row (label + chevron) inside the `NavigationLink` label; full-width `VStack` + `contentShape(Rectangle())`; keep `.buttonStyle(.plain)`, VoiceOver label/value, LOCKED branch untouched
- [x] 2.2 Notes card: hoist `contentShape(Rectangle())` to the outer label `VStack` with full-width frames; keep `.buttonStyle(.plain)`, VoiceOver label/value, LOCKED branch untouched, notes copy unchanged
- [x] 2.3 Padding capture without `FormCard` global change: scope the push to cover card padding (per-card outer link or hit-expansion that leaves `FormCard.swift` generic); no custom gestures
- [x] 2.4 Parent follow-up `8d06a37` (no conflict, idle handoff): add inline `@ViewBuilder` to `nameCard`/`notesCard` — the LOCKED-vs-editable property-level branch returns mismatching types (`FormCard` vs `ModifiedContent+AccessibilityAttachmentModifier`) and the Release device build of the combined tree failed without branch type erasure; swiftlint `attributes` rule requires the attribute inline (`@ViewBuilder private var`)
- [x] 2.5 SwiftLint clean: `swiftlint lint --strict` from `ios/TimeOfLife` (no xcodebuild/simulator; verifier owns them)

## 3. Verification (parent-executed; human-approved PR #183)

- [x] 3.1 Baseline repro on clean `f5aa180` (dedicated verifier, iPhone16Pro sim F132A44E, `UITEST_SCREEN=history` → History → EntryRow Evening walk EDIT): Name chevron/caption taps dead, Name value tap opened NamePicker; Notes chevron dead, Notes body opened NotesEditor. Log: `/private/var/folders/8c/pwh55jk140g1shxfnwm7zxf80000gn/T/opencode/repro-issue4/build.log`
- [x] 3.2 xcodebuild TEST SUCCEEDED on final code (incl. `8d06a37` @ViewBuilder fix): 688 Swift-Testing passes, 0 failures. Log: `/private/var/folders/8c/pwh55jk140g1shxfnwm7zxf80000gn/T/opencode/verify-editor.log`. Backend PASS on base `f5aa180` (tree `cda3b83`): gofmt/vet/golangci-lint/test-cover/build. Log: `/private/var/folders/8c/pwh55jk140g1shxfnwm7zxf80000gn/T/opencode/backend-verify-fix-entry-editor-card-hit-targets.log`
- [x] 3.3 User acceptance: all four fixes ACCEPTED on physical iPhone (combined-tree Release device build SUCCEEDS after `8d06a37`)
- [ ] 3.4 Fixed-tree simulator re-run of the tap probes — NOT performed; SUBSTITUTED by device acceptance + full suite (honest note as in PR #183 body). Deliberately left unticked — do not tick without running the probes.
- [x] 3.5 `openspec validate --all --strict` green (27 passed); no baseline spec hand-edits, no strings/backend changes
