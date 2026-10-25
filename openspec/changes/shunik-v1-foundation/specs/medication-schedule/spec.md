## Purpose

Medication is a program that emits doses, not a single event: a course holds the plan while child intakes record what actually happened, so edits never rewrite history and adherence is always computable.

## ADDED Requirements

### Requirement: Course holds the plan, intakes record the truth

A medication course SHALL own its plan (drug name, dose amount + unit + route, schedule, start, end/duration/open-ended, status active/paused/done/stopped, instructions). Each due or logged giving SHALL be a child `intake` row Snapshotting the dose at due time. Past intakes SHALL be immutable by edits to the course.

#### Scenario: Mid-course dose change preserves history

- **WHEN** the dose changes on day 4 of a 10-day course
- **THEN** intakes before the change keep the old dose and future pending intakes carry the new dose

### Requirement: Intake states with distinct missed and skipped

An intake SHALL be exactly one of pending, taken, missed, or skipped. Skipped (deliberate, e.g. vet-ordered) SHALL be recorded distinctly from missed and SHALL be excluded from the adherence rate denominator. PRN courses (no schedule, log-only) SHALL have no adherence rate, only a log count.

#### Scenario: Skipped dose does not punish adherence

- **WHEN** a course has 12 taken, 1 missed, 1 skipped
- **THEN** adherence reports 12/13 with the skipped dose shown separately

### Requirement: Auto-miss on supersede, manual anytime

A still-pending intake SHALL flip to missed when the next intake of the same course becomes due. The owner MAY mark any pending intake taken/missed/skipped at any time before that.

#### Scenario: Forgotten morning dose collapses honestly

- **WHEN** the 08:00 intake is still pending at the next due time
- **THEN** it becomes missed and the new intake becomes pending

### Requirement: Stopping a course deletes only future pendings

Stopping or completing a course SHALL delete its future pending intakes (tombstoned, synced) and SHALL leave taken/missed/skipped intakes untouched.

#### Scenario: Early stop keeps evidence

- **WHEN** a 10-day course stops on day 6
- **THEN** days 1–6 intakes remain and days 7–10 pendings disappear on all synced devices

### Requirement: Schedules are wall-clock local

Course schedules SHALL be interpreted in device-local wall-clock time (20:00 fires at 20:00 wherever the device is). Daily × N times, specific weekdays, N days / until-date / open-ended, and single-amount-per-course SHALL be supported in v1; interval-hours shifting, cycles, tapering, weight-linked dosing, and refills SHALL NOT.

#### Scenario: Travel keeps dose time

- **WHEN** the household travels across timezones with an active twice-daily course
- **THEN** doses continue at local 08:00/20:00 on each device
