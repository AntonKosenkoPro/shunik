## ADDED Requirements

### Requirement: First Track paint carries the full local snapshot in one commit

Track's first data — recents, the full name list, the category map, and the persisted running draft — SHALL be loaded through one shared snapshot query set whose results publish in a single render commit (gathered into locals, assigned synchronously), so the empty state is never visibly replaced by loaded content across progressive paints. The launch gate preloads the same snapshot before mounting; `TrackViewModel.load()` consumes the same loader and adopts a preloaded snapshot when one is handed to the shell, re-querying only when none was provided.

#### Scenario: Cold boot shows chips on first paint
- **WHEN** the user cold-boots with committed entries on the device
- **THEN** the first visible Track paint already shows Recents chips with icons — no empty hint, no progressive fill across multiple renders

#### Scenario: Cold boot with a persisted run restores it on first paint
- **WHEN** the user cold-boots with a running timer draft persisted in the local store
- **THEN** the first visible Track paint already shows the running state (locked name, tag selector, elapsed readout) — the screen never shows idle first

#### Scenario: Preload failure falls back to load-on-appear
- **WHEN** the gate preload throws (unbound or unreadable store)
- **THEN** the shell still mounts on schedule and `TrackViewModel.load()` runs on appear, surfacing the existing recoverable error banner instead of blanking — a failed preload never strands the launch

### Requirement: Reloads publish once and skip unchanged snapshots

Every Track reload (tab return, Profile exit, sync-cycle exit) SHALL resolve through the same single-commit snapshot path, and SHALL skip publishing when the resolved snapshot equals the current one, so no-op reloads (including sync cycles that merge nothing new) render literally nothing and relay-pulled changes fill in place without blanking.

#### Scenario: No-op sync exit renders nothing
- **WHEN** a background sync cycle finishes having merged no new entries, categories, or draft changes
- **THEN** Track publishes nothing and the screen holds its pixels — no flash, no shift, no re-render artifacts

#### Scenario: Relay data fills in place
- **WHEN** a sync cycle merges newer relay entries or categories
- **THEN** Track reloads once through the snapshot path and the new rows appear in their reserved geometry without blanking the last good snapshot
