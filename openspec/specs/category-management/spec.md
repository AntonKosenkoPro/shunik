# Category Management Specification

## Purpose

Defines a local-first category catalog that users can manage from Profile and apply as optional, reusable tags to one or more Activities.
## Requirements
### Requirement: A starter category set is created once
The system SHALL create exactly one starter set for a new local dataset containing Work (`briefcase`), Hobby (`paintbrush`), Sport (`figure.run`), Education (`book`), Relax (`cup.and.saucer`), Sleep (`bed.double`), and Entertainment (`tv`). Starter names SHALL use the app's active supported language when the records are first created. Starter categories SHALL thereafter behave as ordinary user records and SHALL NOT be recreated merely because the user edits or deletes them.

#### Scenario: First launch in English
- **WHEN** a new local dataset is initialized while English is active
- **THEN** the seven starter categories are available with their English names and specified icons before category management or Activity editing is shown

#### Scenario: First launch in Russian
- **WHEN** a new local dataset is initialized while Russian is active
- **THEN** the same seven starter categories are available with localized Russian names and the same specified icons

#### Scenario: Initialization is retried
- **WHEN** starter initialization is attempted again after the starter set was committed
- **THEN** no starter category is duplicated or recreated

#### Scenario: User deletes every starter category
- **WHEN** the user deletes all starter categories and their undo windows expire
- **THEN** the category catalog remains empty until the user creates or synchronizes a category

#### Scenario: App language changes after seeding
- **WHEN** the app language changes after starter categories were created
- **THEN** existing category records retain their current user-editable names and are not silently renamed

### Requirement: Every category has a valid name and icon
Each category SHALL have a name that is non-empty after trimming surrounding whitespace and no longer than 60 characters, and exactly one icon from the supported catalog SF Symbol set. The supported set is the pre-existing 47-symbol catalog PLUS the 16 life-domains symbols below (63 total; no renames, no removals — stored raw values keep syncing):

- Pets: `pawprint`, `dog`, `cat`, `fish`, `bird`
- Home + housekeeping: `washer`, `dryer`, `dishwasher`, `refrigerator`, `sofa`, `shower`, `lamp.table`
- People + family: `person.2`, `figure.and.child.holdinghands`
- Body + rest: `stethoscope`, `pill`

Category names SHALL be unique after trimming and case-insensitive comparison. Invalid input SHALL leave the persisted catalog unchanged and SHALL present one localized error for the affected field. Every catalog symbol SHALL have an EN + RU VoiceOver name (`L10n.catalogIconName`); the icon picker shows only symbols that render on the running OS (`CatalogIcon.renderableSymbols`), and a valid synchronized symbol that cannot render is displayed as `tag` without changing the stored value.

#### Scenario: Create a valid category
- **WHEN** the user enters a unique valid name, selects a supported icon, and saves
- **THEN** one category is created with the trimmed name and selected icon

#### Scenario: Name is empty
- **WHEN** the user attempts to save a category whose name contains only whitespace
- **THEN** no category is created or updated and a localized name-required error is shown beneath the name field

#### Scenario: Name exceeds the limit
- **WHEN** the user attempts to save a category whose name exceeds 60 characters
- **THEN** no category is created or updated and a localized name-length error is shown beneath the name field

#### Scenario: Name collides by case or whitespace
- **WHEN** the user attempts to create or rename a category to a name that differs from another category only by case or surrounding whitespace
- **THEN** neither category is overwritten or merged and a localized duplicate-name error permits correction

#### Scenario: Create a category with a life-domains icon
- **WHEN** the user enters a unique valid name, selects one of the 16 life-domains icons (e.g. `pawprint`, `washer`, `person.2`, `stethoscope`), and saves
- **THEN** one category is created with the trimmed name and selected icon, and the icon renders in the category row, the picker, and (first-position) Recents chips / entry rows

#### Scenario: Dropped candidates are not selectable
- **WHEN** the user browses the icon picker on iOS 18
- **THEN** `turtle` and bare `lamp` are absent (both fail the runtime `canRender` check: `UIImage(systemName:)` returns nil), while `lamp.table` is present

#### Scenario: Existing icons are unchanged
- **WHEN** a category saved before this change syncs or renders after it
- **THEN** its stored icon raw value resolves to the same symbol as before (no renames or removals in the closed set)

#### Scenario: New icon has localized VoiceOver names
- **WHEN** VoiceOver focuses an icon option or category row using one of the 16 new symbols in English or Russian
- **THEN** it announces the localized icon meaning (e.g. "Paw print" / "След лапы") alongside the category name and action

#### Scenario: Icon is unsupported
- **WHEN** a category save carries an icon outside the supported catalog
- **THEN** the save is rejected and the persisted category remains unchanged

### Requirement: Profile owns category management

The system SHALL provide a Categories destination from Profile to the signed-in account in any connectivity state. It SHALL list categories alphabetically by localized name and allow the user to add and edit categories; deletion SHALL be initiated only from the category editor's Delete button — the list itself SHALL offer no swipe, context-menu, or other delete affordance. Category creation SHALL additionally be available inline from the unified entry form and from the running timer's tag row (see the inline-creation requirement); Profile remains the sole destination for browsing, editing, and deleting the catalog. An empty catalog SHALL show guidance for creating a category and SHALL NOT block Activity creation or timing.

#### Scenario: Open categories while offline

- **WHEN** a signed-in user opens Profile and activates Categories without connectivity
- **THEN** the Manage Categories surface opens from the active account's local data with create and edit controls available, and deletion is reached through the editor

#### Scenario: Edit an existing category

- **WHEN** the user selects a category from the list
- **THEN** an editor opens with the category's current name and icon prefilled, offering Delete alongside Save

#### Scenario: Add a category

- **WHEN** the user activates Add from Manage Categories
- **THEN** a category editor opens with an empty name and the default `tag` icon selected, with no Delete action (create mode)

#### Scenario: Catalog is empty

- **WHEN** Manage Categories contains no category records
- **THEN** it shows a localized empty state that guides the user to Add while other app features remain usable

#### Scenario: List offers no direct deletion

- **WHEN** the user swipes a category row or long-presses it
- **THEN** no delete affordance appears; the row opens the editor, where Delete lives

#### Scenario: Creation entry points

- **WHEN** the user needs a new category while logging or timing an entry
- **THEN** creation is reachable without leaving the entry context (entry form categories row, running-tag row), in addition to Manage Categories

### Requirement: Category edits are explicit and recoverable
The category editor SHALL preserve its draft until the user saves or cancels. Saving valid changes SHALL update the presenting host and dismiss or pop the editor: Manage Categories displays the persisted result; an entry-form or running-tag host reloads its options and selects the new category (see the inline-creation requirement). A persistence or synchronization-related conflict SHALL preserve or restore actionable user context rather than silently discarding an edit.

#### Scenario: Save succeeds
- **WHEN** the user saves a valid new or edited category
- **THEN** the editor dismisses and Manage Categories displays the persisted result

#### Scenario: Save succeeds from an entry context

- **WHEN** the user saves a valid new category from the entry form or the running-tag row
- **THEN** the editor pops back to the originating form, the new category appears in the selector options, and it arrives already selected on the originating draft

#### Scenario: User cancels
- **WHEN** the user cancels or dismisses the editor without saving
- **THEN** the persisted category catalog remains unchanged

#### Scenario: Local persistence fails
- **WHEN** a valid category cannot be persisted locally
- **THEN** the editor remains open with its draft intact and a localized error permits retry

#### Scenario: Newer remote edit wins
- **WHEN** synchronization reports that another device has a newer version of the category
- **THEN** the latest version becomes visible and the user receives a non-blocking localized conflict explanation

### Requirement: Category changes are local-first and synchronizable
Starter creation, category CRUD, deletion finalization, and entry-category assignment changes SHALL commit to the local source of truth without requiring an account or network. When sync is active, category records and complete per-entry category sets SHALL converge through the optional relay using the existing idempotent creation, last-write-wins update, and name-collision rules for category records themselves.

#### Scenario: Manage categories offline
- **WHEN** the user creates, edits, deletes, or assigns categories without connectivity
- **THEN** each successful action is immediately reflected locally and retained for later synchronization

#### Scenario: Synchronize category assignments
- **WHEN** an offline per-entry category edit later synchronizes successfully
- **THEN** another signed-in device receives the complete current category set for that entry

#### Scenario: Cross-device category name collision
- **WHEN** two devices create categories with equivalent normalized names and the relay selects one winning identity
- **THEN** local entry references are remapped to the winning category, the winning category is available locally, and no entry is lost

#### Scenario: Remote category deletion arrives
- **WHEN** a finalized category deletion from another device is received through synchronization
- **THEN** the category and its local entry associations are removed while entries remain intact

### Requirement: Category management is localized and accessible
All category-management copy SHALL be available in English and Russian, all interactive controls SHALL expose stable accessibility identifiers and meaningful labels, and category icons SHALL include the category name as accessible context rather than relying on the symbol alone. Interactive category controls SHALL expose a tap target of at least 44×44 points, and category chip selection SHALL be indicated by a visible ordinal-or-check affordance rather than color alone: a single selected chip shows a checkmark, while two or more selected chips each show their 1-based selection ordinal.

#### Scenario: VoiceOver navigates Manage Categories
- **WHEN** VoiceOver focuses a category row or editor icon option
- **THEN** it announces the category or icon meaning and the available action without requiring visual interpretation of the symbol

#### Scenario: Russian localization is active
- **WHEN** the app runs in Russian
- **THEN** category management, validation, confirmation, error, empty-state, and undo copy appears in Russian

#### Scenario: Chip selection is visible without color
- **WHEN** exactly one category chip in the entry form or running timer selector is selected
- **THEN** the chip shows a checkmark in place of the category icon while unselected chips show their icon, so the selected state remains perceivable without relying on color

#### Scenario: Multiple chip selection shows order without color
- **WHEN** two or more category chips in the entry form or running timer selector are selected
- **THEN** every selected chip shows its 1-based selection ordinal in place of the category icon or checkmark while unselected chips show their icon, so both the selected state and the selection order remain perceivable without relying on color

#### Scenario: VoiceOver announces chip selection order
- **WHEN** VoiceOver focuses a selected category chip while two or more chips are selected
- **THEN** it announces the category name, the selected state, and the chip's ordinal position (e.g. selected, 2 of 3) in the active locale

#### Scenario: Category chips meet minimum touch targets
- **WHEN** the Activity editor renders the category selector
- **THEN** every chip's interactive area is at least 44×44 points

### Requirement: Category deletion is undoable until the app restarts

A confirmed category deletion SHALL remain restorable until the earlier of a successful relay push of its `DELETE` (push-then-commit) or the next app restart — there is no wall-clock undo window. The category editor (edit mode) SHALL offer the destructive Delete action at the bottom of the form; confirming the destructive confirmation (which names the category and explains that Activity tags will be removed while entries remain available, with timeless undo copy — "You can shake to undo." and no lifetime bound) SHALL enter the durable undo buffer, dismiss the editor, and refresh the list. The entry-delete confirmation SHALL carry the same timeless undo copy. Until the buffer row commits, the Manage Categories surface SHALL offer restore through the DEFAULT system Undo confirmation only: shaking the device surfaces the system Undo prompt, and confirming restores exactly one deletion — the most recent buffered one. No UndoToast SHALL be shown. No deletion SHALL be sent to the relay while it is buffered. Undo SHALL restore the same category identity, values, and Activity assignments.

#### Scenario: Undo from the visible affordance

- **WHEN** the user activates Undo from the system Undo confirmation before the buffered deletion commits (no restart and no successful push of its `DELETE`)
- **THEN** the category and all prior Activity assignments are restored and no deletion is synchronized

#### Scenario: Undo through the system gesture

- **WHEN** the user invokes the system Undo gesture on Manage Categories (before the buffered deletion commits) and confirms
- **THEN** the most recent eligible category deletion is restored

#### Scenario: Restart commits buffered deletions

- **WHEN** the app restarts with a buffered category deletion
- **THEN** the deletion becomes final locally on cold launch and is queued for relay synchronization

#### Scenario: Successful push commits the buffered deletion

- **WHEN** a sync cycle successfully pushes the buffered deletion's `DELETE` for every snapshotted record
- **THEN** the buffer row is dropped and a later undo finds nothing to restore

#### Scenario: Backgrounding does not expire the buffer

- **WHEN** the app leaves the foreground with a buffered deletion and returns (without restarting and without a successful push of its `DELETE`)
- **THEN** the deletion is still restorable; nothing is finalized on any time boundary

#### Scenario: Delete confirmations carry timeless undo copy

- **WHEN** the user opens the entry-delete or category-delete confirmation in English or Russian
- **THEN** the undo sentence states only that shake-to-undo is available ("You can shake to undo." / "Отменить можно встряской.") with no sync, restart, or time bound

#### Scenario: Cancel category deletion

- **WHEN** the user cancels the destructive confirmation
- **THEN** the category and all of its Activity assignments remain unchanged

### Requirement: Category deletion preserves entries
Deleting a category SHALL remove that category's joins from every entry but SHALL NOT delete or otherwise modify any entry or timer draft. Before deletion, the system SHALL present a destructive confirmation that names the category and explains that entry tags will be removed while entries remain available.

#### Scenario: Delete an assigned category
- **WHEN** the user confirms deletion of a category assigned to one or more entries
- **THEN** the category disappears from the catalog and those entries, while the entries, their texts, notes, timings, and timer draft remain intact

#### Scenario: Cancel category deletion
- **WHEN** the user cancels the destructive confirmation
- **THEN** the category and all of its entry assignments remain unchanged

### Requirement: Entries support optional multiple category assignments
The unified entry form and the running timer's `TagSelector` SHALL display the available category catalog and allow zero, one, or multiple categories per entry with order preserved. The `TagSelector` SHALL offer an opt-in trailing creation chip (rendered last in the flow only when the host provides a creation action): a dashed-outline action chip with `plus` glyph and localized creation label — never a category icon, checkmark, or ordinal. The chip region SHALL hug content and clamp at up to 4 visible rows bounded by the finite available height, scrolling internally beyond the visible rows; smaller catalogs SHALL render compactly with no reserved dead space, short viewports (e.g. SE) SHALL show fewer rows with internal scroll, the timer/name/Stop frames SHALL be preserved, and the viewport SHALL never grow the page or slide under the tab bar. Entire-page scroll SHALL engage only as an accessibility fallback when the core controls cannot fit. Both chip groups SHALL carry the same border clearance: 1 pt top/bottom scroll-content padding plus a matching +2 pt max cap above the row clamp, so hairline chip borders never clip at the cut. Toggling categories SHALL NOT move, restyle, or select the creation chip. Saving SHALL persist that entry's ordered category set. Category assignment SHALL remain optional. There is no activity entity and no Activity editor — category chips live on entry forms and the running timer only. Recents chips SHALL display only the icon of the first category of each exact text's newest entry and SHALL NOT display category names. Whenever two or more categories are selected, each selected chip SHALL display its 1-based position in the selection order (tap order; deselect-then-reselect appends at the end); deselecting any chip SHALL renumber the remaining selected chips to the dense sequence 1…n. Ordinal presentation SHALL cap at 99 (a third digit is impossible). Ordinal changes (select, deselect, renumber, checkmark↔ordinal swap) SHALL animate with a fade. Selecting or deselecting chips SHALL NOT change chip geometry: the ordinal glyph fits the existing fixed symbol slot (two-digit ordinals shrink to fit) so surrounding rows never re-pack.

#### Scenario: Assign multiple categories
- **WHEN** the user selects two or more categories for an entry and saves
- **THEN** the entry is associated with every selected category in the chosen order

#### Scenario: Selection order is visible on chips
- **WHEN** the user selects a second category (tap order C then A)
- **THEN** the first-tapped chip shows 1 and the second-tapped chip shows 2, and the previously single-selected chip swaps its checkmark for its ordinal with a fade

#### Scenario: Deselecting renumbers remaining chips
- **WHEN** the user deselects a selected chip while two or more others stay selected
- **THEN** the remaining selected chips renumber to the dense sequence 1…n preserving their relative tap order, with a fade

#### Scenario: Returning to one selection restores the checkmark
- **WHEN** deselecting leaves exactly one category selected
- **THEN** the remaining chip swaps its ordinal back to the checkmark with a fade

#### Scenario: Remove one assignment
- **WHEN** the user deselects one category while leaving others selected and saves
- **THEN** only the deselected association is removed

#### Scenario: Clear all assignments
- **WHEN** the user deselects every category and saves
- **THEN** the entry remains valid with no categories

#### Scenario: Selection does not move surrounding layout
- **WHEN** the user selects or deselects categories (including reaching a two-digit ordinal count)
- **THEN** chip positions, row wrapping, and everything above the selector stay pixel-identical apart from the glyph/fill change itself

#### Scenario: Assignment save fails
- **WHEN** the entry and its selected category set cannot be committed together
- **THEN** neither the entry fields nor its persisted category set changes and the draft remains available for retry

#### Scenario: Capture inherits but never requires
- **WHEN** the user starts a timer or opens the entry form
- **THEN** no category is required, no category name appears except on Recents icons, and inherited categories remain fully editable

#### Scenario: Categoryless entry chip has no icon
- **WHEN** a Recents chip's newest entry has no categories
- **THEN** the chip renders with the exact text and no icon

#### Scenario: Creation chip is always last and distinct
- **WHEN** the entry form or running-tag selector renders with a creation action
- **THEN** a single creation chip appears after all category chips with action styling (dashed outline, plus glyph, localized label) that never participates in selection, and selecting or deselecting categories never moves, restyles, or selects it

#### Scenario: Chip region clamps at up to 4 rows of available height
- **WHEN** the catalog holds more categories than fit the visible viewport
- **THEN** the chip region shows up to 4 rows bounded by the finite available height (fewer rows on short viewports) and scrolls internally, with edge dividers marking hidden content, the timer/name/Stop frames preserved, and no tab-bar overlap

#### Scenario: Dividers follow the scroll edges
- **WHEN** the chip region is scrolled down from the top
- **THEN** a hairline divider fades in above the viewport, marking content hidden above

#### Scenario: Bottom divider hides at the content end
- **WHEN** the chip region is scrolled to its end
- **THEN** the bottom divider fades out at the content end

#### Scenario: No dividers when everything fits
- **WHEN** the catalog fits in the viewport without scrolling
- **THEN** neither divider appears

#### Scenario: Small catalogs stay compact
- **WHEN** the catalog fits in fewer than the available row budget (at most 4 rows)
- **THEN** the chip region sizes to its content with no reserved dead space

#### Scenario: No creation action means select-only
- **WHEN** a `TagSelector` host provides no creation action
- **THEN** no creation chip renders and the selector behaves exactly as before (select-only)

### Requirement: Inline category creation from entry contexts
The entry form (CREATE and EDIT modes) and the running timer's tag row SHALL offer inline category creation through the `TagSelector` trailing creation chip: a dashed-outline action chip with `plus` glyph and localized label, rendered last in the flow. Activating the chip SHALL push the full category editor (name field plus icon grid, identical validation and duplicate rules as Profile creation) onto the host navigation stack — the CREATE sheet's internal stack, the History stack for pushed entry forms, or the Track stack — and SHALL NEVER present a second sheet over the CREATE sheet. Saving a valid new category SHALL pop back to the originating form, reload its category options, and append the new category id to the originating selection in tap order (entry-form drafts and the running timer draft alike). The creation chip SHALL be reachable only while the timer runs or from the entry form: in every non-running Track state the slot shows Recents and the tag row (with its creation chip) is hidden and ignores hits. A duplicate name SHALL keep the editor open with the localized duplicate-name error and the draft intact, identical to Profile creation. The creation chip SHALL expose a stable accessibility identifier distinct from category-chip identifiers, a localized VoiceOver label naming the creation action (without embedding the Button trait word), and a 44 pt minimum tap target; all copy SHALL be localized in English and Russian.

#### Scenario: Create from the entry form
- **WHEN** the user activates the creation chip in the entry form's categories row, enters a unique valid name with an icon, and saves
- **THEN** the editor pops back to the entry form whose draft is otherwise intact, and the new category appears selected in the selector

#### Scenario: Create while the timer runs
- **WHEN** the user activates the creation chip in the running-tag row, enters a unique valid name with an icon, and saves
- **THEN** the editor pops back to Track, the running draft gains the new category id in tap order, and the persisted draft snapshot updates

#### Scenario: Creation chip unreachable while idle
- **WHEN** no timer is running (idle, ready, saving, or saved states)
- **THEN** the below-button slot shows Recents and the tag row with its creation chip stays hidden, ignores hits, and stays silent for VoiceOver

#### Scenario: Duplicate name from an entry context
- **WHEN** the user attempts to save a name that differs from an existing category only by case or surrounding whitespace
- **THEN** no category is created, the editor stays open with the draft intact, and a localized duplicate-name error permits correction

#### Scenario: Cancel keeps both drafts
- **WHEN** the user goes back from the pushed editor without saving
- **THEN** the catalog is unchanged and the originating entry or timer draft is exactly as before

#### Scenario: VoiceOver identifies the creation chip
- **WHEN** VoiceOver focuses the creation chip in English or Russian
- **THEN** it announces the localized creation action (e.g. new-category wording) as a button, distinct from any category chip

### Requirement: Each entry snapshots its own categories
Entries SHALL store their own ordered category set at creation. Later category edits on other entries, renames of categories, or retags elsewhere SHALL NOT reclassify existing entries. Deleting a category SHALL strip it from all entries without touching their texts, notes, or timings.

#### Scenario: Retag affects one entry only
- **WHEN** the user changes one entry's categories
- **THEN** no other entry with the same text changes

#### Scenario: Delete an assigned category
- **WHEN** an assigned category is deleted
- **THEN** existing entries cease to list that category while retaining their text, notes, and timing data

### Requirement: Category-editor name field has a clear button
The category-editor name field SHALL offer a trailing clear (`×`) button visible only when the field is focused AND holds non-empty text, with the same Apple-standard look (small dim `xmark.circle.fill`, 44 pt tap target). One tap SHALL clear the draft name; field validation re-evaluates. The shared field component's clear affordance is opt-in per call site and defaults to off (the email-OTP field has none). The field's rendered height SHALL NOT change when the clear button appears or disappears: the text input SHALL carry a minimum height of 44 pt so the 44 pt button fits inside an already-44 pt row, and the input card SHALL use horizontal-only padding so the card stays compact (~44 pt, NamePicker parity) instead of ballooning with full padding. Focus state SHALL be bound to the text field itself (programmatic focus moves to the field; user focus updates the binding), never to a wrapper container. The editor SHALL autofocus the name field after the sheet presentation settles, and the focused field SHALL be fully inside the visible viewport (never partly clipped by the navigation bar, keyboard, or sheet edge) in both create and edit modes.

#### Scenario: Category name clear hidden when unfocused or empty
- **WHEN** the category-editor name field is empty or unfocused
- **THEN** no clear button is shown

#### Scenario: Category name clear clears the draft name
- **WHEN** the category-editor name field is focused and holds text
- **THEN** a trailing `×` is visible, and one tap empties the field

#### Scenario: Field height is stable when the clear button appears
- **WHEN** the user types the first character into the focused empty name field (create mode), or focuses the prefilled field (edit mode)
- **THEN** the trailing `×` appears with no change to the field's rendered height and no shift of the content below it

#### Scenario: Field height is stable when the clear button disappears
- **WHEN** the focused name field loses focus (e.g. keyboard Done) while holding text, or its text is cleared
- **THEN** the trailing `×` hides with no change to the field's rendered height

#### Scenario: Name field card is compact in both modes
- **WHEN** the category editor renders the name field in create or edit mode, with or without the clear button
- **THEN** the input card is ~44 pt tall (44 pt row with horizontal-only padding), matching the app's other plain-text fields

#### Scenario: Prefilled editor opens with a compact fully-visible field
- **WHEN** the category editor opens in edit mode (name prefilled, autofocused)
- **THEN** the name field renders at its compact single-line height, fully inside the visible viewport, with the keyboard open

#### Scenario: Programmatic focus reaches the text field
- **WHEN** the editor requests autofocus on appear
- **THEN** the name text field becomes first responder (caret visible, keyboard open) in both create and edit modes

### Requirement: Category editor uses toolbar X and checkmark affordances
The category editor (create and edit modes) SHALL offer cancellation as a toolbar `xmark` button and saving as a toolbar `checkmark` button, matching the Log Time sheet grammar — no text Cancel button and no bottom Save bar. The ✓ button SHALL be disabled while the draft name is invalid (empty/whitespace-only, over 60 characters) or a save is in flight; activating it with a valid draft SHALL save through the atomic `LocalStore` mutation and dismiss on success, preserving the draft and staying open on duplicate, stale, or persistence outcomes. The X button SHALL dismiss without saving (identical to the previous Cancel paths, including disabled-while-saving). Both buttons SHALL expose stable accessibility identifiers and meaningful VoiceOver labels.

#### Scenario: Checkmark saves a valid category
- **WHEN** the user activates ✓ with a unique valid name and supported icon
- **THEN** the category is created/updated, the editor dismisses, and Manage Categories shows the result

#### Scenario: Checkmark disabled for invalid drafts
- **WHEN** the draft name is empty, whitespace-only, or over the length limit, or a save is in flight
- **THEN** ✓ is disabled and no save is attempted

#### Scenario: X discards the draft
- **WHEN** the user activates X without a save in flight
- **THEN** the editor dismisses and the persisted catalog remains unchanged

#### Scenario: VoiceOver identifies the toolbar actions
- **WHEN** VoiceOver focuses the X or ✓ button in English or Russian
- **THEN** it announces the cancel/save meaning and the available action

