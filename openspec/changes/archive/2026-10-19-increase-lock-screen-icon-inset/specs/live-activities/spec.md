## MODIFIED Requirements

### Requirement: Island and banner presentations
The activity SHALL provide compact (icon + elapsed), minimal (icon only), expanded (big borderless elapsed top-left + Stop top-right + full-width name with category chips along the bottom), and Lock Screen banner (icon + exact name + elapsed + Stop as transparent content over the system card) presentations. Elapsed time SHALL tick via the system timer view (no per-second updates). The expanded face SHALL show the exact entry text verbatim (`Gym` ≠ `GYM`, one line) and the draft's ordered categories as icon chips (validated SF Symbol + name, cap 2 chips + `+n` overflow, never a half-clipped third chip); the expanded timer readout SHALL NOT truncate at width phase crossings (`9:59`→`10:00`, `59:59`→`1:00:00`). The Lock Screen banner SHALL render no custom container — on iOS 26+ the system Liquid Glass card (via a clear background tint), on older systems the default solid card. The Lock Screen banner content row SHALL be inset 12pt from the leading system-card edge (icon side) and 8pt from the trailing edge and vertically. Faces SHALL show only the exact entry text, the first-position category icon, chips, and the elapsed readout — never provenance labels, notes, or started-at lines. All faces SHALL expose localized accessibility labels naming the text and running state.

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

#### Scenario: Lock Screen banner leading inset
- **WHEN** the device is locked with the timer running
- **THEN** the icon sits 12pt inside the leading system-card edge while the trailing content edge and vertical insets stay 8pt, and the Dynamic Island faces are unchanged

#### Scenario: Long timer never truncates
- **WHEN** the run crosses an elapsed-width boundary (e.g. 10 minutes, 1 hour)
- **THEN** the expanded timer readout keeps its full digits with no clipping into the Island curve

#### Scenario: Categories follow the draft
- **WHEN** the running draft carries ordered categories
- **THEN** the expanded face shows them as icon chips in draft order; drafts with no categories show no chip row
