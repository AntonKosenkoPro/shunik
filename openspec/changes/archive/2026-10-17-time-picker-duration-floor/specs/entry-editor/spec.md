## ADDED Requirements

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

## MODIFIED Requirements

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
