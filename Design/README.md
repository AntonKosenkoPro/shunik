# Design System — Lifio

This directory contains the textual design system for the Lifio iOS app. It is the single source of truth for visual design, reusable components, screen layouts, and interaction patterns.

## Goal

Keep design under version control as plain Markdown so:

- **You** can edit it in any text editor and review diffs in pull requests.
- **Coding agents** can implement screens deterministically without guessing colors, spacing, copy, or behavior.
- **SwiftUI Previews** remain the visual validation loop, replacing the need for a separate design tool for the MVP.

## How to use

1. Before adding or changing a screen, write the spec in `SCREENS/<Screen>.md`.
2. If the screen introduces a new color, spacing value, icon, or component, update `TOKENS.md` or `COMPONENTS.md` first.
3. Implement the screen in SwiftUI using only the tokens and components documented here.
4. Add SwiftUI Previews for light/dark and English/Russian.
5. Run the per-iteration checklist from `AGENTS.md`:
   - `swiftlint lint --strict` (iOS)
   - `xcodebuild test -scheme TimeOfLife -destination '<available simulator>'`
   - confirm requirements alignment
   - update this design doc if the implementation diverged.

### App icon assets

`icon/ios/` is the authoritative approved iOS app-icon package. When the icon changes, replace that package first, then copy its `Contents.json` and referenced PNG files without transformation into `ios/TimeOfLife/TimeOfLife/Resources/Assets.xcassets/AppIcon.appiconset/`. Validate every image's pixel dimensions against its declared point size and scale before building.

## File guide

| File | Purpose |
|---|---|
| `TOKENS.md` | Colors, typography, spacing, corner radii, shadows, and the catalog icon set. |
| `COMPONENTS.md` | Reusable SwiftUI components: signature, states, accessibility IDs, usage. |
| `INTERACTIONS.md` | Shared patterns: loading, errors, offline, empty states, haptics, focus. |
| `SCREENS/Auth.md` | Auth flow screens (Welcome, EmailEntry, OtpEntry). |
| `SCREENS/AppShell.md` | App shell: Track/History/Insights tabs, Profile destination, compact timer placement. |
| `SCREENS/Account.md` | Profile-owned Account page: read-only email, sign-out, local-only deletion, and permanent account/local-data deletion. |
| `SCREENS/TimeTracking.md` | Track screen — the capture destination; covers the numeric timer state machine + name push row, Recents chips, and running tag selector. |
| `SCREENS/History.md` | History screen — day-grouped list of committed time entries (EntryRow, day totals, persistent nav bar; entry-form push, Log Time sheet, pull-to-refresh, shake-to-undo). |
| `SCREENS/Insights.md` | Insights screen — read-only mirror-only breakdown (period switch, hero total, lens toggle, proportional rows). |
| `SCREENS/NamePicker.md` | Shared dedicated name-picking page pushed from Track and the entry form. |
| `SCREENS/EntryForm.md` | Unified entry form (`LogTimeView`) — CREATE sheet (Log Time), EDIT/LOCKED push from History. |
| `SCREENS/ManageCategories.md` | Manage Categories screen — category CRUD, seeding, undo. |
| `SCREENS/CategoryEditor.md` | Shared sheet to create/edit a category. |
| `DECISIONS.md` | Design precedents and rationale. |
| `icon/ios/` | Authoritative iOS app-icon artwork and asset-catalog metadata. |

> Category management introduces the editors (`CategoryEditor`, `ManageCategories`) and the Recents/tag-selector spec in `TimeTracking.md`. The activities layer (`ActivityEditor`, `ManageActivities`, the search sheet) was removed by `remove-activities-layer` — entries own their text and tags.

## Global rules

1. **Tokens only.** No raw `Color(...)`, `.padding(17)`, or hard-coded fonts. Use `Theme.*` for colors and layout constants.
2. **Localized keys only.** No hard-coded user-facing strings. Every string lives in `L10n` and in both `en.lproj/Localizable.strings` and `ru.lproj/Localizable.strings`.
3. **Accessibility identifiers.** Every interactive element gets a stable `accessibilityIdentifier` for UI tests.
4. **Minimum tap area.** All tappable targets are at least `44×44 pt`.
5. **Dynamic Type.** Use text styles (`.largeTitle`, `.title`, `.title2`, `.headline`, `.body`, `.subheadline`, `.caption`) instead of fixed sizes.
6. **Color scheme.** Light and dark variants must be previewed and tested. The app follows the system scheme by default.
7. **Offline awareness.** Every screen documents its offline behavior; network-dependent actions are disabled offline with `error.offline`. There is no global offline banner — offline surfaces via the History pull-to-refresh inline notice and the Profile sync status.

## Decisions log

See `DECISIONS.md` for resolved design precedents. Respect them when adding new screens.
