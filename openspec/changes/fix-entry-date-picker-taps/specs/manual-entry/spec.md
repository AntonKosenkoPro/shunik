## MODIFIED Requirements

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
