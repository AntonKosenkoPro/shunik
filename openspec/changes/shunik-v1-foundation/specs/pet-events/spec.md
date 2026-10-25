## Purpose

All pet care activity is one uniform timeline built on a shared event base with kind-specific details, so reminders, sync, and history query one shape while each kind validates and evolves independently.

## ADDED Requirements

### Requirement: Event base with single immutable pet link

Every event SHALL be a row in `event_base` carrying exactly one `pet_id` that is NOT NULL, set at creation, and never changed. There SHALL be no event shared across pets: the same real-world happening for two pets is two events (a multi-create shortcut is explicitly v2).

#### Scenario: Filtering by pet needs no join

- **WHEN** the timeline filters to one pet
- **THEN** only that pet's events appear via a plain `pet_id` predicate

#### Scenario: Rare shared happening is logged twice

- **WHEN** both dogs are vaccinated at one visit
- **THEN** the owner logs two events (one per pet) and each pet's history stays independently correct afterwards

### Requirement: Kind details hang off the base

Each base row SHALL have exactly one kind detail (vaccination, grooming, weight point, medication course). Detail schemas SHALL evolve per kind without touching the base or other kinds. Clients SHALL ignore unknown kinds' details but still list their base rows.

#### Scenario: New kind does not disturb old data

- **WHEN** a future kind is added
- **THEN** existing timelines, reminders, and sync behavior are unchanged and old clients still list the new rows' titles

### Requirement: Vaccination and grooming are points with a next due

Vaccination and grooming details SHALL record what happened plus an optional `next_due_at`. The `next_due_at` SHALL feed the reminder engine; clearing or passing it without renewal leaves the event as history with no pending.

#### Scenario: Next vaccination reminds once

- **WHEN** a vaccination with a next due date syncs to a device
- **THEN** the reminder engine schedules it and the timeline shows both the past event and the upcoming due

### Requirement: Weight is a series, never a plan

Weight details SHALL be numeric observations (`measured_at`, canonical grams — see `unit-system`) with no schedule, no reminders, and no adherence. History SHALL present them newest-first plus a trend line.

#### Scenario: Weight never notifies

- **WHEN** a weight point is logged
- **THEN** no notification is scheduled and the point appears in history and the trend

### Requirement: Single-pet feel until the second pet

Pet-scope controls (picker, "All" filter, per-row pet prefixes) SHALL appear only when `pets.count > 1`. With one pet, event titles and reminder text SHALL NOT carry a pet prefix.

#### Scenario: First pet feels like the only pet

- **WHEN** the household has one pet
- **THEN** the timeline shows bare titles ("Nobivac due") with no scope chrome

#### Scenario: Second pet morphs the IA

- **WHEN** a second pet is added
- **THEN** scope controls appear and reminder/timeline rows prefix the pet name
