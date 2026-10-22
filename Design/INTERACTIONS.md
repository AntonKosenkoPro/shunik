# Interaction Patterns

These rules apply across all screens unless a screen spec explicitly overrides them.

## Loading states

- Buttons show an indeterminate `ProgressView` inside the button at full width.
- Do **not** show blocking full-screen loaders for primary actions.
- Disable submit and destructive actions while `isLoading == true`.
- Keep the rest of the UI interactive (e.g., the user can tap back or dismiss).

## Errors

- Field errors appear **directly beneath** the related input field.
- Use a single unified message per field (Requirements U4). Example: "Email must be a valid email address and be at most 254 characters."
- Non-field errors (server, offline) appear as a banner above the primary action.
- Clear field errors when the user edits the corresponding field.
- Map server error codes to localized strings via `ErrorLocalization.message(for:)`.

## Offline

- There is no global offline banner (`fix-offline-banner-duplication` removed it): offline is surfaced per-surface, never as a top-of-screen banner on every screen.
- Disable network-dependent submit buttons while offline.
- History pull-to-refresh shows the inline offline notice while offline; Profile shows the sync status.
- Cache the authenticated session; restore it on app launch.
- Logout must work offline by clearing the local session.

## Empty / placeholder states

- Use `EmptyState` with an SF Symbol, a headline, and a subheadline.
- Center it in the available space.
- No custom illustrations for the MVP.

## Focus management

- Focus the primary input field when a screen appears.
- Move focus to the next field with `.submitLabel(.continue)` and `.onSubmit`.
- Dismiss the keyboard when the primary action is triggered.

## Keyboard and primary input placement

When a screen’s main purpose is to collect input from a single field (email, OTP, activity name, etc.), the layout must guarantee that the focused field and the primary action button remain visible while the system keyboard is open.

### Placement rules

1. **Primary input stays above the keyboard without scrolling.**
   - Position the input field in the upper half of the screen (top-aligned content), not vertically centered.
   - On appear, focus the field immediately. The user should already see the caret and typed characters without the app needing to scroll.
2. **Primary action follows the keyboard.**
   - Place the submit / continue / primary button in a pinned bottom action bar using `.safeAreaInset(edge: .bottom)`.
   - The action bar animates with the keyboard on iOS 15+ and stays tappable above the keyboard.
3. **Reserve space for the action bar in the scrollable content.**
   - Add a bottom spacer (measured via `BottomBarHeightPreferenceKey` or fixed) equal to the action bar height plus `Theme.spacingLarge` so the scrollable content ends well above the bar.
   - This prevents the input from being obscured on short screens (e.g., iPhone SE 1st gen) when the keyboard is open.
4. **Use a `ScrollView` as a safety net.**
   - Even though the input is positioned to avoid the keyboard, wrap the form in a `ScrollView` so the user can correct any overlap caused by larger dynamic-type sizes or smaller devices.
5. **Do not rely on `Spacer()` to center the form.**
   - Centering pushes the field into the keyboard zone on short devices. Use a small top padding and fixed spacers instead.

### Anti-patterns

- Centering the form with `Spacer()` above and below the input.
- Placing the primary action button inside the scrollable content where it can be scrolled behind the keyboard.
- Forcing the user to scroll manually to see what they are typing.

## Auth flow interactions

### Return-key submit

- Email fields use `.submitLabel(.continue)` and `.onSubmit` to submit via the keyboard Return key.
- A visible primary button that performs the same action must also exist. VoiceOver / Switch Control users may never discover the Return-key shortcut.

### OTP input and auto-submit

- The OTP field is a single hidden `TextField` with `.textContentType(.oneTimeCode)`. Visual digit boxes are decorative and hidden from VoiceOver.
- The hidden field stays first responder while the OTP screen is visible so SMS AutoFill / QuickType can insert the code.
- Tapping any digit box focuses the hidden field.
- Typing, pasting, or AutoFill updates the bound code.
- Auto-submit triggers only after the code reaches the required length (6 digits), debounced by 250 ms so the user sees the complete code before the network call.
- On a verification error, clear the code and re-focus the hidden field so the user can re-type immediately. Do not force focus when VoiceOver is running.
- Do not auto-submit partial codes or on every keystroke.

### Sign Out

- Sign Out is a destructive, low-frequency account action owned by Account (Profile → Account).
- The Track toolbar and Profile do not expose Sign out as a peer to capture or sync.
- Tapping Sign Out signs the user out after one confirmation (local account files are kept; the id stays `ProfileSignOutButton`). Sign Out must work offline by clearing the local session.

### Profile destination

- The person control opens Profile for the signed-in user — sign-in is the mandatory launch gate (`RootView` renders the auth flow full-screen when signed out), so Profile is unreachable unsigned.
- Profile shows sync status ("Last synced"/"Syncing…"/error) and a manual "Sync now" action directly, plus `Account >` (`ProfileAccountRow`) and `Categories >` navigation and the version footer. There is no "Enable Sync" row or auth-flow sheet anywhere: the optional-sync presentation was removed with the mandatory gate.
- Profile owns no destructive actions: Sign out, Delete local data, and Delete account and local data live only in Account (see `SCREENS/Account.md`). "Erase local data" is renamed **Delete local data** with the move; its single-confirmation, server-untouched scope is unchanged — it deletes only the active account's local file (state + outbox + undo buffer + sync cursors) and keeps dormant account files.

### Account deletion (irreversible, online-only)

- Account → **Delete account and local data** presents exactly ONE confirmation alert (title and destructive button both name account + local data; Cancel sends nothing). No second deletion-confirmation alert exists. A native Apple authorization sheet that appears for Apple-created accounts without a stored revocable credential is authentication for the same identity, not a confirmation — dismissing it sends no request, and email-only accounts never see it.
- While a deletion submission is in flight, the destructive button shows progress (`AccountDeletionProgress`), duplicate submissions are disabled, and conflicting account actions (Sign out, Delete local data, this account's Sync now) are unavailable. An error/result notice afterward is information, never another confirmation.
- Resolution after send is status-checked, never assumed: if delivery is ambiguous, the client queries the read-only account-status capability for the original account UUID. `deleted` resumes local cleanup without another alert or login; `active` offers explicit retry through the same single-alert interaction (no automatic replay). Generic 401s, missing-user middleware rejections, expired/missing status evidence, and offline/5xx NEVER count as deletion proof — they lock with files intact.
- Versus the neighboring actions: Sign out keeps the session-clearing, file-preserving semantics behind one confirmation; Delete local data keeps its own single confirmation and removes only this account's on-device file while the relay account survives. Only confirmed permanent deletion purges the relay account (identity, sessions, entries, joins, categories, tombstones) with automatic Apple unlinking, and only independently confirmed deletion schedules the account-scoped local cleanup on other devices.
- External Apple Settings revocation is sign-out-only: it ends sessions but preserves the Lifio identity, server data, and local files, and reauthorizing the same Apple identity returns to the existing account. It is never interpreted as account deletion.

### Auth transitions

- Auth screens (Welcome → Email → OTP) are pushed on the shared `AppNavigationStack`.
- Use the system `NavigationStack` push slide. Do not add custom `.transition()` modifiers.
- iOS 18 native zoom navigation transitions are noted as future-only and require a separate decision.

## Haptics

| Action | Haptic |
|---|---|
| Start timer | `.selection` |
| Stop / save timer | `.success` |
| Validation error | `.notification(.error)` |
| Sign in success | `.success` |

Keep haptics subtle. Do not vibrate on every keystroke.

## Navigation

- Use `AppNavigationStack` for programmatic push/pop.
- Navigation renders in a `NavigationStack` + `navigationDestination(for:)`.
- Do not use `NavigationLink` directly for programmatic navigation.

## App shell (Track / History / Insights / Profile)

D1 (OpenSpec change `redesign-track-experience`). The root is a three-tab shell, not a timer-only root:

- **Track, History, Insights are the primary destinations.** Track is initially selected and is the only destination that starts or stops a timer.
- **Profile is a pushed page, not a tab.** A consistent top-trailing person control on every tab pushes it (back navigation, no Done). Profile owns account/sync, category management, integrations, export, appearance, and destructive data controls.
- **Switching destinations never changes timer state** and never discards the previous destination's state.
- **The app launches into the auth flow when signed out and into Track when signed in**; sign-in is mandatory before any Track/History/Insights use. There is no anonymous use and no optional "Enable Sync" action — the launch gate owns authentication.
- **A running timer stays globally accessible.** While running, History and Insights show the compact timer immediately above the tab bar (`.safeAreaInset(edge: .bottom)`). Its main area returns to Track; its Stop button saves in place and keeps the current destination selected. Track does not duplicate it.
- **Sign Out is owned by Account**, not the Track toolbar or Profile root. Tapping Sign Out asks once, then signs the user out (account files are kept). Sign Out must work offline by clearing the local session.
- The hierarchy maps to a future macOS sidebar without changing meaning (Track/History/Insights primary; profile-owned features secondary).

## Accessibility identifiers

- Every interactive element has a stable `accessibilityIdentifier`.
- Format: `<Screen><Element><Role>`. Examples: `EmailContinueButton`, `OtpFieldError`, `TimerStartButton`.
- Reuse identifiers across the app only when the element is truly the same.

## Undo flow (catalog deletions)

R3 / U6 / U7; decisions D17 + `unify-catalog-deletion`. Applies to entry and category deletions, all confirmed from their editing forms (entry form, category editor — no list swipes, no toasts).

- A deletion is **not** committed to the local store or pushed to sync immediately. It enters the client-side **durable undo buffer** and stays restorable until the app restarts; a cold launch commits whatever is still buffered.
- No `UndoToast` is shown. Undo is the DEFAULT system Undo confirmation only: shaking on the presenting surface shows the system prompt, and confirming restores exactly the most recent buffered deletion (registrations are cleared-then-single).
- The buffer is **superseded** by the next undoable action — only the most recent buffered deletion is restorable, including across surfaces (an entry delete followed by a category delete leaves only the category undoable, and vice versa; each surface filters snapshots by resource; older rows stay buffered until undone or the app restarts).
- On restart, commit locally (hard delete) and enqueue the `DELETE` for sync; the server hard-deletes (no trash, per `Entry_Catalog_API.md` Sync & ids).
- **Undo failure:** undo is a local transaction (no API call); on a local failure the surface keeps its last good snapshot and the buffer row is preserved for retry until the app restarts.

### Durable undo buffer (local-first)

D3 (OpenSpec change `local-first-sync-architecture`). The undo buffer is **durable** — it lives in an `undo_buffer` table in the local GRDB database, not in memory:

- There is no wall-clock undo window: a buffered deletion stays restorable until the app restarts. There is no countdown UI.
- A deletion writes the buffer row (full serialized snapshot of the deleted records) and removes the records in **one transaction**; no outbox row is created while the deletion is in the buffer, so the relay is never notified of an undone deletion.
- **A cold launch commits everything still buffered** — never while the process is alive, and there is no background timer. The commit deletes each buffer row + inserts the outbox rows in one transaction.
- The buffer **survives suspension and backgrounding**. After a restart, buffered deletions are finalized with no restore path.
- **Supersession (U7):** only the most recent buffered deletion is restorable via the system shake-to-undo; older rows stay buffered until undone or the app restarts.

### Shake-to-undo wiring (U7)

U7 says "no custom shake detection" — use the iOS system motion event. The view layer owns the binding:

- Every surface that can follow a deletion (Track, History, Manage Categories, entry form) hosts the shared passive `ShakeFirstResponderHost` (transparent, background-placed, holds first responder, handles NO motion itself) bound to its own `@Environment(\.undoManager)`.
- After a deletion lands, the surface registers the newest eligible buffer row cleared-then-single with `setActionName`, filtered by snapshot resource — so one shake+confirm restores at most one deletion, and foreign-surface rows are left for their owners.
- Do not implement custom accelerometer/gyro logic, and do not restore immediately on shake — the system prompt is the only confirmation.

### Plain-text capture (remove-activities-layer)

Track has one plain-text name field plus Recents chips. There is no search
sheet, no quick-create, and no catalog:

- **Draft vs. commit:** the field content is a temporary draft that never mutates committed history. Stopping the timer is the only commit boundary — it creates exactly one entry plus one outbox row.
- **Identity:** names are equal only as exact trimmed text (byte-exact, case-sensitive: `Gym` ≠ `GYM`). An exact match against a recent entry inherits that entry's full ordered category set at Start; otherwise the draft starts categoryless.
- **Running lock:** the name cannot be edited while running. The shared ordered tag selector stays live (select-only, zero allowed); toggles rewrite the draft snapshot only and never touch committed entries.
- **Validation:** Start is gated on trimmed non-empty text (≤ 60 chars); invalid input keeps Start disabled with localized guidance, never a blocking alert.

## Delete confirmation (F10 / U5)

Decision D18 (as superseded). The confirm pattern depends on what is being deleted.

- **Entry:** single destructive confirm naming the entry text → undo flow. There is no cascade and no scope choice.
- Destructive buttons use `role: .destructive` / `Theme.danger` tint.
- **Category:** single destructive confirm; the category's tag is removed from all entries (join cascade), entries themselves are unaffected — state this clearly in the confirm copy.

## Sync conflict (last-write-wins)

R2. Reuses the Offline sync path; do not duplicate the Offline section above.

- Every mutable request carries the client `updated_at`. The server applies the write only if `client.updated_at > server.updated_at`; otherwise it returns **409 `conflict`** with the server's current version in `details`.
- On 409 `conflict`, the client shows an inline `ErrorBanner` ("Edited on another device") and adopts the server's version as the source of truth (keep-latest). No field-level merge at MVP.
- If the user dismisses the conflict `ErrorBanner` without choosing, default to keep-latest (adopt server version) — the banner is informational, not blocking.
- On 409 `category_exists` (case-insensitive name collision on create), the client re-maps local references to the surviving id (see `Entry_Catalog_API.md` Sync & ids) and proceeds without an error.
- Idempotent `POST` (same id replayed) returns the existing record — the offline queue is safe to replay; do not surface this as an error.

### Confirmation-dialog cleanup

For destructive confirmations that use `.confirmationDialog` or `.alert`, the cancel callback attached to a `role: .cancel` button is **not** called when the user taps outside the sheet or swipes down. To avoid stale `pendingDelete` / "delete in progress" state, either:

- Observe the presentation binding (`isPresented`) in the parent ViewModel and clear pending state when it flips to `false`; or
- Provide an explicit `onDismiss` closure on the sheet/dialog and reset state there.

All manage-screen delete flows should follow this pattern consistently.

| Server response | Client action |
|---|---|
| 200/201 success | Apply locally, clear outbound queue entry |
| 404 not found (on DELETE) | Treat as success — item was already removed elsewhere; remove row locally, clear outbound queue entry |
| 409 `conflict` | `ErrorBanner`, adopt server version, keep-latest |
| 409 `category_exists` | Re-map local refs to surviving id, proceed |
| Idempotent POST (replay) | Treat as success; no error surfaced |

## Sync client (local-first)

D6 (OpenSpec change `local-first-sync-architecture`). Sync is a **session-gated transport feature**: the tracker works fully offline once signed in; the `SyncController` activates only on sign-in and deactivates on sign-out.

- **Triggers:** (1) app enters foreground, (2) connectivity restored (`.satisfied`), (3) manual "Sync now" in Profile. No background task scheduling on iOS (unreliable); macOS may add a timer-based background sync later.
- **First-sync is pull-first:** on activation, pull the relay's full state, merge server-wins on `updated_at` conflicts, then drain the local outbox. Subsequent pulls are deltas via `?modified_since=` (per-resource cursor advanced to the max `updated_at` received).
- **Outbox drain:** one HTTP call per outbox row, in `created_at` order; idempotent POST / LWW PATCH / hard DELETE make replays safe. 409 `conflict` on push → adopt the server version (keep-latest) and clear the row; 409 `category_exists` → re-map local references to the winning id and proceed without an error.
- **Status display (Profile, visible only when signed in):** "Last synced: <relative time>" or "Syncing…" (button disabled while in progress) or an error state (button stays enabled to allow retry). The manual "Sync now" action calls the same drain+pull path as the automatic triggers.
- **Sign-out preserves local data and the outbox**; an explicit "Erase local data" action in Profile wipes them (destructive, confirmed).

## Category empty states

U8. Applies to Manage Categories and the Track Recents area.

- Show `EmptyState` (`COMPONENTS.md`) when there are zero categories (e.g. after deleting all, or if seeds are declined on first run).
- Empty states guide toward creation ("Add a category") and **never block** free-text timer start — typing a name and starting always works (F4 / D20).

## Recency ordering

Timer Recents are up-to-12 exact texts computed on-device from committed entries (`GROUP BY activity_text`, newest `started_at` wins per group). No manual drag-reorder at MVP. The Manage Categories list is name-ordered.

## Text and category semantics

- An entry owns the exact text being timed plus zero or more Categories in an explicit order; all three are written at creation and owned per entry.
- A Category is optional analytics metadata; the first-position category supplies chip/row icons.
- Track Recents and the running tag selector show exact texts and icons only. Category names are omitted from capture.
- Manage Categories is a separate surface. The entry form may assign or remove Categories for one entry.
- Editing one entry never reclassifies any other entry: history is immutable except through its own entry form.

## Editor sheets and keyboard placement

D13 / D21. Applies to `LogTimeView` (CREATE sheet) and `CategoryEditor`.

- Editors are presented as full-height sheets (plain `.sheet`, no detents — closed or fully open) and shared across create + edit modes (D21).
- Inside the sheet, follow the existing **Keyboard and primary input placement** rule above, with Log Time toolbar chrome:
  - The name field is in the upper scrollable area, focused on appear (after the presentation settles).
  - The primary action is the toolbar `checkmark` (gated on a valid draft and idle state); cancellation is the toolbar `xmark`. Both dismiss paths are disabled while saving.
  - Scroll-away dismisses the keyboard (`.scrollDismissesKeyboard(.interactively)`).
- Dismiss the sheet on save success or cancel; do not leave the keyboard up after save.
