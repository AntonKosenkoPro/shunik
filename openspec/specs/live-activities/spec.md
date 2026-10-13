# Live Activities Specification

## Purpose

A Live Activity mirrors the running timer outside the app — in the Dynamic Island, on the Lock Screen, and (via the system) on the user's Mac — with Stop and return-to-Track actions, so a run stays glanceable and stoppable without opening the app.
## Requirements
### Requirement: Live Activity follows the running timer
The system SHALL start a Live Activity when a timer starts and end it when the timer stops. The activity SHALL be requested only while the app is in the foreground and only when Live Activities are enabled; at most one activity SHALL exist at a time (the `timer_state` singleton). Starting SHALL NOT create an entry and stopping via the activity SHALL save the entry exactly as an in-app Stop (same `source='manual'` path, same outbox row). The activity content SHALL refresh the visible category chips when the running draft is retagged mid-run (same text keeps the singleton; chips update in place); the first-position icon stays as requested at start.

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
- **THEN** the Live Activity keeps its singleton identity (same text) and its visible category chips update to the draft's current ordered set; the first-position icon stays as requested at start; identical chips skip the update

### Requirement: Island and banner presentations
The activity SHALL provide compact (icon + elapsed), minimal (icon only), expanded (big borderless elapsed top-left + Stop top-right + full-width name with category chips along the bottom), and Lock Screen banner (icon + exact name + elapsed + Stop as transparent content over the system card) presentations. Elapsed time SHALL tick via the system timer view (no per-second updates). The expanded face SHALL show the exact entry text verbatim (`Gym` ≠ `GYM`, one line) and the draft's ordered categories as icon chips (validated SF Symbol + name, cap 2 chips + `+n` overflow, never a half-clipped third chip); the expanded timer readout SHALL NOT truncate at width phase crossings (`9:59`→`10:00`, `59:59`→`1:00:00`). The Lock Screen banner SHALL render no custom container — on iOS 26+ the system Liquid Glass card (via a clear background tint), on older systems the default solid card. Faces SHALL show only the exact entry text, the first-position category icon, chips, and the elapsed readout — never provenance labels, notes, or started-at lines. All faces SHALL expose localized accessibility labels naming the text and running state.

#### Scenario: Single activity owns the pill
- **WHEN** this is the only active activity
- **THEN** the Island shows the compact face (icon + ticking elapsed)

#### Scenario: Competing activity squeezes to minimal
- **WHEN** another app's activity is also active
- **THEN** this activity renders its minimal face (icon only) without layout breakage

#### Scenario: Long-press expands
- **WHEN** the user long-presses the compact or minimal face
- **THEN** the expanded card shows the big ticking elapsed top-left, Stop top-right, and the exact name plus category chips full-width along the bottom

#### Scenario: Lock Screen banner
- **WHEN** the device is locked with the timer running
- **THEN** the banner shows the icon, exact name, and ticking elapsed plus Stop as transparent content over the system card (glass on iOS 26+, solid card below)

#### Scenario: Long timer never truncates
- **WHEN** the run crosses an elapsed-width boundary (e.g. 10 minutes, 1 hour)
- **THEN** the expanded timer readout keeps its full digits with no clipping into the Island curve

#### Scenario: Categories follow the draft
- **WHEN** the running draft carries ordered categories
- **THEN** the expanded face shows them as icon chips in draft order; drafts with no categories show no chip row

### Requirement: Stop and return actions
Tapping any face SHALL deep-link to Track (`lifio://track`). The expanded card and the banner SHALL offer a Stop button that stops and saves the entry through the same `LocalStore` path as in-app Stop (`source='manual'`, outbox row in the same transaction) without opening the app. Compact and minimal faces SHALL offer no buttons (tap navigates only).

#### Scenario: Tap returns to Track
- **WHEN** the user taps the compact, minimal, expanded, or banner surface (outside Stop)
- **THEN** the app opens to Track for the running timer

#### Scenario: Stop from the Island saves
- **WHEN** the user activates Stop in the expanded card or banner while running
- **THEN** the entry is saved with the draft's final categories, the running draft is cleared, and Track reconciles via its existing external-stop path. The Island itself is ended by the app on contact (Darwin signal, foreground, or load) — the intent only saves and signals, never ends.

#### Scenario: Stop fails gracefully
- **WHEN** Stop is activated with no active account file or an inaccessible database (e.g. cold boot before first unlock)
- **THEN** nothing is written, no anonymous file is created, and the activity keeps its current face

#### Scenario: Dimmed rendering hides the Stop control
- **WHEN** the activity renders outside full color (Always-on dim, StandBy accent modes)
- **THEN** faces show the same layout with the Stop control dimmed and inert instead of hidden (it is not interactive there and its saturated red is quieted); the control returns to full opacity in full color

#### Scenario: Dimmed banner masks the seconds
- **WHEN** the banner renders outside full color
- **THEN** the elapsed readout keeps ticking via the system timer view, which the dimmed renderer sustains itself (no coarse static masking)

### Requirement: Saved card then dismissal
Ending the activity SHALL show a final `✓ Saved <duration>` banner and then remove it via a timed dismissal (`.after`, seconds tuned during testing) whenever the true duration is known; the Island SHALL collapse at once. The system default linger (hours) SHALL NOT be used.

#### Scenario: Stop shows Saved then removes
- **WHEN** the timer stops from any surface while the app is live (in-app Stop, or Island Stop reaped with the signaled duration)
- **THEN** the banner shows the Saved card with the final duration and is removed after the tuned delay

#### Scenario: Stop with a terminated app dismisses silently
- **WHEN** an orphaned Island is reaped without a known duration (terminated app, missed signal)
- **THEN** it is dismissed immediately with its last content and no card — no duration is ever invented

#### Scenario: No hour-long linger
- **WHEN** the activity has ended
- **THEN** it is gone within seconds, never lingering for hours

### Requirement: Active-account only, no extension auth or sync
The activity and its Stop intent SHALL operate only on the active account's file in the App Group, SHALL perform no authentication of their own (device unlock is the authorization), SHALL NOT create anonymous files, and SHALL NOT attempt sync (the app's `SyncController` drains the outbox on next foreground).

#### Scenario: Dormant account never surfaces
- **WHEN** another account's file is dormant and this account's file is active
- **THEN** every face and every Stop reads and writes only the active file

#### Scenario: Signed out shows nothing
- **WHEN** no active account file exists
- **THEN** no activity is started and Stop performs no write

