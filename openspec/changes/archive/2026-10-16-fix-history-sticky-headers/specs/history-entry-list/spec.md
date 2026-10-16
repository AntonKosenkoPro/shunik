## MODIFIED Requirements

### Requirement: Day groups use relative-then-absolute labels; total shown when elevated
Day group headers SHALL use relative labels ("Today", "Yesterday") for the two most recent days and the regional-standard absolute date for older days. Each header SHALL show the day label on its first line and the day's total tracked time as a subheader second line ("8h 30m tracked": total formatted in the device locale's natural language with a localized "tracked" suffix), following the Calendar Agenda week-number pattern. The total subline SHALL be visible in every header position — in-list and pinned alike, with no scroll-state gating. The day label SHALL be left-aligned to the `EntryRow` icon column's leading edge on compact width (both at `Theme.spacingMedium`); regular width follows when the iPad reflow lands (deferred per design.md D1 iPhone-first). Day group headers SHALL render as bare two-line blocks with no background fill or material, in a native `List(.plain)` (design.md D8). Pinned headers do NOT occlude scrolled rows — row text may visibly cross beneath a pinned header on every OS (accepted bleed); the day label and total subline remain readable. Under Reduce Transparency / Increase Contrast nothing changes (there is no material to fall back from; the page background is opaque).

#### Scenario: Today's entries
- **WHEN** entries exist for the current calendar day
- **THEN** their day group header reads "Today" (localized) with the day's total tracked time as its subline

#### Scenario: Yesterday's entries
- **WHEN** entries exist for the previous calendar day
- **THEN** their day group header reads "Yesterday" (localized) with the day's total tracked time as its subline

#### Scenario: Older entries
- **WHEN** entries exist for a day before yesterday
- **THEN** their day group header reads the absolute date formatted using the device's regional settings, with the day's total tracked time as its subline

#### Scenario: In-list header shows only the day label
- **WHEN** a day group header sits in its in-list scroll position (not pinned at the top)
- **THEN** the header shows the day label on its first line together with the total subline on its second line — the position-independent two-line header supersedes the former label-only presentation, so in-list and pinned headers render identically

#### Scenario: Day with in-progress entries
- **WHEN** a day group contains an entry with no end time
- **THEN** the total counts only entries with a known `durationSeconds`; in-progress entries contribute zero to the total

#### Scenario: Elevated total follows the device locale
- **WHEN** the device locale is Russian and a header is elevated
- **THEN** the day total renders with Russian unit abbreviations followed by the localized "tracked" suffix (the total subline is position-independent, so this holds for in-list headers identically)

#### Scenario: Pinned header bleed is accepted
- **WHEN** the user scrolls a day group so its header pins at the top of the list
- **THEN** scrolled row text may remain visible crossing beneath the pinned header, while the day label and total subline stay readable

#### Scenario: Reduce Transparency changes nothing
- **WHEN** Reduce Transparency (or Increase Contrast requiring opacity) is enabled
- **THEN** day group headers render exactly as otherwise (bare text over the opaque page; no material involved)

## ADDED Requirements

### Requirement: Pinned header stays legible over dense content on iPad
On regular-width (iPad) panes the pinned day group header SHALL keep the day label and the total subline simultaneously legible over scrolling entry rows in light and dark appearances, with no opaque seam or material against the navigation bar and no label/subline overlap at any supported Dynamic Type size.

#### Scenario: iPad landscape pinned header
- **WHEN** the user scrolls History on an iPad landscape pane so a day header pins
- **THEN** the day label and the total subline are both readable over the blurred rows beneath, with the header band visually continuous with the navigation bar

#### Scenario: Large Dynamic Type keeps label and subline apart
- **WHEN** the device uses an accessibility-large Dynamic Type size
- **THEN** the day label and the total subline do not overlap or clip

### Requirement: List content passes under the glass tab bar
On iOS 26 and later, the History list SHALL extend its scroll content beneath the bottom tab bar so rows blur behind the glass mid-scroll (TestFlight parity). On iOS 18 the tab bar SHALL render opaque so no scrolled content shows through it. On every OS the bottom content inset SHALL keep the final row fully reachable above the tab bar and above the compact timer when it is shown (native `List` insets; no manual frame games).

#### Scenario: Rows blur beneath the tab bar (iOS 26+)
- **WHEN** the user scrolls History so content crosses the tab-bar line on iOS 26 or later
- **THEN** rows pass visibly blurred beneath the bar with no hard cut at its top edge

#### Scenario: Default tab bar on iOS 18
- **WHEN** the user scrolls History on iOS 18
- **THEN** no scrolled content is visible through the bar (opaque bar), matching the pre-bridge parking

#### Scenario: Final row reachable with and without the compact timer
- **WHEN** the compact timer is shown or hidden
- **THEN** the last entry row scrolls fully above the timer/tab-bar chrome (no row permanently obscured)
