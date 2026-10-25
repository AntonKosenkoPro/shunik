## Purpose

Every owner sees weights and doses in their own system while the household shares one exact truth, so a metric phone and an imperial phone never disagree about a pet.

## ADDED Requirements

### Requirement: Canonical integer storage, never the display string

Weight points SHALL store integer grams; the display string or input unit SHALL never be persisted as truth. Sync SHALL carry only the canonical value.

#### Scenario: Two systems, one truth

- **WHEN** A logs 4.3 kg and B views in imperial
- **THEN** B sees 9.5 lb derived from the same stored grams

### Requirement: Per-device system setting with locale default

The Metric/Imperial choice SHALL be per-device local state (never synced, never in the database) and SHALL initialize from the device locale's measurement system.

#### Scenario: Household mixes systems

- **WHEN** A's phone is metric and B's is imperial
- **THEN** each renders the shared grams in its own system with no conflict and no sync traffic

### Requirement: Field chip filtered by system with live conversion

The input field SHALL offer only the scales of the active system (g|kg or oz|lb) and toggling the chip SHALL live-convert the draft value. Pounds SHALL be decimal (never lb+oz compound).

#### Scenario: Chip converts, not relabels

- **WHEN** a metric draft of 4.3 kg toggles to grams
- **THEN** the field shows 4300 g as the same value, storing 4300 grams whichever chip is active

### Requirement: Trend ignores conversion jitter

Trend and deviation displays SHALL apply an epsilon rule (single-digit gram jitter from unit round-trips is not a change) so cross-system households never see phantom gains.

#### Scenario: No phantom gain from B's phone

- **WHEN** B logs 9.5 lb (≈4309 g) for a 4300 g pet
- **THEN** the trend does not flag a gain from the rounding residue

### Requirement: Dimension concept reserved for doses

The units layer SHALL distinguish convertible dimensions (mass: g⇄kg⇄oz⇄lb) from discrete ones (tabs, drops, IU — no cross-conversion). V1 SHALL ship mass-for-weight only; dose dimensions arrive later with no retrofit to weight storage.

#### Scenario: Tabs never convert to milligrams

- **WHEN** a future dose unit is added
- **THEN** discrete units carry no conversion path and weight code is untouched
