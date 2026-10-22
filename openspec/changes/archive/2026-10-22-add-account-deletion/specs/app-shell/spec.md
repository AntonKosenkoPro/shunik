## MODIFIED Requirements

### Requirement: Three primary destinations
The app SHALL provide Track, History, and Insights as its primary destinations, and SHALL identify Track as the destination for starting and controlling a timer. The History destination SHALL present committed time entries as a day-grouped, read-only list (see `history-entry-list` capability). The Insights destination SHALL present a period-scoped breakdown of committed tracked time with a hero total (see `insights-breakdown` capability), replacing the empty-state placeholder whenever committed entries exist. The History destination SHALL show the navigation bar (inline title and Profile button) at rest and collapse it on scroll; the Profile button remains present on Track and Insights. The app SHALL require authentication before presenting any primary destination: when the user is signed out, the app SHALL render the auth flow full-screen in place of the shell and MUST NOT render Track, History, Insights, or the tab bar; primary destinations become reachable only after sign-in. When a cached session exists at launch, the app SHALL optimistically prepare that account's shell — bind the local store, commit buffered deletions, seed starter categories, and load the full Track snapshot (recents, names, categories, persisted running draft) — and mount the shell with the snapshot already in hand, so the first visible Track paint is complete with no splash, skeleton, spinner, or fade; session restore (`/me`) verifies concurrently in the background and is invisible on success, while an authentication failure cuts to the auth flow. Normal authentication failure SHALL preserve local account files; only independently confirmed account deletion SHALL schedule the separate account-scoped cleanup defined by `account-deletion`. When no cached session exists, the app SHALL render the auth flow immediately with no waiting UI. The shell SHALL mount only after the signed-in account's local store is bound, buffered deletions are committed, starter categories are seeded, and the first Track snapshot is loaded; the first-sync network pull stays background and MUST NOT block the reveal.

#### Scenario: Local launch
- **WHEN** the user launches the app signed out, with no account or active timer
- **THEN** the auth flow is presented full-screen instead of Track and the primary destinations are not reachable until sign-in succeeds

#### Scenario: Switching destinations
- **WHEN** the user selects History or Insights
- **THEN** the selected destination becomes visible without changing timer state or discarding the state of the previous destination

#### Scenario: Profile access on History
- **WHEN** the user is on History at rest and wants to open Profile
- **THEN** the Profile button is visible in the navigation bar and opens Profile

#### Scenario: Insights shows breakdown
- **WHEN** the user selects Insights with committed entries on record
- **THEN** the period breakdown with hero total is shown instead of the empty-state placeholder

#### Scenario: Auth gate is not a sheet
- **WHEN** the user is signed out at launch
- **THEN** the auth flow covers the full screen with no shell visible behind it and there is no way to dismiss it into the app without signing in

#### Scenario: Restoring session shows splash, not login
- **WHEN** the app launches with a cached session and tokens whose server validation is still in flight
- **THEN** the gate mounts the shell optimistically with the locally prepared snapshot instead of the auth flow, the restoring splash no longer exists, and auth appears only if restore resolves to signed-out

#### Scenario: Cached session launches straight into complete Track
- **WHEN** the app launches with a cached session for an account with committed entries
- **THEN** the first visible paint is Track already showing Recents chips with icons or the restored running state, with no splash, skeleton, spinner, fade, or empty-hint flash

#### Scenario: Failed background restore cuts to auth
- **WHEN** background restore rejects a revoked, reused, or TTL-exhausted session without independent account-deletion confirmation
- **THEN** the app cuts to the auth flow with local files intact and a fresh sign-in reopens and resumes the same existing account

#### Scenario: Shell mounts after local ready
- **WHEN** fresh, restored, or repeated sign-in binds an account file needing buffered-deletion commit or starter seeding
- **THEN** the shell appears only after bind, commit, seed, and first snapshot load so its first Track paint is complete

### Requirement: Profile owns secondary destinations
The app SHALL expose account, sync, category management, and destructive data controls from a profile destination rather than as a primary tab. The profile destination SHALL open as a pushed page on the current tab's own navigation path with the system back button, and SHALL NOT present as a sheet or offer a Done/dismiss control. Each tab (Track, History, Insights) SHALL own an independent navigation path: opening Profile on one tab SHALL NOT push Profile on any other tab, and switching tabs SHALL NOT carry Profile state across. Account and Manage Categories SHALL push from Profile on the same tab path, and the category editor SHALL remain a sheet. The profile destination SHALL be signed-in-only: it SHALL NOT present an Enable Sync row or auth-flow sheet, and the auth flow SHALL NOT be presented from Profile as a sheet. Because the launch auth gate guarantees a signed-in user, account identity and sync state SHALL reflect the active signed-in account at all times. Profile SHALL retain Account navigation, sync status/Sync now, Categories navigation, and version; Sign out and Delete local data SHALL move into Account alongside Delete account and local data and SHALL NOT be duplicated directly on Profile. The profile destination SHALL NOT expose integrations, export, appearance, or data-and-privacy placeholder rows, and no activity catalog exists. Destructive rows in Account SHALL share one list-row visual contract: the shared list row geometry with a leading icon and the danger tint.

#### Scenario: Open profile while signed out
- **WHEN** a user without an account attempts to reach the profile destination
- **THEN** the auth gate precedes it: the profile destination is unreachable, and the auth flow is the only presented surface until sign-in completes

#### Scenario: Return from profile
- **WHEN** the user navigates back from the profile destination
- **THEN** the previously selected primary destination and its own tab-path state are restored, and Track data is reloaded once on exit so categories created in Profile are immediately usable

#### Scenario: Profile stays on its tab
- **WHEN** the user opens Profile on Track and then switches to History after navigating back
- **THEN** History shows its own root without Profile pre-pushed and each tab's push state evolves independently afterwards

#### Scenario: Enable Sync with a restorable session
- **WHEN** the launch gate runs with a valid restorable session
- **THEN** silent restore signs the user in with no auth flow shown and the shell is presented directly

#### Scenario: Enable Sync without a restorable session
- **WHEN** the launch gate runs with no restorable session
- **THEN** the required-voice auth flow is presented full-screen, never a silent no-op into the shell

#### Scenario: Sign in from the sheet
- **WHEN** the user completes sign-in in the launch-gate auth flow
- **THEN** the shell replaces the auth flow with Track selected and Profile exposes the signed-in account destination and sync state

#### Scenario: Dismiss the sheet unsigned
- **WHEN** the user attempts to leave the launch-gate auth flow without signing in
- **THEN** no dismiss or cancel path is offered and local data stays untouched

#### Scenario: No placeholder rows
- **WHEN** the user opens Profile
- **THEN** no Integrations, Export, Appearance, or Data & Privacy rows are shown and every visible row is navigation, an action, live status, or version information

#### Scenario: Sign out row parity
- **WHEN** the user opens Account from Profile
- **THEN** Sign out uses the same list-row geometry, leading icon, and danger tint as Delete local data, keeps the `ProfileSignOutButton` accessibility identifier, and tapping it asks once before signing out

#### Scenario: Profile retains convenient sync
- **WHEN** the user opens Profile after account actions move
- **THEN** sync status and Sync now remain directly accessible without entering Account and no direct Sign out or local-deletion action remains on Profile

## ADDED Requirements

### Requirement: Account page displays identity and separated account actions
Account SHALL be a signed-in-only pushed page titled Account with system Back to Profile, no Done/dismiss control, and the tab bar hidden at every nested depth. It SHALL show the active account's full stored email as read-only wrapping text, available from cached session state offline. It SHALL NOT offer email editing or substitute an inferred personal email for an Apple relay address. The page SHALL group email and Sign out under account identity, Delete local data under a device-only group, and Delete account and local data under a visually separate permanent-deletion group. Helper text SHALL distinguish their effects. All labels/helper text SHALL support English, Russian, VoiceOver, and Dynamic Type without truncating consequential wording.

#### Scenario: Account opens from each tab's Profile
- **WHEN** the user navigates any tab → Profile → Account
- **THEN** Account pushes on that tab's own stack with the tab bar hidden and Back returns to Profile without resetting the tab's root state

#### Scenario: Account email offline
- **WHEN** the signed-in user opens Account without connectivity
- **THEN** the full cached account email is visible and read-only

#### Scenario: Apple private email
- **WHEN** the account's stored email is an Apple private-relay address
- **THEN** Account displays that actual address rather than guessing or requesting the user's personal email

#### Scenario: Large text and long email
- **WHEN** Account is displayed with a long email and an accessibility Dynamic Type size in either locale
- **THEN** email, destructive labels, and explanatory text remain readable with wrapping and the three actions remain distinguishable

### Requirement: Permanent deletion uses one explicit confirmation alert
The permanent-deletion row and its destructive confirmation button SHALL explicitly read Delete account and local data in English, with equivalent Russian wording. The single confirmation alert's title SHALL explicitly name both account and local data deletion, and its message SHALL describe permanent removal of the Lifio account, synced entries/categories/notes, this account's data on this iPhone, and sign-out of other devices. Cancel SHALL leave the account and data unchanged. The app SHALL NOT add a second deletion-confirmation alert. Required native Apple authorization is not an extra confirmation alert. While a deletion submission is in flight, conflicting account actions and duplicate submissions SHALL be unavailable and progress SHALL be accessible.

#### Scenario: Confirmation states both consequences
- **WHEN** the user taps Delete account and local data
- **THEN** one alert names both consequences in its title and destructive button, explains scope, and offers Cancel

#### Scenario: Cancel deletion
- **WHEN** the user cancels the confirmation alert
- **THEN** no deletion request is sent and no local or server data changes

#### Scenario: Confirm only once
- **WHEN** the user confirms permanent deletion
- **THEN** the operation proceeds without another deletion-confirmation alert and duplicate submission is prevented
