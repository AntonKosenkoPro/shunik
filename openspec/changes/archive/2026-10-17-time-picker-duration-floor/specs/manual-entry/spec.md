## MODIFIED Requirements

### Requirement: Starts and Ends use inline expanding pickers

Tapping a date pill SHALL expand an inline graphical month picker below the pills; tapping a time pill SHALL expand an inline hour/minute/period wheel picker below the pills. Only one picker SHALL be open at a time — opening one collapses the other. The active pill SHALL show a selected tint. Pickers SHALL use the device locale and calendar. Tapping a visible day in the expanded month picker SHALL update the draft date for that Start/End. Month steppers and swipe paging SHALL change the visible month and the browsed month SHALL persist (no snap-back to the selection month) until the user picks a day or collapses the picker. Expanding a picker SHALL NOT flash an empty card: the month grid SHALL appear together with the expansion. The Start pickers SHALL be unbounded. The End date picker SHALL NOT offer any day before the Start's calendar day. The End time picker SHALL NOT offer times before Start plus one minute when the End day equals the Start day (Start 1:00 PM → earliest End 1:01 PM); on later End days the time wheel SHALL be unbounded.

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

#### Scenario: End day before Start day is unpickable

- **WHEN** Start is on Jan 5 and the user opens the End date picker
- **THEN** Jan 4 and earlier days cannot be chosen while Jan 5 and later days can

#### Scenario: Same-day End time floor

- **WHEN** Start is 1:00 PM, End is the same day, and the user opens the End time picker
- **THEN** times before 1:01 PM cannot be chosen

#### Scenario: Later-day End time is unbounded

- **WHEN** the End day is after the Start day and the user opens the End time picker
- **THEN** any time of day can be chosen

### Requirement: Add is a validity gate
The Add action SHALL be enabled only when the trimmed name is non-empty AND the end is at least one minute after the start. Otherwise it SHALL be disabled. No error text or alert SHALL be shown for the disabled state.

#### Scenario: No activity chosen
- **WHEN** the sheet is open and the trimmed name is empty (no text has been entered)
- **THEN** Add is disabled

#### Scenario: End not after start
- **WHEN** the chosen end is equal to or before the start
- **THEN** Add is disabled

#### Scenario: End under one minute
- **WHEN** the chosen end is after the start but less than one minute later (e.g. 30 seconds)
- **THEN** Add is disabled

#### Scenario: Valid form
- **WHEN** a non-empty name is entered and the end is at least one minute after the start
- **THEN** Add is enabled

### Requirement: Moving Start preserves duration Calendar-style

When the user moves Start, the End SHALL shift by the same delta (`end += newStart − oldStart`) so the duration stays constant — whether Start moves earlier or later, and whether the move comes from the date or the time picker. Moving End SHALL never move Start.

#### Scenario: Start pushed past End

- **WHEN** the form holds Start 2:35 PM / End 3:35 PM (1h) and the user moves Start to 4:00 PM
- **THEN** End shifts by the same delta to 5:35 PM (duration stays 1h)

#### Scenario: Start moved earlier

- **WHEN** the form holds Start 2:35 PM / End 3:35 PM (1h) and the user moves Start to 1:00 PM
- **THEN** End shifts by the same delta to 2:00 PM (duration stays 1h)
