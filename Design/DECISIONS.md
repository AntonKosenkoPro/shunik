# Design Decisions

Resolved design precedents for Lifio. Add a new entry here when a visual or interaction decision has project-wide impact.

## D1 — Minimalistic, native iOS design

- Use SwiftUI system components and SF Symbols.
- No custom typefaces or illustrations for the MVP.
- Reason: matches `Requirements/FURPS/Common.md` U1, U2, U5, and S2 (native UI SDK).

## D2 — Passwordless auth

- No password fields, no "forgot password" screens.
- The email-OTP flow handles sign-up, sign-in, and access restoration.
- Reason: security requirement R1; eliminates an entire class of UI and state.

## D3 — Semantic color tokens

- All colors are referenced via `Theme.*` and resolved from `Assets.xcassets` color sets.
- No raw `Color(...)` literals in views.
- Reason: dark/light support U2 and deterministic agent implementation.

## D4 — Localized keys, not raw text

- Every user-facing string is referenced via `L10n` and present in both EN and RU.
- Server error codes map to `error.<code>` keys.
- Reason: localization requirement U4 and test parity (`LocalizationTests`).

## D5 — Text-based design specs

- The design system is Markdown in `Design/` rather than Figma or other external tools.
- SwiftUI Previews are the visual validation loop.
- Reason: easy to create and change; lives under version control; deterministic for AI agents.

## D6 — Accessibility identifiers

- Every interactive element gets a stable `accessibilityIdentifier`.
- Reason: supports UI tests and agent verification; aligns with Apple HIG U5.

## D7 — Offline-first where possible

- Auth session is cached; logout works offline.
- Time entries are saved locally and synced when online.
- Reason: `Requirements/FURPS/Common.md` U3.

## D8 — Sign in with Apple as the primary auth method

- The welcome screen leads with the native Apple sign-in button. Email/OTP is a secondary option reached via a plain text button.
- Reason: user request; Apple HIG recommends making Sign in with Apple prominent and avoiding excessive alternatives.

## D9 — Welcome screen as the auth-flow root

- The first signed-out screen shows the app name and a short tagline before asking for credentials.
- Reason: explains value; aligns with Apple HIG guidance to delay sign-in as long as possible.

## D10 — One-box-per-digit OTP via a single hidden TextField

- Decorative styled boxes give the “one digit per box” visual pattern, but the real responder is a single hidden `TextField` with `.textContentType(.oneTimeCode)`.
- Reason: supports typing, paste, and SMS AutoFill while avoiding a custom text engine. Visual boxes are hidden from VoiceOver; the group is exposed as one accessible element.

## D11 — Return-key and visible button coexist

- Email submission works via the keyboard Return key and via a visible Continue button. Both trigger the same action.
- Reason: Return key is a convenience for sighted users; the visible button is required for VoiceOver and Switch Control workflows.

## D12 — Sign Out lives in Profile

- Sign Out is a destructive, low-frequency account action owned by the Profile destination (D30), not the Track toolbar. Tapping Sign Out signs the user out with no confirmation (local account files are kept; only the session is cleared) and works offline.
- Reason: user request; keeps the low-frequency account action out of the primary time-tracking controls. Supersedes the interim TimerView toolbar placement.

## D13 — Primary input and action stay above the keyboard

- Screens built around a single text input place the field in the upper portion of the scrollable content, not vertically centered, so the field remains visible when the keyboard opens. The primary action is pinned to `.safeAreaInset(edge: .bottom)` so it follows the keyboard and stays tappable without dismissing the keyboard first.
- Reason: guarantees the user can see what they type and reach the submit/continue button on every device, especially short screens like iPhone SE.

## D14 — Auto-submit only on OTP screen

- The `OtpEntryView` submits automatically once the 6-digit code is entered, debounced by 250 ms. There is no visible Verify button because the number pad has no Return key and the screen’s sole purpose is the single OTP field.
- Reason: the one-box-per-digit field already has a clear completion point (6 digits); adding a Verify button would duplicate the action without improving accessibility, since the field is exposed as a single editable accessibility element and AutoFill/paste work through the hidden `TextField`.
- Guard: keep the field focused after verification errors and ensure the component exposes the `.isTextField` trait so assistive tech recognizes it as editable.

## D15 — Retired: fixed activity/category color palette

- Superseded by the activity/category model reconciliation: activities no longer carry color or icon, categories carry a validated catalog icon, and the palette plus `Theme.activityColor(_:)` resolver are removed.

## D16 — On-device recency from committed entries

- Timer Recents are up-to-12 exact entry texts computed on-device from committed entries (`GROUP BY activity_text`, newest `started_at` wins per group); there is no suggestions endpoint. Works fully offline.
- Capture shows exact texts only; the Recents chip flow is the single exception — each chip shows the icon of the first-position Category (icon-only, never names), and categoryless texts render name-only chips. The running tag selector stays category-name-free.
- Reason: F5/P1 — the client already holds the synced store, so a server round-trip would buy nothing and break offline; the text IS the identity (exact, case-sensitive).

## D17 — Durable undo buffer, system prompt only

- Deletions enter the client-side durable undo buffer (`undo_buffer` table) and stay restorable until the app restarts — no wall-clock window, no countdown UI, no toast. A cold launch commits whatever is still buffered (never while the process is alive); no background timer. Only the most recent buffered deletion is restorable via the DEFAULT system Undo confirmation (shake → prompt → confirm); older rows stay buffered until undone or the app restarts (supersession). No outbox row is created while a deletion is buffered.
- Reason: R3/U6/U7 — undoable deletion without server-side trash (`unify-catalog-deletion`); keeps destructive actions reversible for the common "oops" case while staying simple.

## D18 — Delete-scope confirmation for activities with history

- Deleting an activity that has past entries shows a destructive two-option confirm naming the affected entry count: delete the entire activity (+ all entries) vs. delete only the current entry. Both choices are destructive and enter the undo flow as a unit.
- Reason: F10/U5 — the user must understand the scope before losing history; the prompt names the count so the choice is informed.
- **Superseded by `remove-activities-layer`**: there are no activities, so there is no cascade and no scope choice. Deleting an entry from its entry form shows a single destructive confirm naming the entry text (F10/U5).

## D19 — Recency ordering, no manual reorder at MVP

- Manage Activities and timer suggestions are ordered by `last_used_at` (most-recent first). No drag-to-reorder at MVP.
- Reason: F8 — manual reorder adds complexity for little value now; recency is the cheapest useful default.
- **Superseded by `remove-activities-layer`**: there is no Manage Activities screen. Recents are up-to-12 exact texts computed on-device from entries (`GROUP BY activity_text`, newest `started_at` wins); categories are name-ordered.

## D20 — Free-text start stays first-class

- Typing a name and starting the timer still works in one step; if the name matches an existing activity (case-insensitive, trimmed) it is reused, otherwise a new activity is auto-created with no categories and linked to the entry. The user is never forced into the catalog to start a timer.
- Reason: F4 — forcing categorization would add friction and fight the app's minimal-effort premise; auto-create keeps the free-text flow frictionless while still giving every entry an `activity_id`.
- **Superseded by `remove-activities-layer`**: there is no activity to reuse or auto-create. Typing a name and starting still works in one step; an exact match against recent entries inherits that entry's ordered categories, otherwise the draft starts categoryless. The text IS the identity (exact, case-sensitive).

## D21 — Editors as sheets, shared create/edit modes

- `ActivityEditor` and `CategoryEditor` are presented as sheets, each with create + edit modes, reused by the timer (quick-add, F7) and the Manage screens (F8). Keyboard placement follows D13.
- Reason: one editor component per entity avoids duplicate surfaces; sheets keep the user in context (timer / manage list) without a full navigation push.
- **Partially superseded by `remove-activities-layer`**: `ActivityEditor` is deleted with the activities layer. `CategoryEditor` remains a create/edit sheet; the entry form (`LogTimeView`) is a sheet for CREATE and a navigation push for EDIT/LOCKED (pushed by `fix-entry-form-gestures` so the edge-back gesture works — a full-screen cover has no back stack).

## D22 — Categories have catalog icons

- Categories carry one icon from the validated `CatalogIcon` set, defaulting to `tag`; category icons are used in category rows, selectors, Activity management, and Insights representations, but not in capture suggestions.
- This reverses the earlier “categories do not have icons” correction in `ManageCategories.md` and supersedes the retired color-palette decision (D15).

## D23 — Centered numeric timer

- Track uses a centered numeric readout for the exact elapsed duration. It has no Dial, ring, sweep, goal, daily-total, or decorative progress visualization.
- Reason: the user rejected the Dial and chose a numbers-only treatment; exact elapsed time is sufficient for capture while History and Insights own retrospective meaning.

## D24 — Categories are current Activity metadata

- Activities are concrete tasks required for timing. Categories are optional zero-or-more analytics metadata managed separately from capture. Entries resolve an Activity's current Categories at query time, so editing an Activity's Categories reclassifies its existing history.
- Reason: the current Activity/category API and entry model already use `activity_id` plus query-time tag resolution, and this keeps categoryless quick creation valid.
- **Superseded by `remove-activities-layer`**: there are no activities. Entries own their trimmed text, ordered categories, and notes at write time; history never mutates retroactively. Categories remain optional zero-or-more per-entry metadata.

## D25 — Track, History, and Insights are the primary destinations

- The root is a three-tab shell (Track initially selected). Profile is opened from a consistent top-trailing person control and is not a fourth tab.
- Reason: capture, retrospective review, and interpretation are durable intents with different frequencies; a tab per intent keeps History discoverable and maps directly to a future macOS sidebar. Profile holds low-frequency configuration and optional account state, so a tab would overstate its importance.

## D26 — The numeric timer is a pure start instrument

- Track uses a centered numeric readout with no dial, ring, sweep, daily-total, goal, or decorative progress visualization. The readout carries the exact elapsed time, including hours, and stays in the same central region across ready, running, saving, and saved states.
- Reason: the user rejected the Dial and chose a centered numeric treatment; exact numbers are sufficient for capture, while History and Insights own retrospective meaning.

## D27 — Activity selection is a native sheet

- Tapping the selected Activity affordance opens a searchable sheet: recent names before search, case-insensitive matches while typing, `Create "Name"` for valid unmatched input, and Manage Activities as a secondary destination. Category names and icons are not shown. Selecting or creating prepares the Activity and dismisses the sheet.
- Reason: the main screen stays calm and numeric while the sheet handles a potentially large catalog with familiar search and keyboard behavior; Categories are optional analytics metadata and must not compete with the concrete task being selected.
- **Superseded by `remove-activities-layer`**: the search sheet is deleted. Capture is a plain-text field plus up-to-12 Recents chips (exact texts with first-position category icons); tapping a chip fills the field and inherits that entry's ordered categories.

## D28 — Start is explicit and Stop is spatially stable

- Selection enters a ready state; a separate Start action begins timing. The same central/lower control region changes from Start to Stop without moving. After Stop succeeds, a restrained saved confirmation appears and the same Activity remains prepared.
- Reason: explicit Start is predictable across recents, search, and creation; stable geometry supports muscle memory; retaining selection makes repeated sessions quick while still requiring explicit confirmation.
- Note (`remove-activities-layer`): "Activity" now means the prepared exact text. After Stop the same text stays prepared; running locks the name while the shared tag selector stays live (select-only).

## D29 — A compact timer is inset above non-Track tabs

- While running, History and Insights show a compact timer immediately above the tab bar. Its main area returns to Track; a separate Stop button saves in place. Track does not duplicate it.
- Reason: a running timer is global app state and must not disappear on navigation; a bottom safe-area inset stays close to primary navigation, avoids covering content, and creates a visual grammar reusable by widgets and Live Activities.

## D30 — Profile is signed-in-only

- The person control opens Profile for the signed-in user — sign-in is the mandatory launch gate (`RootView` renders the auth flow full-screen when signed out), so Profile is unreachable unsigned and there is no "Enable Sync" row or auth-flow sheet anywhere. Its account section shows sync status plus "Sync now" and sign-out; Library holds Manage Categories; App holds the per-account Erase local data (active file only).
- Reason: account-bound local-first (account-bound-local-data) — one destination for low-frequency configuration and account state; a tab would overstate its importance.

## D31 — Motion and haptics explain state rather than decorate it

- Start uses a subtle selection haptic, Stop/save uses success feedback, and invalid input uses error feedback. State transitions remain restrained; Reduce Motion replaces rotational/spring transitions with fades or immediate updates.
- Reason: physical feedback marks consequential state changes without making routine navigation noisy; motion must clarify readiness, running, and saved state and remain optional.

## D32 — Profile-owned category management (signed-in-only)

- Categories are managed from Profile for the signed-in user (the launch gate precedes every tab). The list is name-ordered and editable offline; assignment to entries is optional and ordered.
- Category deletion is tag-only and uses the durable undo buffer (system prompt only, no toast, no countdown). This does not claim that bulk-delete UX is complete.
- Reason: local-first capture must not depend on network state, while a dedicated Profile surface keeps capture uncluttered and gives category deletion an explicit, recoverable boundary.

## D33 — Editor sheets use one native collapsing-header scaffold

- Category and future editor sheets use `EditorSheetScaffold` (`ActivityEditor` was deleted with the activities layer): a native large navigation title with Cancel floating at rest, collapsing into the material navigation bar beside Cancel on scroll and expanding again at the top edge. The scaffold also owns the standard scroll container and keyboard-safe pinned action bar. The unified entry form (`LogTimeView`) is a full-height sheet for CREATE and a navigation push for EDIT/LOCKED (see `SCREENS/EntryForm.md`).
- Reason: the previous custom title scrolled under an otherwise empty Cancel bar. The system large-title mechanism removes that overlap without custom header geometry or appearance code, while one scaffold keeps all present and future editors consistent. See `openspec/changes/archive/2026-08-13-collapsing-editor-sheet-headers/design.md`.

## D34 — Track uses a dual-flow adaptive layout with a 48 pt spacer cap and no editing affordance

- Track is one vertical composition in this order: navigation title → top adaptive spacer → completion-mark region → timer numbers → timer status → reserved non-field-error region → central separator → name push row → state-specific main action → Recents / running tag selector → bottom adaptive spacer → tab bar.
- The top and bottom spacers share one maximum-height token — **48 pt**, selected by the user from the 24/48/72/96 Pro Max spike comparison and validated on iPhone SE (default and Large Dynamic Type). With positive free space (`slack = viewport - content`) each spacer resolves to `min(cap, slack / 2)`, so the ends are always equal; surplus beyond twice the cap goes to the central separator between the error region and the search/refine flow. Under constraint all three flexible regions collapse to zero and the ordered content scrolls. The main action sits above Recents so Choose Activity / Start / Stop stays reachable without scrolling. The reserved error region preserves geometry when empty (no empty accessibility element), wraps error text fully, and grows past the reservation with the flexible spacing yielding first. The local-first Track screen shows no offline hint.
- The Track editing affordance is removed — the former beside-picker Refine and the interim "Edit activity" variant are gone; its placement is deferred to a later change (the editor sheet machinery remains in `TrackViewModel`).
- Reason: equal capped ends give the composition a symmetric rhythm (the timer stack hangs from the top, the control stack from the bottom), the central separator makes the cap visible on roomy screens, and a zero minimum ensures spacing disappears before controls overlap or become unreachable on short screens or under accessibility text sizes. The user rejected a pinned `.safeAreaInset` action bar, fixed padding, bottom-first surplus distribution, and a main action below Recents during the SE spike.
