# App Shell — Track / History / Insights / Profile

Implements the `app-shell` capability (OpenSpec change `redesign-track-experience`): a stable product hierarchy for frequent capture, retrospective review, and analysis, with account and configuration tasks kept secondary and a running timer kept globally accessible.

## Hierarchy

```
TabView (Track | History | Insights)
  ├─ Track      — capture: name push row + shared picker + Recents chips + numeric timer (SCREENS/TimeTracking.md, SCREENS/NamePicker.md)
  ├─ History    — retrospective review (SCREENS/History.md; entry-form push, Log Time sheet, pull-to-refresh)
  └─ Insights   — analysis: period breakdown with hero total (SCREENS/Insights.md)
Profile (pushed page, top-trailing person control on every tab; signed-in only — unreachable until the launch gate signs the user in)
  ├─ Account >          (pushed page on the same tab path: read-only email, Sign out, Delete local data, Delete account and local data — full spec: SCREENS/Account.md)
  ├─ Sync status / Sync now   (stays directly on Profile — convenient, no Account entry needed)
  ├─ Categories >             (Manage Categories — stays on Profile)
  └─ Version                  (trailing diagnostic footer — stays on Profile)
```

- Each tab owns its own `NavigationStack` path (`trackPath` / `historyPath` / `insightsPath`, per-tab-navigation-paths): entry taps append to the History path only, Profile pushes per-tab — opening Profile on one tab never pre-pushes it on another. Destinations live next to their stack (History's entry-form + Profile destinations render inside `HistoryView`).
- Track is the initially selected destination and the only place that starts or stops a timer.
- Profile is opened from a consistent top-trailing person control and is **not** a fourth tab.
- The hierarchy maps to a future macOS sidebar without changing meaning: Track, History, Insights become primary sidebar destinations; profile-owned features remain secondary.

## Screen: AppShellView

- **File**: `ios/TimeOfLife/TimeOfLife/Features/AppShell/Views/AppShellView.swift`
- **Route**: root of `RootView` (replaces the timer-only root)
- **State**: `AppShellViewModel` (selected tab, running-timer observation)

### Layout

1. `TabView(selection:)` with three tabs:
   - Track — `Label(L10n.tabTrack, systemImage: "timer")`, `accessibilityIdentifier("TabTrack")`.
   - History — `Label(L10n.tabHistory, systemImage: "clock.arrow.circlepath")`, `accessibilityIdentifier("TabHistory")`.
   - Insights — `Label(L10n.tabInsights, systemImage: "chart.line.uptrend.xyaxis")`, `accessibilityIdentifier("TabInsights")`.
2. Each tab root carries the top-trailing person control (`ProfileButton`) pushing the Profile page.
3. While a timer is running, History and Insights render the compact timer immediately above the tab bar via `.safeAreaInset(edge: .bottom)` (see `CompactTimer` in `COMPONENTS.md`). Track does not duplicate it — the full numeric timer is already visible.
4. There is no global offline banner. Offline surfaces via the History pull-to-refresh inline notice and the Profile sync status.

### Behaviors

- Switching destinations never changes timer state and never discards the previous destination's state (tab state is preserved by `TabView`).
- The app launches into the auth flow when signed out (the auth flow is the root until sign-in completes) and into Track when signed in; there is no unsigned use and no "Enable Sync" action.
- Insights shows a mirror-only breakdown of committed time (full spec: `SCREENS/Insights.md`): a `Today | This week | All time` period switch (default `This week`), a hero period total, a `By category | By text` lens toggle (default `By category`), and proportional rows with max-scaled bars. Category rows attribute the full duration to every attached category (rows may sum above the hero) with a one-line footnote naming the rule; rows are not tappable; empty periods show a one-line sentence, and the true-zero state keeps the honest placeholder.
- Profile is signed-in-only and shows sync state plus navigation. Dismissing Profile restores the previously selected destination and its state. Profile owns NO destructive actions directly: Sign out, Delete local data (renamed from "Erase local data"), and Delete account and local data live only in Account — no duplicates on Profile, no placeholder rows (full spec: `SCREENS/Account.md`).
- The compact timer's main area returns to Track; its Stop button saves in place and keeps the current destination selected.

### Accessibility

- Tab items expose stable identifiers (`TabTrack`, `TabHistory`, `TabInsights`) and localized labels.
- The compact timer is a single accessible element announcing entry text, elapsed duration, running state, and available actions (see `COMPONENTS.md`).
- Navigation labels and compact timer content remain readable at accessibility Dynamic Type sizes without hiding Start/Stop actions.

### Implementation checklist

- [ ] All colors use `Theme.*` tokens.
- [ ] All strings use `L10n.*` keys in English and Russian.
- [ ] Tab items and Profile button have stable identifiers.
- [ ] Compact timer appears only on History/Insights and only while running.
- [ ] Profile is a pushed page, not a tab.
- [ ] VoiceOver, Dynamic Type, Reduce Motion, light/dark, and iOS 18 are tested.
- [ ] SwiftLint and warning-as-error builds pass.
