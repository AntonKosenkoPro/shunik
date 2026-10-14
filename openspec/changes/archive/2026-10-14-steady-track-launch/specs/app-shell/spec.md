## MODIFIED Requirements

### Requirement: Three primary destinations
The app SHALL provide Track, History, and Insights as its primary destinations, and SHALL identify Track as the destination for starting and controlling a timer. The History destination SHALL present committed time entries as a day-grouped, read-only list (see `history-entry-list` capability). The Insights destination SHALL present a period-scoped breakdown of committed tracked time with a hero total (see `insights-breakdown` capability), replacing the empty-state placeholder whenever committed entries exist. The History destination SHALL show the navigation bar (inline title and Profile button) at rest and collapse it on scroll; the Profile button remains present on Track and Insights. The app SHALL require authentication before presenting any primary destination: when the user is signed out, the app SHALL render the auth flow full-screen in place of the shell and MUST NOT render Track, History, Insights, or the tab bar; primary destinations become reachable only after sign-in. When a cached session exists at launch, the app SHALL optimistically prepare that account's shell — bind the local store, commit buffered deletions, seed starter categories, and load the full Track snapshot (recents, names, categories, persisted running draft) — and mount the shell with the snapshot already in hand, so the first visible Track paint is complete with no splash, skeleton, spinner, or fade; session restore (`/me`) verifies concurrently in the background and is invisible on success, while an authentication failure cuts to the auth flow (lock-not-wipe semantics unchanged: local files are never touched). When no cached session exists, the app SHALL render the auth flow immediately with no waiting UI. The shell SHALL mount only after the signed-in account's local store is bound, buffered deletions are committed, starter categories are seeded, and the first Track snapshot is loaded; the first-sync network pull stays background and MUST NOT block the reveal.

#### Scenario: Local launch
- **WHEN** the user launches the app signed out, with no account or active timer
- **THEN** the auth flow is presented full-screen instead of Track and the primary destinations are not reachable until sign-in succeeds

#### Scenario: Switching destinations
- **WHEN** the user selects History or Insights
- **THEN** the selected destination becomes visible without changing timer state or discarding the state of the previous destination

#### Scenario: Profile access on History
- **WHEN** the user is on History at rest (list at top) and wants to open Profile
- **THEN** the Profile button is visible in the navigation bar and opens Profile

#### Scenario: Insights shows breakdown
- **WHEN** the user selects Insights with committed entries on record
- **THEN** the period breakdown with hero total is shown instead of the empty-state placeholder

#### Scenario: Auth gate is not a sheet
- **WHEN** the user is signed out at launch
- **THEN** the auth flow covers the full screen with no shell visible behind it, and there is no way to dismiss it into the app without signing in

#### Scenario: Restoring session shows splash, not login
- **WHEN** the app launches with a cached session and tokens whose server validation is still in flight
- **THEN** the gate mounts the shell optimistically with the locally prepared snapshot instead of the auth flow (the restoring splash no longer exists), and the auth flow appears only if the restore resolves to signed-out

#### Scenario: Cached session launches straight into complete Track
- **WHEN** the app launches with a cached session for an account with committed entries
- **THEN** the first visible paint is the Track screen already showing Recents chips with icons (or the restored running state) — no splash, skeleton, spinner, or fade appears at any point, and no empty hint flashes

#### Scenario: Failed background restore cuts to auth
- **WHEN** the background session restore rejects the cached session (revoked, reused, or TTL-exhausted refresh)
- **THEN** the app cuts to the full-screen auth flow with local account files intact, and a fresh sign-in reopens and resumes the same account file

#### Scenario: Shell mounts after local ready
- **WHEN** the user signs in (fresh, restored, or re-login) on a device whose account file needs binding, buffered-deletion commit, or starter seeding
- **THEN** the shell appears only after the bind, commit, seed, and first Track snapshot load complete, so the first Track paint already carries starter categories and local recents and never flashes an empty store

## REMOVED Requirements

### Requirement: Restoring splash shows the Lifio brand mark
- **Reason:** the optimistic launch holds no splash, skeleton, or spinner at all — the first visible paint is the complete Track screen, so there is no restoring surface left for the mark to live on. Brand continuity stays where HIG places branding: the Welcome screen keeps its mark (unchanged code, covered by the auth flow, not by this spec).
- **Migration:** none. No other spec references the restoring splash; delete the splash view and its gate branches with the veil machinery.
