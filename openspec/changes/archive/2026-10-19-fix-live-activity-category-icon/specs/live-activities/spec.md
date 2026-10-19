## MODIFIED Requirements

### Requirement: Live Activity follows the running timer
The system SHALL start a Live Activity when a timer starts and end it when the timer stops. The activity SHALL be requested only while the app is in the foreground and only when Live Activities are enabled; at most one activity SHALL exist at a time (the `timer_state` singleton). Starting SHALL NOT create an entry and stopping via the activity SHALL save the entry exactly as an in-app Stop (same `source='manual'` path, same outbox row). The activity content SHALL refresh the visible category chips when the running draft is retagged mid-run (same text keeps the singleton; chips update in place); the live icon SHALL follow the draft's first ordered category (timer fallback when the draft has no categories) without restart or time reset.

#### Scenario: Start shows the activity
- **WHEN** the user starts a timer in the app while Live Activities are enabled
- **THEN** a Live Activity appears showing the exact entry text, the first-category icon (or timer fallback), and the live elapsed time

#### Scenario: Stop from the app ends the activity
- **WHEN** the user stops the timer in the app
- **THEN** the entry is saved and the Live Activity ends with the Saved card (see dismissal requirement)

#### Scenario: Second start replaces, never duplicates
- **WHEN** a timer starts while a Live Activity is already active
- **THEN** no second activity is created (the singleton is reused or the stale one is ended first)

#### Scenario: Activities disabled
- **WHEN** Live Activities are disabled for the app or device
- **THEN** starting a timer succeeds with no activity and no error shown

#### Scenario: Restore re-mirrors the run
- **WHEN** the app launches or Track loads with a persisted running draft and no fresh Start (cold start, upgrade install, relaunch)
- **THEN** the activity is requested for the draft; an already-live activity for the same text is reused untouched

#### Scenario: Mid-run retag refreshes category chips
- **WHEN** the user changes the running draft's categories while the timer runs
- **THEN** the Live Activity keeps its singleton identity (same text) and its visible category chips update to the draft's current ordered set; the live icon on all running faces (banner, compact, minimal) reflects the draft's first ordered category (timer fallback when empty); identical chips skip the update

#### Scenario: Mid-run reorder moves the live icon without restart
- **WHEN** the user reorders the running draft's categories while the timer runs
- **THEN** the live icon follows the new first ordered category with `startedAt` unchanged (no restart, no elapsed reset)

#### Scenario: Mid-run removal falls back to the timer icon
- **WHEN** the user removes all categories from the running draft while the timer runs
- **THEN** the live icon falls back to `timer` with `startedAt` unchanged (no restart, no elapsed reset)
