# Entry Form (unified)

Implements the `entry-editor` + `manual-entry` capabilities: the single unified entry form (`LogTimeView`) for CREATE (Log Time sheet from the History toolbar `[+]`), EDIT (`manual` entries pushed from History), and LOCKED (imported entries — read-only with delete only). Styled on the iOS Calendar add-event form. There is no separate entry-detail surface.

## View: LogTimeView

- **File**: `ios/TimeOfLife/TimeOfLife/Features/ManualEntry/Views/LogTimeView.swift`
- **ViewModel**: `LogTimeViewModel`
- **Routes**: CREATE as a full-height `.sheet` (toolbar `xmark` cancel + `checkmark` confirm); EDIT/LOCKED pushed onto the History `NavigationStack` (system Back + `checkmark`, so the edge-back gesture works — never nested stacks)

### Layout

Five cards in fixed order: Name, Start, End, Categories, Notes (`FormCard` sections). Start/End are separate cards, each with date + time pills and an inline single-open picker (Calendar behavior: one open at a time; tapping the active pill collapses it).

### Behaviors

- Validity gate: confirm disabled until the trimmed name is non-empty and End is strictly after Start.
- Name field opens the shared `NamePicker` contract (exact-text identity, ordered-category inheritance).
- Categories: shared ordered `TagSelector` (select-only, zero allowed).
- Notes: read-only multiline presenter (1–5 line window, collapsed `entry.notesPlaceholder` copy) pushing the shared `NotesEditorPage` (expanded `notes.editorPlaceholder` copy — see `COMPONENTS.md`); LOCKED mode renders read-only with no navigation.
- LOCKED mode shows values read-only with Back only (no confirm); EDIT and LOCKED both offer bottom destructive Delete (single confirm naming the entry text → durable undo buffer, shake-to-undo, no toast).
- Save failure surfaces as a non-field error with the draft intact and the form open.
- No system gesture is ever disabled (pickers keep non-picker grab area so pull-down-to-scroll reaches the outer `ScrollView`).
- Follows `INTERACTIONS.md` → Editor sheets and keyboard placement (full-height sheet, no detents; name field focused on appear; primary action follows the keyboard).

### Implementation checklist

- [ ] All colors use `Theme.*` tokens.
- [ ] All strings use `L10n.*` keys (EN + RU).
- [ ] Name/Start/End/Categories/Notes cards in fixed order.
- [ ] CREATE sheet vs EDIT/LOCKED push presentations correct.
- [ ] Delete confirm names the entry text; undo via system prompt only.
- [ ] Previews exist (CREATE + EDIT + LOCKED).
