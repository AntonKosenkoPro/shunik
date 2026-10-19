# Entry Editor Specification

## Purpose

Lets users correct and remove logged time with one shared surface: the entry form used for manual creation also edits a committed entry's activity and interval, or deletes it with confirmation and shake-to-undo — while imported entries stay read-only except for delete.
## Requirements
### Requirement: Unified entry form with CREATE, EDIT, and LOCKED modes
The app SHALL provide a single entry form with three modes sharing one layout — input cards in Name → Start → End → Categories → Notes order (Start and End as separate cards with date + time pills and inline single-open pickers; device locale and calendar) — and one validity gate (the confirm action is enabled only when the trimmed name is non-empty AND the interval satisfies the floor rule: untouched prefilled intervals use the end-strictly-after-start rule with the sub-minute display-mapping requirement applied, while any draft whose times were manually edited requires the end at least one minute after the start; otherwise disabled with no error text). CREATE mode SHALL behave per the manual-entry capability (Log Time copy, X/✓ chrome, sheet presentation). EDIT mode SHALL be titled "Edit entry" (localized) with Back + checkmark actions in the navigation bar when pushed. LOCKED mode SHALL show the entry read-only with Back only and no confirm action. The form SHALL use Theme semantic colors only, with all user-facing strings localized (EN + RU). With any inline picker expanded, the form SHALL keep its card margins on 320 pt screens: no card goes edge-to-edge and no content clips at the screen edges. The Start and End cards SHALL stretch to the same full card width as the Name, Categories, and Notes cards in every mode, whether their inline picker is collapsed or expanded: a collapsed card SHALL NOT hug its date/time pills.

#### Scenario: Edit mode titles and actions
- **WHEN** the form opens for an existing `manual` entry
- **THEN** the title reads "Edit entry" (localized) with Back and a ✓ confirm action — the same Name/Start/End/Categories/Notes cards as creation

#### Scenario: Validity gate applies in edit mode
- **WHEN** the form holds an end equal to or before the start, or an empty trimmed name, in EDIT mode
- **THEN** the confirm action is disabled with no error text, matching creation behavior

#### Scenario: Grandfathered sub-minute draft stays savable
- **WHEN** the form holds an untouched prefilled interval shorter than one minute with a non-empty name
- **THEN** the confirm action is enabled and saving writes back the original times

#### Scenario: Edited draft under one minute is disabled
- **WHEN** the user manually edits the times to an interval shorter than one minute with a non-empty name
- **THEN** the confirm action is disabled with no error text (unreachable via the pickers, which forbid it — the gate is a safety net)

#### Scenario: Locked mode titles and actions
- **WHEN** the form opens for an entry with a non-`manual` source
- **THEN** the title identifies the entry as imported with Back only and no confirm action

#### Scenario: Collapsed Start/End cards stretch full width
- **WHEN** the form opens (or all inline pickers are collapsed) in any mode
- **THEN** the Start and End cards span margin-to-margin exactly like the Name, Categories, and Notes cards, with the date + time pills leading-aligned inside

#### Scenario: Expanded picker stays inside the cards on small screens
- **WHEN** the user expands a date or time picker on a 320 pt screen in any mode
- **THEN** the cards keep their horizontal margins, the picker renders within the card width, and no text or control touches or clips at the screen edges

### Requirement: EDIT mode saves through last-write-wins update
EDIT mode SHALL prefill the Name, Categories, Notes, and Starts/Ends pills from the entry (sub-minute prefills use the display mapping with touch-to-adopt: pills show the mapped times while the backing times stay original until a time picker is touched). Activating Save on a valid form SHALL persist the changes through the local store's last-write-wins entry update (bumping `updated_at`, enqueuing the sync outbox row in the same transaction), dismiss the form, and refresh the underlying lists so the entry appears with its new values in the correct day group. Saving an untouched sub-minute draft SHALL write back the original times. Overlapping entries and future end-times SHALL be allowed, matching creation. Retexting or retagging SHALL affect only this entry. When the record changed underneath (stale write), the app SHALL show a localized error with the draft intact and the form open.

#### Scenario: Successful edit
- **WHEN** the user changes the end time of a `manual` entry and activates Save
- **THEN** the form dismisses and the entry shows the new interval and derived duration in its day group

#### Scenario: Stale write keeps the draft
- **WHEN** Save loses the last-write-wins race (the entry changed underneath, e.g. by sync)
- **THEN** a localized error is shown, the draft is preserved, and the form stays open

#### Scenario: Reassignment moves the entry
- **WHEN** the user retexts or retags an entry and saves (reassignment is now per-entry text/category change, not a move between activities)
- **THEN** the entry shows the new values in History and no other entry with the old text changes

#### Scenario: Overlap is allowed in edit mode
- **WHEN** the edited interval overlaps another entry
- **THEN** Save stays enabled and saving succeeds

### Requirement: Entry delete needs confirmation and enters the undo buffer
EDIT and LOCKED modes SHALL offer a destructive Delete action at the bottom of the form (below the input cards, red destructive styling). Activating it SHALL present a destructive confirmation alert titled "Delete this entry?" with an entry-focused message naming the entry's text (never an activity — no activity entity exists); confirming SHALL remove the entry from all lists immediately, enter the durable undo buffer (full snapshot, no outbox row yet — the relay is never notified of an undone deletion), dismiss the form, and refresh the underlying lists. No UndoToast SHALL be shown in this change. The deletion SHALL stay restorable through the DEFAULT system Undo confirmation until the app restarts (no wall-clock window): shaking the device surfaces the system Undo prompt, and confirming restores exactly one entry — the most recent buffered deletion (the registration is cleared-then-single, so one shake+confirm can never restore two). Cold launch SHALL commit the deletion (outbox delete row) with no restore path afterwards. Only the most recent buffer row SHALL be restorable (supersession, including across surfaces — an entry delete followed by a category delete leaves only the category undoable on this surface). Dismissing the confirm alert SHALL leave the entry and the draft unchanged.

#### Scenario: Confirmed delete removes the entry
- **WHEN** the user confirms deletion of an entry
- **THEN** the form dismisses and History no longer shows the entry

#### Scenario: Delete confirmation cancels cleanly
- **WHEN** the user dismisses the delete confirmation without confirming
- **THEN** the entry is unchanged and the form draft is intact

#### Scenario: Shake offers the system Undo confirmation, confirm restores one entry
- **WHEN** the user shakes the device after confirming an entry deletion while the process is still alive
- **THEN** the system Undo confirmation is offered, and confirming restores the entry with its text and values back into its day group, with nothing synced (one shake+confirm restores at most one deletion — the most recent one)

#### Scenario: Expired deletion commits on foreground
- **WHEN** the buffered deletion is still present at restart (no wall-clock window — restorable until restart)
- **THEN** the deletion commits and syncs as a hard delete with no restore path

### Requirement: Imported entries are read-only except delete
Entries with a non-`manual` source SHALL open in LOCKED mode: the Activity row, Starts/Ends pills, and pickers SHALL be disabled (dimmed, non-interactive) and no Save action SHALL be present. The form SHALL show a read-only provenance note with the localized source name explaining that editing is disabled to avoid conflicts with the external source of truth. Delete (with confirmation, into the undo buffer) SHALL remain available in LOCKED mode.

#### Scenario: Locked controls cannot be changed
- **WHEN** the form opens for an entry with `source='garmin'`
- **THEN** Activity, Starts, and Ends are disabled and dimmed, no Save is offered, and a note names the source and states editing is disabled

#### Scenario: Imported entry can still be deleted
- **WHEN** the user deletes an imported entry and confirms
- **THEN** the entry enters the undo buffer exactly like a manual entry (restorable by shake within 30 s)

### Requirement: Entry-form name clear shows only when focused and non-empty
The entry-form Name row's trailing clear (`×`) button SHALL be visible only when the field is focused AND holds non-empty text and the form is editable (hidden in LOCKED mode, when unfocused, or when empty); one tap SHALL clear the draft name (categories, notes, and interval untouched; the validity gate re-evaluates). The button uses the Apple-standard trailing look (small dim `xmark.circle.fill`, 44 pt tap target).

#### Scenario: Name clear hidden when unfocused
- **WHEN** the entry-form name field holds text but is not focused
- **THEN** no clear button is shown

#### Scenario: Name clear clears the draft name
- **WHEN** the entry-form name field is focused, holds text, and the form is editable
- **THEN** a trailing `×` is visible, and one tap empties the field while categories, notes, and Start/End stay unchanged

### Requirement: Entry-form Notes row has a clear button
The entry-form Notes row SHALL present a read-only multiline presenter instead of an inline editor: a `Text` label with a 1–5 line window that shows the localized notes placeholder when the draft notes are empty and truncates past 5 lines. The presenter SHALL carry the caption row with a trailing chevron in balanced corner margins (the caption row's top inset equals the card's trailing inset; approved spike variant B). Tapping the presenter SHALL push a dedicated Notes editor page carrying X (cancel/discard) and ✓ (save/commit) in the navigation bar with no system Back button (X is the sole cancel path; swipe-back still pops and discards). The editor page SHALL show a live localized subtitle pairing the entry name with the notes counter (`<name> • <count>/2000`, name omitted when empty), counting every rune against the 2000 bound. Past the bound the counter SHALL render red; the confirm action SHALL stay enabled and an over-limit save attempt SHALL shake the counter subtitle and play the error haptic without saving or popping. The 2000-rune notes cap is enforced by the relay; the 60-char name bound is unchanged. In LOCKED mode the presenter SHALL render multiline read-only (disabled and dimmed) with no editing and no navigation. All strings localized (EN + RU), `Theme` semantic colors only.

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
- **THEN** the presenter shows the localized notes placeholder, and tapping it opens the editor page; the placeholder hides as soon as any text is present

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

### Requirement: Notes clear never dismisses the keyboard
Tapping the Notes-row clear (`×`) SHALL clear the field and keep the keyboard open with no dismiss/reappear transition. Taps on the card's labels, padding, and background SHALL still resign focus, and taps on the name row, category chips, and start/end pills SHALL still resign focus. Taps on the expanded graphical calendar's day cells SHALL select that date: the card's tap-away dismissal SHALL NOT swallow them.

#### Scenario: Clear notes with keyboard open
- **WHEN** the Notes field is focused with non-empty text and the user taps `×`
- **THEN** the field empties, the keyboard stays open and focused, and no dismiss animation plays

#### Scenario: Tap-away still dismisses
- **WHEN** the user taps a card label, padding, or background
- **THEN** the keyboard dismisses as before

#### Scenario: Control taps still dismiss
- **WHEN** the user taps the name row, a category chip, or a start/end pill
- **THEN** the tapped control acts and the keyboard dismisses as before

#### Scenario: Calendar day taps select the date
- **WHEN** a Start or End date picker is expanded and the user taps a visible day cell
- **THEN** the draft date updates to that day (date pill text, duration subtitle, and validity gate re-evaluate; moving Start shifts End per the always-preserve duration rule) and the picker stays expanded

### Requirement: Unified entry form field order
The unified entry form SHALL lay out its input cards in exactly this order in every mode (CREATE, EDIT, LOCKED): Activity name → Start time → End time → Categories → Notes. Start and Ends SHALL be separate cards (one `timeRow` each with its own date + time pills and inline single-open picker), not one combined Starts/Ends card. The validity gate, picker behavior (single-open, device locale/calendar), mode chrome (titles/actions/LOCKED dimming + provenance note), and bottom destructive Delete are unchanged.

#### Scenario: Card order in CREATE mode
- **WHEN** the Log Time sheet opens for a new entry
- **THEN** the cards read top-to-bottom: Name, Start, End, Categories, Notes

#### Scenario: Card order in EDIT mode
- **WHEN** the form opens for an existing `manual` entry
- **THEN** the cards read top-to-bottom: Name, Start, End, Categories, Notes with the same pills/pickers as creation

#### Scenario: Card order in LOCKED mode
- **WHEN** the form opens for an imported entry
- **THEN** the cards read top-to-bottom: Name, Start, End, Categories, Notes, disabled-dimmed with the provenance note and no Save action

### Requirement: All native gestures work in the entry form
The entry form SHALL NOT disable, block, or work around any system gesture to accommodate layout. Pull-down-to-scroll SHALL scroll the form with any picker open or closed; swipe-down-to-dismiss SHALL dismiss the sheet/cover presentation; the edge-back gesture SHALL pop the form wherever a back stack exists; tapping outside a focused text field SHALL dismiss the keyboard. If a presentation kills a system gesture, the presentation SHALL change (navigation push or interactive dismiss) rather than patching the gesture.

#### Scenario: Scroll with picker open
- **WHEN** a date or time picker is expanded and the user drags vertically starting outside the picker wheels
- **THEN** the form scrolls; the wheel picker never traps the scroll gesture

#### Scenario: Dismiss and back gestures
- **WHEN** the form is presented and the user swipes down (sheet/cover) or swipes back from the leading edge (pushed onto a navigation stack)
- **THEN** the form dismisses/pops with the draft discarded and no entry created or changed

#### Scenario: Keyboard dismissal
- **WHEN** the name or notes field is focused and the user taps outside the field or scrolls
- **THEN** the keyboard dismisses and the draft is preserved

### Requirement: Entry form shows a live duration subtitle in the navigation bar
The entry form SHALL show a live duration subtitle in the form's navigation bar in every mode (CREATE, EDIT, LOCKED): a `ToolbarItem(.principal)` VStack with the mode title (`Log Time` / `Edit entry` / `Imported entry`, localized) plus a footnote duration line. The duration line SHALL update live from the draft interval, formatted with the History natural-language duration (`33s`, `1m 20s`, `1h 12m`, `1d 12h`) prefixed by the localized `Duration` label; a grandfathered untouched sub-minute draft SHALL show its true duration (e.g. `33s`) even though the pills show the mapped times. When the interval is invalid (confirm disabled by the interval: end at or before start, or a manually edited interval under one minute), the subtitle SHALL show a localized explanatory text (e.g. `End must be after Start`) in `Theme.danger` instead of a duration — it explains *why* the confirm action is disabled. The subtitle SHALL use `Theme` semantic colors only, with all user-facing strings localized (EN + RU); the footnote line SHALL be a single line (inline-mode truncation).

#### Scenario: Valid interval shows a live duration
- **WHEN** the form holds an end at least one minute after the start
- **THEN** the nav bar shows the mode title plus a footnote `Duration: <natural-language duration>` line that updates as Start/End change

#### Scenario: Grandfathered draft shows the true duration
- **WHEN** the form holds an untouched prefilled interval of 33 seconds
- **THEN** the nav bar footnote shows `Duration: 33s` while the pills show the mapped 1-minute pair

#### Scenario: Invalid interval explains why the confirm is disabled
- **WHEN** the form holds an end equal to or before the start, or a manually edited interval under one minute
- **THEN** the nav bar footnote shows the localized invalid-interval text in `Theme.danger` instead of a duration

#### Scenario: Locked mode keeps the read-only subtitle
- **WHEN** the form opens for an imported entry
- **THEN** the subtitle shows that entry's fixed interval duration (or the invalid text), never editable

### Requirement: Entry-form name row has autocomplete suggestions
(Clear-button behavior for this row — focused-AND-non-empty visibility, editable only — is owned by the "Entry-form name clear shows only when focused and non-empty" requirement.) The entry-form Name row SHALL open the shared dedicated name-picker page (`name-picker` capability) instead of rendering an inline suggestion list. Tapping the Name row in an editable form (CREATE or EDIT mode) SHALL push the picker prefilled with the current draft name. Picking a suggestion or completing with Done SHALL fill the field with that exact text and inherit that entry's full ordered categories (the Recents tap contract); suggestions SHALL cover every committed name (newest-first, uncapped) and SHALL never mutate committed history. LOCKED mode is unchanged: the Name row stays read-only and never opens the picker.

#### Scenario: Tapping the Name row opens the picker
- **WHEN** the user taps the entry-form Name row in CREATE or EDIT mode
- **THEN** the shared picker pushes prefilled with the current draft name

#### Scenario: Typing shows prefix suggestions
- **WHEN** the user types a non-empty prefix matching one or more committed names on the picker page
- **THEN** those names are suggested newest-first, including the exact text already in the field

#### Scenario: Picking a suggestion fills text plus categories
- **WHEN** the user picks a suggestion or completes with Done on the picker page
- **THEN** the field fills with that exact text and the ordered categories become that entry's categories; no committed entry changes

#### Scenario: Exact-text identity is case-sensitive
- **WHEN** committed names hold both `Gym` and `GYM` and the user types `g`
- **THEN** both are suggested; typing the exact `Gym` suggests `Gym` itself (plus longer prefix matches)

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

### Requirement: Untouched drafts use a display mapping with touch-to-adopt

Pills and picker selections SHALL show minute-exact display values: the minute floor of Start, and for End the minute floor — except an EDIT prefill whose duration is strictly between zero and one minute (0 < end − start < 60s), where the End pill SHALL show `floor(start)` plus one minute (flooring both ends there would collapse, e.g. 0:00:15–0:00:25 to the invalid 0:00–0:00 pair). The pill time formatter truncates seconds, so pills always agree with the mapping. An EDIT prefill with 0 < duration < 60s SHALL keep its backing times untouched: the duration subtitle SHALL show the true duration (e.g. `33s`), the confirm action SHALL stay enabled for such untouched drafts, and saving SHALL write back the original backing times — a category/notes-only edit SHALL never force a time change. The first write through any of the four time pickers (Start/End × date/time) SHALL minute-normalize both ends (floor both — e.g. 23:59:34–00:01:58 becomes 23:59–00:01, 2m; 23:59:34–00:02:03 becomes 23:59–00:02, 3m), then apply the gesture on top; from then on the 1-minute floor and End picker ranges (manual-entry capability) apply and saving writes the draft. Normalization of a draft of at least one minute provably keeps at least one minute, so it SHALL never disable the confirm action by itself. End picker ranges SHALL derive from the minute-exact display values so the picker's selection always lies inside its range. A prefill with end at or before start SHALL keep the existing invalid path (confirm disabled, unbounded End date picker).

#### Scenario: Sub-minute prefill displays mapped times with true subtitle

- **WHEN** the form opens for a `manual` entry holding 2:35:00–2:35:33
- **THEN** the Start pill shows 2:35, the End pill shows 2:36, the subtitle shows the true `33s`, and the confirm action is enabled

#### Scenario: Draft with seconds displays floored pills with true subtitle

- **WHEN** the form opens for a `manual` entry holding 23:59:34–00:01:58 (2m24s)
- **THEN** the Start pill shows 23:59, the End pill shows 00:01, the subtitle shows the true `2m 24s`, and the confirm action is enabled

#### Scenario: Category-only edit preserves original times

- **WHEN** the user changes only categories on such a draft and activates Save without touching any time picker
- **THEN** the entry keeps its original 2:35:00–2:35:33 times with the new categories

#### Scenario: First time touch drops seconds on both ends

- **WHEN** the user moves any time picker on a 23:59:34–00:01:58 draft without moving it (adopts the displayed value)
- **THEN** the draft becomes the minute-exact 23:59–00:01 pair (2m), and saving writes the normalized draft

#### Scenario: First time touch adopts display values

- **WHEN** the user moves any time picker on a 2:35:00–2:35:33 draft
- **THEN** the draft becomes the displayed 2:35–2:36 pair first, the gesture applies on top, and saving writes the resulting draft (always at least one minute long)

#### Scenario: Corrupt prefill keeps unbounded pickers with disabled confirm

- **WHEN** the form opens for a `manual` entry whose end precedes its start
- **THEN** the End date picker is unbounded, the confirm action is disabled with the invalid-interval subtitle, and saving is refused

