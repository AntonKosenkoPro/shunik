## Purpose

One narrow scheduler owns all due-date notifications across vaccinations, intakes, and grooming, so kinds declare what is due and the engine alone decides how the device buzzes.

## ADDED Requirements

### Requirement: One queue over due, pet, title, link

The engine SHALL schedule from a single derived stream of `(due_at, pet_id, title, deep_link)` fed by vaccination/grooming `next_due_at` values and pending intakes. Kinds SHALL NOT schedule notifications directly.

#### Scenario: New next-due appears without app logic per kind

- **WHEN** any kind produces a new due
- **THEN** it appears in the engine queue with no kind-specific scheduling code

### Requirement: Rolling window within the platform cap

The engine SHALL keep only the nearest window (about 14 days) scheduled and SHALL re-top-up on launch, intake marking, course/detail edits, incoming sync with new dues, and timezone change. It SHALL never exceed the platform pending-request cap.

#### Scenario: Long course does not overflow the cap

- **WHEN** two twice-daily 30-day courses are active
- **THEN** only the nearest window is scheduled and marking an intake advances the window

### Requirement: Deterministic IDs shared across devices

Each scheduled notification SHALL carry a deterministic identifier derived from its source record (`intake_<id>`, `due_<event_id>`), so any household device can cancel what another device resolved.

#### Scenario: B's phone clears what A completed

- **WHEN** A's mark-taken syncs to B
- **THEN** B's engine cancels the matching pending notification by identifier

### Requirement: Snooze is cut for v1

Pending dues SHALL sit red/overdue until marked; v1 SHALL provide no snooze affordance in-app or in notification actions. (Revisit as a single-length, capped actions-only compromise only if proposal review overturns this.)

#### Scenario: Hands-full moment waits

- **WHEN** a dose becomes due while the owner cannot act
- **THEN** it remains pending and overdue until taken, missed, or skipped — nothing auto-dismisses it

### Requirement: Per-device mute, household-loud default

Notifications SHALL fire on every member device holding the data unless that device enabled its local-only mute. The mute SHALL never sync.

#### Scenario: Night-shift phone stays quiet

- **WHEN** one device mutes reminders
- **THEN** it stays silent while the other device continues to notify, with no effect on shared truth
