# Manual Entry Specification

## Purpose

Lets users log past time without the live timer: pick an activity, set a start and end, and save a committed manual entry — the recovery path for forgotten sessions.

## Requirements


### Requirement: Starts and Ends use inline expanding pickers

Tapping a date pill SHALL expand an inline graphical month picker below the pills; tapping a time pill SHALL expand an inline hour/minute/period wheel picker below the pills. Only one picker SHALL be open at a time — opening one collapses the other. The active pill SHALL show a selected tint. Pickers SHALL use the device locale and calendar. Tapping a visible day in the expanded month picker SHALL update the draft date for that Start/End. Month steppers and swipe paging SHALL change the visible month and the browsed month SHALL persist (no snap-back to the selection month) until the user picks a day or collapses the picker. Expanding a picker SHALL NOT flash an empty card: the month grid SHALL appear together with the expansion.

#### Scenario: Expand the date picker

- **WHEN** the user taps the Starts date pill
- **THEN** a month-grid picker expands below the pills showing the currently selected date

#### Scenario: One picker at a time

- **WHEN** the date picker is open and the user taps a time pill
- **THEN** the date picker collapses and the wheel picker expands

#### Scenario: Select a day in the month picker

- **WHEN** the month picker is expanded and the user taps a visible day
- **THEN** the draft date updates to that day, the date pill reflects the new date, and the picker stays expanded

#### Scenario: Browse months without snap-back

- **WHEN** the month picker is expanded and the user taps a month stepper (or swipes the grid)
- **THEN** the visible month pages and stays on the browsed month; the selection and pills are unchanged until a day is tapped

### Requirement: Add is a validity gate
The Add action SHALL be enabled only when the trimmed name is non-empty AND the end is strictly after the start. Otherwise it SHALL be disabled. No error text or alert SHALL be shown for the disabled state.

#### Scenario: No activity chosen
- **WHEN** the sheet is open and the trimmed name is empty (no text has been entered)
- **THEN** Add is disabled

#### Scenario: End not after start
- **WHEN** the chosen end is equal to or before the start
- **THEN** Add is disabled

#### Scenario: Valid form
- **WHEN** a non-empty name is entered and the end is after the start
- **THEN** Add is enabled
### Requirement: Sheet opens with sensible defaults
The sheet SHALL open with Name empty (or the exact recent's text when opened with a text context), Categories empty (or that text's inherited ordered set when a text context is supplied), Notes empty, Start set to the current time floored to 5 minutes and End set to Start plus one hour.

#### Scenario: Default times
- **WHEN** the sheet opens from History at 2:37 PM
- **THEN** Start shows 2:35 PM and End shows 3:35 PM on the same day with empty name, categories, and notes

#### Scenario: Pre-filled activity
- **WHEN** the sheet opens from any entry point (History or otherwise)
- **THEN** no activity is pre-filled: the Name row is empty and categories and notes start empty, with only the time defaults applied
### Requirement: Moving Start preserves duration Calendar-style

When the user moves Start to a time at or after the current End, the End SHALL auto-advance to keep the previous duration. Moving Start earlier SHALL NOT move End. Moving End SHALL never move Start.

#### Scenario: Start pushed past End

- **WHEN** the form holds Start 2:35 PM / End 3:35 PM (1h) and the user moves Start to 4:00 PM
- **THEN** End auto-advances to 5:00 PM

#### Scenario: Start moved earlier

- **WHEN** the form holds Start 2:35 PM / End 3:35 PM and the user moves Start to 1:00 PM
- **THEN** End stays at 3:35 PM

### Requirement: Saving creates a committed manual entry
Activating Add SHALL persist a committed entry via `LocalStore.createEntry` with `source:"manual"` and null `source_ref` (client-generated UUID v7 id, trimmed `activity_text`, ordered `category_ids`, `notes`, `duration_seconds` derived from end minus start), enqueueing the sync outbox row in the same transaction. The sheet SHALL dismiss and the underlying list SHALL refresh to include the entry in its day group. Overlapping entries and future end-times SHALL be allowed.

#### Scenario: Successful save
- **WHEN** the user activates Add on a valid form
- **THEN** a committed manual entry exists with the entered text, categories, notes, start, end, and derived duration, and the sheet dismisses

#### Scenario: Overlap is allowed
- **WHEN** the chosen interval overlaps an existing entry or a running timer session
- **THEN** Add stays enabled and saving succeeds
### Requirement: Log Time sheet captures name, start, end, categories, and notes
The app SHALL provide the Log Time sheet as the CREATE mode of the unified entry form (see entry-editor capability): cards in exactly this order — Name (plain-text entry-text field, never an activity picker), Start (date pill + time pill with inline single-open picker), End (date pill + time pill with inline single-open picker), Categories (ordered TagSelector), Notes (plain-text field, empty by default). An empty name SHALL mean no text is chosen and no entry text is pre-filled. CREATE mode SHALL keep the "Log time" title (localized) with an X dismiss action (`LogTimeDismissButton`) and a ✓ confirm action (`LogTimeAddButton`, localized VoiceOver labels, system-default toolbar tint) in the navigation bar, presented as a sheet from the existing entry points with unchanged defaults, gates, pickers, and save behavior. EDIT and LOCKED modes are defined by the entry-editor capability; no title, location, all-day, repeat, or alert fields SHALL be present in any mode. The all-native-gestures-must-work rule (entry-editor capability) SHALL apply to CREATE mode as well as EDIT/LOCKED.

#### Scenario: Sheet contents
- **WHEN** the Log Time sheet is open
- **THEN** it shows an X dismiss button and a ✓ confirm button (with the Log time title and the unchanged Name/Start/End/Categories/Notes cards) — and no Cancel/Add text buttons

#### Scenario: Cross discards the draft
- **WHEN** the user activates the X button
- **THEN** the sheet dismisses and no entry is created

#### Scenario: Create mode keeps its presentation
- **WHEN** the sheet opens from History for logging new time
- **THEN** it presents as a sheet (not a full-screen cover) with the "Log time" title and Cancel/Add actions
