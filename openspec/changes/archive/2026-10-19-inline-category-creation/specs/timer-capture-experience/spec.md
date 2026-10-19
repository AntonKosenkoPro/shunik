## REMOVED Requirements

### Requirement: Section headers carry a separator above their chips
**Reason**: Superseded by the edge-aware viewport dividers: header/chip grouping on Track is now carried by the scroll-edge hairlines (shared `ChipViewport` contract), making the constant caption dividers visually excessive.
**Migration**: No user or data action — the captions remain; only the constant `Divider` under each Track section caption is removed. Grouping semantics move to the viewport edge dividers documented in `Design/SCREENS/TimeTracking.md`.

## MODIFIED Requirements

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

### Requirement: Running timer hosts the category TagSelector
While a timer is running, Track SHALL show the shared ordered `TagSelector` (zero allowed, order preserved) below the readout, ending with the inline-creation chip defined by the category-management capability. Category options remain the existing catalog (select from existing); only the trailing creation chip is new. The chip region SHALL hug content and clamp at up to 4 visible rows bounded by the finite available height, scrolling internally beyond the visible rows; the timer/name/Stop frames SHALL be preserved with no tab-bar overlap, and entire-page scroll SHALL engage only as an accessibility fallback. The name SHALL be locked after Start; tags SHALL stay live until Stop. The locked name card SHALL align its text to the leading edge, matching the idle/ready name-row grammar (icon + text pushed leading, never centered). Toggles SHALL rewrite only the running draft (persisted `timer_state` snapshot) and SHALL never touch history. Notes edits SHALL rewrite only the running draft notes snapshot the same way. Activating the creation chip SHALL push the full category editor onto the Track stack (never a sheet); saving SHALL pop back, reload the tag-row options, and append the new category to the running draft in tap order. Stop SHALL save the entry with the final ordered categories, the final draft notes, and derived duration, plus a single outbox row. The running selector SHALL render selection ordinals exactly as defined by the category-management capability (single selection shows a checkmark, multiple selections show 1-based ordinals with fade-animated renumbering) without moving the main action above it.

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
