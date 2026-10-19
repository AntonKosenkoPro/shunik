## MODIFIED Requirements

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

## ADDED Requirements

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
