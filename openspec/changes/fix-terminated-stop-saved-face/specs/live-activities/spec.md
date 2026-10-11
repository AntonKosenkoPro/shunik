# Live Activities — terminated Island Stop opens the app (delta)

## MODIFIED Requirements

### Requirement: Stop and return actions
Tapping any face SHALL deep-link to Track (`lifio://track`). The expanded Island face SHALL offer Stop as a `Link` to the stop URL (`lifio://track?stop=1`): tapping it opens the app, which stops and saves the entry through the exact in-app path (`LocalStore`, `source='manual'`, outbox row in the same transaction) and ends the activity with the Saved card — including when the app process was dead (cold open performs reload-then-stop; no draft → graceful no-op). The banner SHALL offer Stop as a `Link` to the same stop URL with identical open-and-stop semantics (Spike E, device-proven: sibling-`widgetURL` loses to the label URL, `Link` wins) — the intent button remains only as the nil-URL fail-safe and the AoD-dimmed/inert rule is unchanged. Compact and minimal faces SHALL offer no buttons (tap navigates only).

#### Scenario: Tap returns to Track
- **WHEN** the user taps the compact, minimal, expanded, or banner surface (outside Stop)
- **THEN** the app opens to Track for the running timer

#### Scenario: Stop from the Island saves
- **WHEN** the user activates Stop in the expanded Island while running
- **THEN** the app opens to Track and the entry is saved with the draft's final categories through the in-app Stop path, the running draft is cleared, and the activity ends with the Saved card

#### Scenario: Stop from the expanded Island with a terminated app opens and stops
- **WHEN** the user activates Stop in the expanded Island while the app process is dead (swiped away or jetsammed) and a run is active
- **THEN** the entry is saved exactly as an in-app Stop AND the app opens, where the cold-open reload-then-stop ends the activity with the `✓ Saved <duration>` card and the tuned dismissal — no ticking orphan survives first contact, and no second tap is needed

#### Scenario: Island Stop with nothing running is a no-op
- **WHEN** the stop link opens the app with no active run (double tap, stale face)
- **THEN** the app opens to Track, nothing is written, and no error surfaces

#### Scenario: Banner Stop with a terminated app opens and stops
- **WHEN** the user activates Stop in the banner while the app process is dead and a run is active
- **THEN** the entry is saved exactly as an in-app Stop AND the app opens, where the cold-open reload-then-stop ends the activity — no ticking orphan survives first contact, and no second tap is needed (device-proven 2026-10-11: `Banner probe|16m47s`)

#### Scenario: Stop fails gracefully
- **WHEN** Stop is activated with no active account file or an inaccessible database (e.g. cold boot before first unlock)
- **THEN** nothing is written, no anonymous file is created, and the activity keeps its current face

#### Scenario: Dimmed rendering hides the Stop control
- **WHEN** the activity renders outside full color (Always-on dim, StandBy accent modes)
- **THEN** faces show the same layout without the Stop control (it is not interactive there and its saturated red otherwise dominates the dimmed face); the control returns in full color

#### Scenario: Dimmed banner masks the seconds
- **WHEN** the banner renders outside full color
- **THEN** the elapsed readout shows the name plus a coarse static `H:MM:--` reading (Apple Timer pattern) instead of the ticking timer, which the dimmed renderer cannot sustain

### Requirement: Saved card then dismissal
Ending the activity SHALL show a final `✓ Saved <duration>` banner and then remove it via a timed dismissal (`.after`, seconds tuned during testing) whenever the true duration is known; the Island SHALL collapse at once. The system default linger (hours) SHALL NOT be used. A terminated-app Island Stop SHALL reach the same Saved card by opening the app into the in-app stop path. Silent immediate dismissal is reserved for reaps with no known save.

#### Scenario: Stop shows Saved then removes
- **WHEN** the timer stops from any surface while the app is live (in-app Stop, or Island Stop reaped with the signaled duration)
- **THEN** the banner shows the Saved card with the final duration and is removed after the tuned delay

#### Scenario: Terminated-app Island Stop shows Saved after opening
- **WHEN** an Island Stop opens the dead app (entry saved in-app on open, no prior app contact)
- **THEN** the banner shows the `✓ Saved <duration>` face with the true duration through the normal end path and is removed after the tuned dismissal — no double card, no invented duration, no lingering running face

#### Scenario: Terminated-app banner Stop ends the activity on opening
- **WHEN** a banner Stop opens the dead app (entry saved in-app on open, no prior app contact)
- **THEN** the activity ends through the normal end path — no lingering running face (device-proven 2026-10-11: no banner on re-lock after `Banner probe|16m47s` save)

#### Scenario: Stop with a terminated app dismisses silently
- **WHEN** an orphaned Island is reaped without a known save (terminated app, missed signal, no recent entry)
- **THEN** it is dismissed immediately with its last content and no card — no duration is ever invented

#### Scenario: No hour-long linger
- **WHEN** the activity has ended
- **THEN** it is gone within seconds, never lingering for hours
