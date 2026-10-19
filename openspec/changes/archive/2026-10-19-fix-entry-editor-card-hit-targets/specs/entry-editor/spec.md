## MODIFIED Requirements

### Requirement: Entry-form push rows share caption-row chevron grammar
The editable Name and Notes rows SHALL present as push rows with the navigation chevron on the caption row (caption plus trailing chevron with balanced corner margins) and the full-width value below — single-line truncated for Name, 1–5 line truncated for Notes. In CREATE and EDIT modes the entire card SHALL be the push hit-target: tapping anywhere on the card — caption text, chevron, value text or placeholder, blank space, and card padding — SHALL push the existing editor (NamePicker for Name, NotesEditorPage for Notes) via the native `NavigationLink` push with no visual change. The hit-target expansion SHALL NOT swallow scroll or back gestures and SHALL NOT alter `FormCard` global behavior. LOCKED mode SHALL show no chevron and no navigation on either row: LOCKED cards stay inert (disabled and dimmed) with no editor push.

#### Scenario: Name row chevron sits on the caption row
- **WHEN** the form opens in CREATE or EDIT mode
- **THEN** the Name row shows its chevron trailing the caption, and the value fills the full row width below

#### Scenario: Notes presenter matches the Name row
- **WHEN** the form opens in CREATE or EDIT mode
- **THEN** the Notes presenter shows the same caption-row chevron grammar as the Name row

#### Scenario: Locked rows show no chevron
- **WHEN** the form opens for an imported entry
- **THEN** neither the Name nor the Notes row offers navigation or a chevron

#### Scenario: Tapping Name caption or chevron pushes the picker
- **WHEN** the user taps the Name caption text, chevron, blank space, or card padding in CREATE or EDIT mode
- **THEN** the shared name picker pushes prefilled with the current draft name, exactly as tapping the value does

#### Scenario: Tapping Notes caption or chevron pushes the editor
- **WHEN** the user taps the Notes caption text, chevron, blank space, or card padding in CREATE or EDIT mode
- **THEN** the dedicated Notes editor page pushes prefilled with the current draft notes, exactly as tapping the preview text does

#### Scenario: Locked cards stay inert on any tap
- **WHEN** the user taps anywhere on the Name or Notes card in LOCKED mode
- **THEN** no editor pushes, no navigation occurs, and the card remains dimmed read-only

#### Scenario: Card taps preserve native gestures
- **WHEN** the user scrolls the form starting on a Name/Notes card, or swipes back from the pushed editor
- **THEN** the form scrolls normally and the edge-back gesture pops the editor with the draft discarded or committed per the existing editor contract
