# Timer Capture Experience Specification

## Purpose

Defines a focused, local-first timer capture journey in which a centered numeric timer communicates exact actionable timer state and every start follows an explicit Activity selection.
## Requirements
### Requirement: Numeric timer is an instrumental readout
The Track numeric timer SHALL represent only timer readiness and exact elapsed timing; it SHALL NOT display fabricated progress, daily totals, goals, rings, sweeps, or history while idle.

#### Scenario: Nothing selected
- **WHEN** no name is entered and no timer is running
- **THEN** the numeric timer presents `00:00` and a clear action to enter a name

#### Scenario: Activity prepared
- **WHEN** the user enters a trimmed non-empty name or taps a recent
- **THEN** the numeric timer presents that name in a ready state with an explicit Start action and zero elapsed duration

#### Scenario: Timer running
- **WHEN** the user starts the prepared name
- **THEN** the numeric timer displays the exact live elapsed duration, including completed hours, without a secondary progress visualization

### Requirement: Starting always requires explicit confirmation
Selecting a recent or typing a name SHALL prepare it without starting a timer; the timer SHALL begin only after the user activates Start. Unconfirmed typed input SHALL NOT start a timer or create an entry. A focused Start tap SHALL resign the field immediately (selection haptic fires and `started_at` is captured at tap time) and delay the running swap until the keyboard finishes dismissing (real `didHide`, bounded fallback for hardware keyboards); the swap SHALL then render instantly with no animation of its own. A Start tap SHALL start timing on the first tap using the field's current text, even when the committed preparation went stale (for example edited after a stop): the tap SHALL bring the preparation up to date before the swap is scheduled, so the resign that follows finds nothing to cancel. Any other field edit or chip tap before the swap fires SHALL cancel the deferred start.

#### Scenario: Select recent activity
- **WHEN** the user taps a recent chip
- **THEN** the app fills the exact text plus that recent's full ordered categories and shows the ready numeric timer without creating an entry

#### Scenario: Select or create through search
- **WHEN** the user types a trimmed non-empty name, whether or not it exactly matches a recent (no search sheet exists; typing is the only input)
- **THEN** the app shows the ready numeric timer without starting timing; an exact-recent match prefills that recent's categories, otherwise categories start empty

#### Scenario: Search input remains unresolved
- **WHEN** the user has typed text but has not activated Start
- **THEN** nothing starts, no entry is created, and the typed text stays editable in the name field

#### Scenario: Start selected activity
- **WHEN** a name is prepared and the user activates Start
- **THEN** the app persists the running draft immediately, begins elapsed-time presentation, and emits a subtle selection haptic

#### Scenario: Focused Start waits for keyboard dismissal
- **WHEN** the user activates Start while the name field is focused
- **THEN** the field resigns at once with haptic feedback and tap-time `started_at`, and the running swap fires only after the keyboard finishes dismissing (bounded fallback when no dismissal notifies)

#### Scenario: Deferred start cancels on edit
- **WHEN** the user edits the field or taps a chip after a focused Start tap but before the swap fires
- **THEN** the deferred start is cancelled and no timer starts with the stale draft

#### Scenario: Start after a post-stop edit starts on the first tap
- **WHEN** the user edits the name after a stop (the committed preparation is stale for the field's current text) and activates Start with the field focused
- **THEN** the timer starts on that first tap with the field's current text once the keyboard dismisses; no second tap is needed

#### Scenario: Running swap renders instantly
- **WHEN** the running swap fires
- **THEN** Stop appears in place with no fade, slide, or spring of its own; the keyboard's own slide moves the whole layout together

### Requirement: Track uses an adaptive two-ended vertical layout
Track SHALL arrange its content in this top-to-bottom order: navigation title, top adaptive spacing, completion mark region, timer numbers, timer status, reserved non-field-error region, central separator, Activity search/refine row when applicable, the state-specific main action, Recents when applicable, bottom adaptive spacing, and the tab bar. The top and bottom adaptive spacing regions SHALL use one shared maximum height selected through approved layout spikes, SHALL resolve to equal heights from the remaining space, SHALL shrink toward zero when vertical space is constrained, and SHALL yield before content clips, overlaps, or becomes unreachable. Free space beyond twice the shared maximum SHALL go to the central separator between the error region and the search/refine flow. Placing the main action above Recents SHALL keep the Choose Activity, Start, and Stop controls reachable without scrolling. The local-first Track screen SHALL NOT display an offline hint.

#### Scenario: Roomy screen uses the approved spacing cap
- **WHEN** Track appears on a screen with more free space than twice the approved shared maximum
- **THEN** the top and bottom adaptive spacing regions each hold at the shared maximum and the remaining space sits in the central separator between the error region and the search/refine flow, preserving the required content order

#### Scenario: Moderate free space splits evenly
- **WHEN** Track appears on a screen whose free space is positive but at most twice the approved shared maximum
- **THEN** the free space is distributed evenly between the top and bottom adaptive spacing regions and the central separator is zero

#### Scenario: Compact height collapses adaptive spacing
- **WHEN** the visible content does not fit because of screen height, content, or Dynamic Type
- **THEN** the adaptive spacing regions and the central separator shrink toward zero before any content clips, overlaps the tab bar, or becomes unreachable, and the ordered content scrolls

#### Scenario: Idle main action
- **WHEN** no Activity is prepared
- **THEN** the main-action region presents one `+ Choose an activity` control above the bottom adaptive spacing

#### Scenario: Ready main action
- **WHEN** an Activity is prepared
- **THEN** the main-action region presents a Start control in the same region the idle main action occupied

#### Scenario: Running main action
- **WHEN** a timer is running
- **THEN** the main-action region presents a Stop control with destructive styling in the same region and no offline hint

#### Scenario: Error region preserves geometry
- **WHEN** a recoverable non-field error is active and its wrapped text fits within the reserved height
- **THEN** the error appears in the reserved region immediately above the central separator without moving the timer, preparation row, Recents, or main-action regions

#### Scenario: Wrapped error text is never cut
- **WHEN** a recoverable non-field error wraps beyond the reserved height
- **THEN** the error text is shown in full, the region grows to fit it, the top adaptive spacing yields first and then the central separator, keeping the main action stationary, and scrolling begins only when both are exhausted

#### Scenario: No active error
- **WHEN** no recoverable non-field error is active
- **THEN** the error region preserves the same layout space without exposing an empty accessibility element

#### Scenario: Completion mark does not move timer content
- **WHEN** the completion mark appears or disappears during a timer-state transition
- **THEN** the timer numbers, timer status, and controls retain their positions within the ordered layout

### Requirement: Main action holds one position across states
Track SHALL present the state-specific main action in one main-action region whose frame is identical across the idle, ready, running, saving, saved, and error states. The layout SHALL render the main action in a fixed-height slot equal to the tallest of its state titles at the active Dynamic Type size. The below-button slot SHALL keep both branches (Recents and the running TagSelector) mounted and hide the inactive branch via opacity, so the slot keeps the taller branch's height in every state and the main action never moves on state switch. When a wrapped error grows the reserved error region, the top adaptive spacing SHALL yield first, then the central separator, keeping the main action stationary; scrolling SHALL begin only when both are exhausted.

#### Scenario: Preparing an Activity preserves the main-action frame
- **WHEN** an Activity is prepared while Track is idle
- **THEN** the preparation row appears in its reserved slot and the main-action frame does not change

#### Scenario: Starting timing preserves the main-action frame
- **WHEN** the user starts timing from ready
- **THEN** Recents hides while its occupied height is preserved and the main-action frame does not change

#### Scenario: Saving preserves the main-action frame
- **WHEN** the user stops and the entry is being saved
- **THEN** Recents reappears in the preserved region and the main-action frame does not change

#### Scenario: Error within the reservation preserves the main-action frame
- **WHEN** a recoverable non-field error fits within the reserved error height
- **THEN** the main-action frame does not change

#### Scenario: Wrapped error keeps the main action stationary
- **WHEN** a recoverable non-field error wraps beyond the reserved height and the top adaptive spacing and central separator can absorb the growth
- **THEN** the main-action frame does not change; only when both are exhausted does the content scroll

### Requirement: Recents present a capped wrapping chip flow
Track SHALL present its most-recently-used exact entry texts as a wrapping chip flow below the name field, ordered by each text's newest committed `started_at` first, and SHALL cap the flow at twelve chips. Identity SHALL be trimmed exact text (case-sensitive: `Gym` and `GYM` are distinct). There is no activity entity — chips represent entry texts, never activities. The chip area SHALL hug content and clamp at up to 4 visible rows bounded by the finite available height, scrolling internally beyond the visible rows; smaller sets SHALL render compactly with no reserved dead space, twelve chips SHALL NOT require horizontal scrolling, and the Track page itself SHALL NOT grow or scroll for Recents overflow except as an accessibility fallback when the core controls cannot fit. Both chip groups SHALL carry the same border clearance: 1 pt top/bottom scroll-content padding plus a matching +2 pt max cap above the row clamp. The viewport SHALL carry edge-aware hairline dividers shared with the tag selector (`ChipViewport` contract): a divider fades in above the viewport once chips scroll under it and below it while content remains, the bottom divider fades out at the content end, and both stay hidden when everything fits. A single tap on a chip SHALL fill the name plus that recent's full ordered categories without starting timing. Recents SHALL yield the below-button slot to the running TagSelector while a timer is running (inactive branch opacity-hidden with the slot keeping the taller branch's height). Returning to Track SHALL reload recents and categories — seeding the starter set first on a fresh install — so History edits and new categories are reflected immediately. Track SHALL also reload recents, the full name list, and the category map when a sync cycle exits (idle or error), so relay-pulled entries and categories converge without requiring a tab switch; a failed cycle MAY have applied partial merges before throwing and still triggers the reload.

#### Scenario: More Activities than the cap
- **WHEN** the user has more than twelve distinct exact texts
- **THEN** Recents presents the twelve with the newest committed entries and omits the rest

#### Scenario: Six or fewer Activities
- **WHEN** the user has between one and six distinct exact texts
- **THEN** Recents presents all of them newest-first within the chip area

#### Scenario: Seven to twelve Activities
- **WHEN** the user has between seven and twelve distinct exact texts
- **THEN** Recents presents all of them newest-first

#### Scenario: Chips wrap
- **WHEN** the Recents chips cannot fit on one row but fit within the available up-to-4-row clamp
- **THEN** the chips flow onto additional rows inside the same area and every chip remains visible and reachable without horizontal scrolling and without growing the Track page

#### Scenario: Overflow scrolls inside the chip area
- **WHEN** twelve chips overflow the available up-to-4-row clamp
- **THEN** the chip area scrolls internally on its own axis, while the Track page frame, the main-action frame, and the below-button slot frame do not move or grow

#### Scenario: Dividers follow the scroll edges
- **WHEN** the Recents chip area is scrolled down from the top
- **THEN** a hairline divider fades in above the viewport, marking content hidden above

#### Scenario: Bottom divider hides at the content end
- **WHEN** the Recents chip area is scrolled to its end
- **THEN** the bottom divider fades out

#### Scenario: No dividers when everything fits
- **WHEN** the recents fit in the viewport without scrolling
- **THEN** neither divider appears

#### Scenario: Tap a Recents chip
- **WHEN** the user taps a Recents chip
- **THEN** the name field fills with that exact text plus its newest entry's ordered categories, the ready numeric timer appears, and no timer starts and no entry is created

#### Scenario: Timing hides Recents
- **WHEN** a timer is running
- **THEN** Recents is not presented and its occupied height is preserved so the main action does not move

#### Scenario: Return refreshes Recents
- **WHEN** the user returns to Track from another tab or sheet
- **THEN** Recents and the category map reload (seeding first when needed), so entries edited in History are inherited and chip icons stay current

#### Scenario: Sync exit refreshes Track
- **WHEN** a background sync cycle finishes (idle) or fails after partial merges (error) while Track is mounted
- **THEN** Track reloads recents, the full name list, and the category map once, so first-sync data appears without leaving the tab and a transient failure never blanks the last good snapshot

#### Scenario: Fresh reinstall shows categories on first paint
- **WHEN** the user signs in on a reinstall with an empty account file and the shell mounts after seeding
- **THEN** the first Track paint already carries the starter categories and the name picker suggests seeded names, with recents filling in as the first sync lands

### Requirement: Recents highlight the prepared text
When an exact text is prepared, its Recents chip SHALL indicate the selected state with a filled accent presentation — accent background, on-accent text, and accent border, keeping the Category icon — a visible affordance that does not rely on color alone, and assistive technologies SHALL be told that the chip is selected. No chip SHALL appear selected while Track is idle.

#### Scenario: Chip shows selection affordance
- **WHEN** the user prepares an exact text that is present in Recents
- **THEN** that text's chip switches to the filled accent presentation, distinct from the unselected chips, without losing its Category icon and without adding a checkmark

#### Scenario: Selection moves
- **WHEN** the user prepares a different text
- **THEN** the selection affordance moves to the newly prepared text's chip and the previous chip returns to the unselected presentation

#### Scenario: No selection while idle
- **WHEN** no text is prepared
- **THEN** no Recents chip displays the selection affordance

#### Scenario: VoiceOver announces the selected chip
- **WHEN** VoiceOver focuses the prepared text's Recents chip
- **THEN** it announces the text and that the chip is selected

#### Scenario: Chips keep full tap targets
- **WHEN** a Recents chip renders with an icon, without an icon, or in the selected presentation
- **THEN** its interactive area remains at least 44×44 points

### Requirement: Recents explain their empty state
When no committed entries exist, Recents SHALL present dedicated localized copy explaining that names the user tracks will appear there.

#### Scenario: Empty catalog
- **WHEN** Track is idle and no committed entries exist
- **THEN** Recents shows the dedicated localized hint that tracked names will appear there

#### Scenario: First Activity created
- **WHEN** the user saves the first entry and returns to Track
- **THEN** the empty hint is replaced by Recents chips containing that exact text

### Requirement: Stop saves with stable feedback
Stopping a running timer SHALL save the completed entry locally, communicate success without a blocking loader, and retain the entered text in the ready state for an optional later restart. While the saved confirmation is showing, the Start button SHALL render disabled (dimmed, non-interactive) since starting is not possible until the state settles back to ready; it SHALL re-enable with the return to ready. Editing the name while the saved confirmation is showing SHALL return to ready for the new text at once, ending the confirmation early. When the persisted running draft is gone but Track still holds a `.running` state (the timer was stopped from the compact timer on another destination), Track SHALL reconcile on next load: stop the elapsed ticker, re-enable the idle timer, reset elapsed to zero, and return to `.ready` for the same text — or `.idle` when nothing was entered — instead of counting elapsed time forever.

#### Scenario: Successful stop
- **WHEN** the user activates Stop on a running timer
- **THEN** the app persists the completed entry, clears running state, emits a success haptic, briefly confirms the saved duration, and returns to the ready numeric timer for the same text

#### Scenario: Save failure
- **WHEN** the local store cannot save the completed entry
- **THEN** the app preserves recoverable running state and presents a localized non-field error without silently losing elapsed time

#### Scenario: External stop reconciles Track
- **WHEN** Track holds a running state whose persisted draft no longer exists (stopped from the compact timer elsewhere)
- **THEN** Track leaves the running state on next load: the ticker stops, elapsed resets to zero, and the screen shows the ready timer for the same text (or idle when empty)

#### Scenario: Stop after the activity was deleted elsewhere
- **WHEN** the user stops a timer (no deletable parent exists; entries and drafts cannot be deleted out from under a run)
- **THEN** the entry always saves normally; this scenario is retained as a no-op for archive continuity

#### Scenario: Start is disabled during the saved confirmation
- **WHEN** the saved confirmation is showing after a stop
- **THEN** the Start button renders dimmed and ignores taps; it re-enables when the state settles back to ready

#### Scenario: Edit during the saved confirmation returns to ready
- **WHEN** the user edits the name while the saved confirmation is showing
- **THEN** the screen returns to ready for the new text at once, ending the confirmation early instead of waiting out the window

### Requirement: Timer states remain visually and physically stable
The idle, ready, running, saving, saved, and error states SHALL preserve the numeric timer's position and primary control geometry, support light and dark appearance, respect Reduce Motion, and expose accessible state. Transient saved-state feedback displayed above the numeric timer SHALL NOT change the timer's vertical position.

#### Scenario: State transition
- **WHEN** Track changes between ready, running, and saved states
- **THEN** content transitions without moving the numeric timer or primary action to a different interaction region

#### Scenario: Saved confirmation appears
- **WHEN** a successful stop displays the saved-state confirmation mark above the numeric timer
- **THEN** the mark appears without changing the numeric timer's vertical position

#### Scenario: Reduce Motion enabled
- **WHEN** Reduce Motion is enabled
- **THEN** state changes use restrained fades or immediate updates instead of rotational or spring-based animation

#### Scenario: VoiceOver reads numeric timer
- **WHEN** VoiceOver focuses the numeric timer
- **THEN** it announces the selected Activity, timer state, elapsed duration, and the available primary action

### Requirement: Plain-text name capture
Track SHALL capture the entry name as plain trimmed text with no catalog, no search sheet, and no quick-create. The idle screen SHALL show a plain-text name field plus the 12 exact-match recents chips. Start SHALL be enabled only when the trimmed text is non-empty. Typing a name that exactly matches a recent SHALL NOT start anything until Start is activated.

#### Scenario: Type a new name
- **WHEN** the user types a trimmed non-empty name with no exact recent match
- **THEN** Start becomes enabled and no catalog record is created

#### Scenario: Empty text cannot start
- **WHEN** the name field holds only whitespace
- **THEN** Start stays disabled with no error text

#### Scenario: Exact text identity
- **WHEN** the trimmed text differs from an existing recent only by letter case (e.g. `Gym` vs `GYM`)
- **THEN** the two are treated as different names with separate recents and separate inherited categories

### Requirement: Running timer hosts the category TagSelector
While a timer is running, Track SHALL show the shared ordered `TagSelector` (zero allowed, order preserved) below the readout, ending with the inline-creation chip defined by the category-management capability. Category options remain the existing catalog (select from existing); only the trailing creation chip is new. The chip region SHALL hug content and clamp at up to 4 visible rows bounded by the finite available height, scrolling internally beyond the visible rows; the timer/name/Stop frames SHALL be preserved with no tab-bar overlap, and entire-page scroll SHALL engage only as an accessibility fallback. The name SHALL be locked after Start; tags SHALL stay live until Stop. The locked name card SHALL align its text to the leading edge, matching the idle/ready name-row grammar (icon + text pushed leading, never centered). Toggles SHALL rewrite only the running draft (persisted `timer_state` snapshot) and SHALL never touch history. Notes edits SHALL rewrite only the running draft notes snapshot the same way. Stop SHALL save the entry with the final ordered categories, the final draft notes, and derived duration, plus a single outbox row. The running selector SHALL render selection ordinals exactly as defined by the category-management capability (single selection shows a checkmark, multiple selections show 1-based ordinals with fade-animated renumbering) without moving the main action above it.

#### Scenario: Toggle tags mid-run
- **WHEN** the user toggles a category while the timer runs
- **THEN** the draft selection updates, the persisted draft snapshot updates, and no entry or history row changes

#### Scenario: Selection order is visible mid-run
- **WHEN** the user selects a second category while the timer runs
- **THEN** the selected chips show their 1-based ordinals with a fade and the Start/Stop action above keeps its exact frame

#### Scenario: Name locked while running
- **WHEN** the timer is running
- **THEN** the name field is non-editable until Stop

#### Scenario: Locked name aligns leading
- **WHEN** the timer is running and the locked name card shows the draft text
- **THEN** the text renders leading-aligned inside the card, matching the idle/ready name row, regardless of live elapsed-time ticks

#### Scenario: Category-less run allowed
- **WHEN** the user deselects every category mid-run
- **THEN** the run stays valid and Stop saves a category-less entry

#### Scenario: Stop saves final tags
- **WHEN** the user activates Stop
- **THEN** the entry is created with the trimmed locked text, the final ordered categories, the final draft notes, and derived duration, plus a single outbox row

#### Scenario: Create a category mid-run
- **WHEN** the user activates the creation chip while the timer runs, saves a unique valid name with an icon
- **THEN** the editor pops back to Track and the running draft gains the new category in tap order with the draft snapshot updated

#### Scenario: Duplicate name mid-run keeps the editor open
- **WHEN** the user attempts to save a duplicate category name from the running-tag row
- **THEN** no category is created, the editor stays open with the draft intact and a localized duplicate-name error, and the running timer and its draft are unaffected

### Requirement: Recents chips show the first inherited Category icon
A Recents chip SHALL display the icon of the first category of that exact text's newest committed entry (first by stored position). A text whose newest entry has no categories SHALL render its chip without an icon. Recents chips SHALL NOT display category names.

#### Scenario: Recent with one Category
- **WHEN** a Recents chip's newest entry has exactly one category
- **THEN** the chip displays that category's icon

#### Scenario: Recent with multiple Categories
- **WHEN** a Recents chip's newest entry has two or more categories
- **THEN** the chip displays only the icon of the category that is first by stored position

#### Scenario: Recent without Categories
- **WHEN** a Recents chip's newest entry has no categories
- **THEN** the chip renders with the exact text and no icon, keeping the full tap target

#### Scenario: Icon cannot render on this OS
- **WHEN** the first category's icon is unavailable on the running iOS version
- **THEN** the chip falls back to the tag glyph used elsewhere for unavailable category icons

### Requirement: Categories are per-entry and never retroactive
The app SHALL treat categories as optional, zero-or-more metadata owned by each entry at creation. Editing categories on one entry (or on the running draft) SHALL NOT change any other entry. There SHALL be no query-time category resolution through any other record.

#### Scenario: Create without categories
- **WHEN** the user starts a timer for a name with no inherited categories
- **THEN** the run is valid with no categories assigned

#### Scenario: Retag affects one entry only
- **WHEN** the user changes an entry's categories
- **THEN** no other entry with the same text changes

### Requirement: Track name clear shows only when focused and non-empty, Apple-standard look
The Track name field's trailing clear (`×`) button SHALL be visible only when the field is focused AND holds non-empty text (idle/ready/saved states; never while running — the name is locked then). One tap SHALL clear the draft and return Track to idle. The button SHALL use the Apple-standard trailing look: a small (16 pt) dim `xmark.circle.fill` in `Theme.textSecondary` at reduced opacity tucked at the field's trailing edge, with the 44 pt accessible tap target preserved.

#### Scenario: Clear hidden when unfocused, even with text
- **WHEN** the Track name field holds text but is not focused
- **THEN** no clear button is shown

#### Scenario: Clear hidden when empty, even when focused
- **WHEN** the Track name field is focused but empty
- **THEN** no clear button is shown

#### Scenario: Clear visible when focused with text
- **WHEN** the Track name field is focused and holds text while idle, ready, or saved
- **THEN** a small dim trailing `×` is visible, and one tap empties the field and returns Track to idle

#### Scenario: No clear button while running
- **WHEN** a timer is running
- **THEN** the name is locked and no clear button is shown

### Requirement: Track name field has autocomplete suggestions over recents
(Clear-button behavior for this field — focused-AND-non-empty visibility, Apple-standard look — is owned by the "Track name clear shows only when focused and non-empty" requirement.) The Track name field SHALL open the shared dedicated name-picker page (`name-picker` capability) instead of rendering a floating overlay. Tapping the idle/ready/saved name row SHALL push the picker prefilled with the current draft. Picking a suggestion or completing with Done SHALL follow the picker completion contract: fill the exact text plus that recent's full ordered categories without starting timing and without creating anything. The Start/Stop action SHALL never be covered by suggestions by construction (typing and starting live on different screens), and the main-action frame requirements are unchanged.

#### Scenario: Tapping the name row opens the picker
- **WHEN** the user taps the Track name row while idle, ready, or saved
- **THEN** the shared picker pushes prefilled with the current draft text and the Start/Stop action stays uncovered behind it

#### Scenario: Typing shows prefix suggestions without moving Start
- **WHEN** the user types a non-empty prefix matching one or more committed names on the picker page
- **THEN** those names are suggested newest-first (exact match included) and the Track Start/Stop action does not move and is never covered

#### Scenario: Picking a suggestion prepares without starting
- **WHEN** the user picks a suggestion or completes with Done on the picker page
- **THEN** the field fills with that exact text plus its ordered categories, the picker pops back to Track showing the ready timer, and no timer starts and no entry is created

### Requirement: Running Track offers a recording-only notes button
While a timer is running, the locked name row SHALL be paired with a trailing notes button that opens the shared Notes editor page bound to the running draft. The button SHALL be visible only while recording (running/error states with a persisted draft) and SHALL sit OUTSIDE the locked-name row as a standalone 44 pt `note.text` control at the screen's trailing padding beside the locked-name `FieldCard` — without changing the row height or moving the main action. The button's tint SHALL signal draft-notes presence (accent when non-empty, secondary when empty); no notes preview SHALL appear on Track. Saving on the editor page SHALL rewrite only the running draft notes snapshot (persisted `timer_state`); cancelling SHALL leave the draft untouched. Notes edits SHALL never touch history until Stop.

#### Scenario: Notes button visible only while recording
- **WHEN** a timer is running
- **THEN** the locked name row shows the trailing notes button at full tap target

#### Scenario: Notes button hidden when not recording
- **WHEN** Track is idle, ready, or saved (no running draft)
- **THEN** no notes button is shown

#### Scenario: Opening notes mid-run
- **WHEN** the user taps the notes button while running
- **THEN** the Notes editor page pushes prefilled with the current draft notes

#### Scenario: Saving running notes updates the draft only
- **WHEN** the user saves on the editor page while running
- **THEN** the running draft notes update, the persisted snapshot updates, and no entry or history row changes

#### Scenario: Cancelling running notes keeps the draft
- **WHEN** the user cancels on the editor page while running
- **THEN** the page pops and the running draft notes are unchanged

### Requirement: First Track paint carries the full local snapshot in one commit

Track's first data — recents, the full name list, the category map, and the persisted running draft — SHALL be loaded through one shared snapshot query set whose results publish in a single render commit (gathered into locals, assigned synchronously), so the empty state is never visibly replaced by loaded content across progressive paints. The launch gate preloads the same snapshot before mounting; `TrackViewModel.load()` consumes the same loader and adopts a preloaded snapshot when one is handed to the shell, re-querying only when none was provided.

#### Scenario: Cold boot shows chips on first paint
- **WHEN** the user cold-boots with committed entries on the device
- **THEN** the first visible Track paint already shows Recents chips with icons — no empty hint, no progressive fill across multiple renders

#### Scenario: Cold boot with a persisted run restores it on first paint
- **WHEN** the user cold-boots with a running timer draft persisted in the local store
- **THEN** the first visible Track paint already shows the running state (locked name, tag selector, elapsed readout) — the screen never shows idle first

#### Scenario: Preload failure falls back to load-on-appear
- **WHEN** the gate preload throws (unbound or unreadable store)
- **THEN** the shell still mounts on schedule and `TrackViewModel.load()` runs on appear, surfacing the existing recoverable error banner instead of blanking — a failed preload never strands the launch

### Requirement: Reloads publish once and skip unchanged snapshots

Every Track reload (tab return, Profile exit, sync-cycle exit) SHALL resolve through the same single-commit snapshot path, and SHALL skip publishing when the resolved snapshot equals the current one, so no-op reloads (including sync cycles that merge nothing new) render literally nothing and relay-pulled changes fill in place without blanking.

#### Scenario: No-op sync exit renders nothing
- **WHEN** a background sync cycle finishes having merged no new entries, categories, or draft changes
- **THEN** Track publishes nothing and the screen holds its pixels — no flash, no shift, no re-render artifacts

#### Scenario: Relay data fills in place
- **WHEN** a sync cycle merges newer relay entries or categories
- **THEN** Track reloads once through the snapshot path and the new rows appear in their reserved geometry without blanking the last good snapshot
