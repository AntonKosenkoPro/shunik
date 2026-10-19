## MODIFIED Requirements

### Requirement: Entry-form Notes row has a clear button
The entry-form Notes row SHALL present a read-only multiline presenter instead of an inline editor: a `Text` label with a 1–5 line window that shows the localized notes placeholder when the draft notes are empty and truncates past 5 lines. The presenter SHALL carry the caption row with a trailing chevron in balanced corner margins (the caption row's top inset equals the card's trailing inset; approved spike variant B). Tapping the presenter SHALL push a dedicated Notes editor page carrying X (cancel/discard) and ✓ (save/commit) in the navigation bar with no system Back button (X is the sole cancel path; swipe-back still pops and discards). The editor page SHALL show a live localized subtitle pairing the entry name with the notes counter (`<name> • <count>/2000`, name omitted when empty), counting every rune against the 2000 bound. Past the bound the counter SHALL render red; the confirm action SHALL stay enabled and an over-limit save attempt SHALL shake the counter subtitle and play the error haptic without saving or popping. The 2000-rune notes cap is enforced by the relay; the 60-char name bound is unchanged. In LOCKED mode the presenter SHALL render multiline read-only (disabled and dimmed) with no editing and no navigation. All strings localized (EN + RU), `Theme` semantic colors only. The collapsed presenter placeholder SHALL read "Optional notes" (EN) / "Необязательные заметки" (RU); the expanded editor page empty-state placeholder SHALL read "Dear diary..." (EN) / "Дорогой дневник..." (RU) via a dedicated localization key separate from the collapsed placeholder.

#### Scenario: Return inserts a newline
- **WHEN** the Notes editor page field is focused and the user presses Return
- **THEN** a newline is inserted, the keyboard stays open, and the page draft is preserved

#### Scenario: Three-line reserve is stable
- **WHEN** the form opens with empty or short notes at any Dynamic Type size
- **THEN** the presenter occupies its 1–5 line window with no vertical jump when the draft changes or the editor page opens

#### Scenario: Overflow scrolls inside the editor
- **WHEN** the draft notes exceed the presenter window
- **THEN** the presenter truncates past line 5 while the editor page holds and scrolls the full text

#### Scenario: Placeholder shows only when empty
- **WHEN** the draft notes are empty
- **THEN** the presenter shows the localized collapsed notes placeholder ("Optional notes" / "Необязательные заметки"), and tapping it opens the editor page; the placeholder hides as soon as any text is present

#### Scenario: Expanded editor shows its own placeholder
- **WHEN** the Notes editor page opens with empty notes
- **THEN** the editor shows the dedicated expanded placeholder ("Dear diary..." / "Дорогой дневник..."), distinct from the collapsed presenter placeholder, and the expanded placeholder hides as soon as any text is present

#### Scenario: Notes clear clears the draft notes
- **WHEN** the editor page holds text and the user activates X
- **THEN** the page pops with the form draft notes unchanged (keystrokes discarded) while name, categories, and Start/End stay unchanged

#### Scenario: Notes clear keeps the keyboard open
- **WHEN** the user is editing on the Notes editor page
- **THEN** typing, newline insertion, and navigation keep the keyboard open until X/✓ or the system pop

#### Scenario: Notes clear hidden when nothing to clear
- **WHEN** the form is LOCKED (read-only)
- **THEN** no editing affordance is shown and the presenter offers no editor page

#### Scenario: Tap-away resigns but the clear button never does
- **WHEN** the user taps the Notes presenter in CREATE or EDIT mode
- **THEN** the dedicated editor page pushes prefilled with the current draft notes

#### Scenario: Chip taps still resign after the fix
- **WHEN** the user taps a category chip (or elsewhere on the form) rather than the Notes presenter
- **THEN** focus resigns exactly as before and the notes draft is untouched

#### Scenario: Locked notes render multiline read-only
- **WHEN** the form opens for an imported entry with multiline notes
- **THEN** the full notes render through the presenter read-only across lines, disabled and dimmed, with no editor page and no editing

#### Scenario: Save commits notes only
- **WHEN** the user edits notes on the editor page and activates ✓
- **THEN** the page pops, the form draft notes update to the edited text, and name, categories, and Start/End stay unchanged

#### Scenario: Counter shows name and live count
- **WHEN** the Notes editor page is open with a non-empty entry name
- **THEN** the subtitle pairs the name with the live counter (`<name> • <count>/2000`) updating as the user types

#### Scenario: Over-limit counter renders red
- **WHEN** the draft notes exceed 2000 runes on the editor page
- **THEN** the counter renders red while the page otherwise behaves identically

#### Scenario: Over-limit save shakes the subtitle without saving
- **WHEN** the user activates ✓ with notes past the bound
- **THEN** the counter subtitle shakes, the error haptic plays, the page stays open with the draft intact, and nothing is written back
