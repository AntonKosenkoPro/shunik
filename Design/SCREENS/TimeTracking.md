# Track Screen

This is the first non-auth screen described for the app. The local-first Track
experience lets the user type an exact entry text, start a timer, see exact
elapsed time, stop, and save the entry. Categories are optional per-entry
metadata attached at capture; they are not a catalog and there is no activity
entity. History never mutates retroactively.

## Use case

1. The user launches locally and lands on Track.
2. The user sees a plain-text name field, a centered numeric timer,
   and an explicit Start action.
3. The user types a name or taps a recent chip (which fills the field and
   inherits that entry's ordered categories).
4. The user taps Start; typing alone never starts timing.
5. The numeric timer counts up from `00:00`.
6. While running, the name is locked and the shared tag selector stays live
   (select-only, zero allowed); toggles rewrite the draft snapshot.
7. The user taps Stop to finish the session.
8. The app saves the elapsed entry locally (single create + single outbox row)
   and syncs it when online.

## Screen: TrackView

- **File**: `ios/TimeOfLife/TimeOfLife/Features/TimeTracking/Views/TrackView.swift`
- **Route**: Track tab in the app shell
- **ViewModel**: `TrackViewModel`

### Layout

Wrap the screen in the app shell's navigation container. Content is a
scrollable column with horizontal `Theme.spacingLarge` padding and a dual-flow
vertical composition; the adaptive spacers collapse to zero before scrolling
engages.

Top-to-bottom order:

1. Navigation title: `L10n.tabTrack` (`Track`), `.inline` display mode (per-tab stack owns the chrome).
2. Top adaptive spacer (see adaptive spacing below).
3. Completion-mark region: the saved-state confirmation appears here, above
   the readout, without moving the timer content.
4. Numeric timer readout:
   - Elapsed time formatted as `MM:SS` or `H:MM:SS`.
   - Centered in the main content region.
    - Font: `Theme.timerFont()` — `.system(size: 64, weight: .semibold, design: .rounded)`.
   - Uses `Theme.textPrimary` and `.monospacedDigit()`.
   - Keeps a stable frame across all timer states.
   - `accessibilityIdentifier`: `TimerDisplay`.
5. State label below the readout:
   - `READY`, `RUNNING`, `SAVING`, or `SAVED` as appropriate.
   - The exact elapsed value remains the primary state information.
6. Reserved non-field-error region, immediately above the central separator:
   - Preserves its reserved height when no error is shown, without exposing
     an empty accessibility element.
   - Error text wraps fully and is never cut: when the wrapped error is taller
     than the reservation, the region grows and the flexible spacing yields
     first.
   - `accessibilityIdentifier`: `TrackErrorBanner`.
7. Central separator: receives free space beyond twice the shared cap (see
   adaptive spacing below).
8. Name control (idle/ready/saved) or locked name label (running/saving/
    error): idle shows the name push row (`TimerNameRow`, `accessibilityIdentifier("TimerNameRow")`) opening the shared `NamePicker` page (see `SCREENS/NamePicker.md`) — there is no inline text field on Track (dedicated-name-picker; issue #69 keeps Start uncovered with no floating layer). The running label (`TimerNameLabel`) is non-editable
    after Start. No state renders more than one preparation control.
    - No control shows a Category name.
    - No editing affordance for past entries: history is corrected from the
      entry form; editing placement on Track is deferred to a later change.
9. State-specific main action in one stable region:
   - `L10n.timerStart` with `play.fill` when ready, identifier
     `TimerStartButton`.
   - `L10n.timerStop` with `stop.fill` when running, identifier
     `TimerStopButton`.
   - Stop hint: `L10n.timerStopHint` - stops the timer and saves the entry.
   - The region changes between these controls without moving; it sits above
     the tags/Recents slot so Start / Stop stays reachable without
     scrolling.
    - The action renders in a fixed-height slot equal to the tallest of its
      state titles (name prompt / Start / Stop) at the active Dynamic
      Type size, so the control's frame is identical in idle, ready, running,
      saving, saved, and error states.
    - The swap itself never animates: no fade, slide, or spring of its own —
      the incoming control appears in place.
10. Tags / Recents slot below the button: Recents while idle, the shared
    ordered `TagSelector` (select-only, zero allowed) while running (see
    Recents below). Both branches stay mounted and the inactive one hides
    via opacity, so the slot keeps the taller branch's height in every
    state — the field and the button above never move on state switch.
11. Bottom adaptive spacer (see adaptive spacing below).
12. Tab bar.

Adaptive spacing:

- The top and bottom spacers share one maximum-height token: **48 pt**,
  selected from the 24/48/72/96 Pro Max spike comparison and validated on
  iPhone SE (default and Large Dynamic Type).
- With free space `slack = viewport - content`, each spacer resolves to
  `min(cap, slack / 2)` — the two are always equal.
- Surplus beyond twice the cap goes to the central separator between the
  error region and the search/refine flow.
- When space is constrained (short screens, large Dynamic Type), all three
  flexible regions collapse to zero and the ordered content scrolls.
- Main-action pinning (D10): the content height around the main action is
  state-invariant (fixed-height action slot; both below-button branches
  mounted so the slot keeps the taller branch's height), so the equal
  split recomputes identically in every state. A wrapped error's growth beyond the reserved
  error height compresses the top spacer first, then the central separator —
  both above the main action, keeping it stationary — and the bottom spacer
  collapses only when both are exhausted, at which point the content
  scrolls.

The Track screen has no Dial, ring, sweep, goal, daily-total, or decorative
progress visualization.

### Recents

- Wrapping chip flow of the most-recently-used exact texts, capped at twelve,
  newest `started_at` first (`GROUP BY activity_text` over committed entries,
  `id DESC` tiebreak); no horizontal scrolling. The chips live in an adaptive
  viewport (hug content, clamp at up to 4 rows of available height with
  1 pt top/bottom scroll-content padding plus matching +2 pt max cap,
  internal scroll, shared `ChipViewport` contract), so small sets stay
  compact, short viewports show fewer rows with internal scroll, and overflow
  never grows the Track page or slides under the tab bar. Entire-page scroll
  engages only as an accessibility fallback. Edge-aware hairline dividers fade in/out with the scroll
  position (`ChipViewport` contract, shared with the tag selector); no
  constant caption divider.
- Each chip shows the icon of the first-position Category (first by the stored
  order) in a fixed symbol slot; categoryless entries render name-only
  chips with no icon and no placeholder glyph. Category names are never shown.
- The prepared text's chip uses a filled accent presentation (accent
  background, on-accent text, accent border) and keeps its icon; no checkmark.
- Minimum 44 pt tap targets; a tap fills the field (ready state) and inherits
  that entry's full ordered category set. Tapping never starts timing.
- Recents yield the below-button slot to the running tag selector while a
  timer is running (opacity-hidden, height preserved via the mounted
  taller branch), so the main action does not move.
- Empty store: a dedicated localized hint (`timer.recentsEmptyHint`,
  "Texts you track will appear here." / «Здесь появятся названия,
  которые вы отслеживаете.»), inviting free-text start.

### Plain-text capture (dedicated picker, no search sheet)

There is no search sheet, no quick-create, and no catalog. Capture is the
name push row plus the dedicated picker page (see `SCREENS/NamePicker.md`):

- Empty field: typing any name is valid; Start is disabled until the trimmed
  text is non-empty (≤ 60 chars).
- Exact match against a recent entry (byte-exact trimmed text,
  case-sensitive): starting inherits that entry's full ordered category set;
  otherwise the draft starts with no categories.
- The field content is a temporary draft: it never changes committed history.
  Stopping is the only commit boundary — it creates the entry and dismisses
  nothing (the same text stays prepared).
- The running name is locked: it cannot be edited until Stop, and it renders
  leading-aligned like the idle field. A `Divider` separates the Categories
  caption from the tag chips. Category
  toggles while running rewrite the draft snapshot only. A standalone notes
  button sits outside the locked-name row (its tint signals whether the
  draft holds notes); mid-run notes saves rewrite the draft notes snapshot
  only, and Stop commits the entry with the final notes.

### Text and Category relationship

- **Text** is the exact identity being timed and is required for an entry.
- **Category** is optional per-entry metadata; an entry may have zero or more
  Categories in an explicit order.
- Manage Categories is a separate surface (Profile).
- The entry form may assign or remove Categories for one entry.
- Category assignment is not required to start a timer.
- Entries own their text, ordered categories, and notes at write time.
  Editing one entry never reclassifies any other entry or Insights history.

### Keyboard handling

Track keeps no inline text field — the capture field lives on the pushed
`NamePicker` page. The picker field follows `Design/INTERACTIONS.md` -> **Keyboard and primary
input placement**: it stays above the keyboard while focused; there is no
Save action on Track (Stop commits).

A focused Start tap resigns the field first: the haptic fires and
`startedAt` is captured at tap time, but the running swap waits for the
keyboard to actually finish dismissing (real `didHide`, bounded fallback
for hardware keyboards) before cutting to Stop in place. Swapping inside
the dismissal slide is what made Stop bubble up with the moving layout.
Any field edit or chip tap before the swap fires cancels the deferred
start, so a stale draft can never start.

### Layout stability rule

- The numeric readout, state-specific preparation control, and main action
  keep their interaction regions across idle, ready, running, saving, and
  saved states.
- The main-action control's frame is identical in every state: the action
  renders in a fixed-height slot, both below-button branches stay mounted
  so the slot never changes height, and wrapped-error growth yields from
  the top spacer before the central separator.
- Only the prepared text, readout value, label, button title/icon, and tint
  change.
- No dial, ring, or progress card appears or disappears around the readout.
- The main action remains visible above the tab bar; adaptive spacing yields
  before any content clips, overlaps, or becomes unreachable.

### Behaviors

- Open capture from the plain-text field or a Recents chip above
  Recents.
- Selecting a recent text fills the field and inherits its ordered categories
  without creating an entry.
- Typing a new name prepares a categoryless draft.
- Start validates trimmed non-empty text; an exact recent match inherits
  categories at start time.
- Start persists the running timer immediately, begins periodic readout refresh,
  emits selection feedback, and keeps the screen awake.
- Returning to Track (tab switch back, navigating back from Profile) reloads
  recents and categories — including seeding the starter set first on a
  fresh install — so History edits and new categories are inherited and
  chip icons stay current.
- Stop calculates elapsed time, saves the entry locally, emits success feedback,
  and returns to the ready state for the same text.
- Save errors preserve recoverable running state and appear in the reserved
  non-field-error region without a blocking loader; error text wraps fully and
  is never cut.
- A running timer remains visible above the tab bar on History and Insights;
  its Stop action saves in place.
- Profile owns sign-out and account/sync controls rather than the Track toolbar.
- Dynamic Type keeps the readout, entry text, and Start/Stop action readable;
  the adaptive spacers and central separator collapse before any content is
  clipped or unreachable.
- Reduce Motion uses fades or immediate state changes rather than custom motion.

### States

| State | Visual |
|---|---|
| Idle | No text entered; centered readout shows `00:00`; name prompt and Start are shown or Start is disabled according to validation policy. |
| Ready | Prepared text shown; centered readout shows `00:00`; Start button shown. |
| Search active | (Removed — no search sheet. Capture is the plain-text field plus Recents chips.) |
| Running | Locked name label remains visible; readout updates live; Stop button shown with destructive tint; Recents yield the below-button slot to the running tag selector. |
| Saving | Readout remains stable; Stop action shows progress while the save completes. |
| Saved | Brief saved confirmation in the completion-mark region above the readout; the same text remains prepared with `00:00` and Start, and the timer stays in its prior position. |
| Error | Localized non-field error in the reserved region above the central separator; text wraps fully and the region grows past the reservation when needed, with the top spacer yielding first and then the central separator so the main action stays stationary; recoverable running state is preserved. |

### Data model

```swift
struct TimeEntry: Identifiable, Codable, Sendable {
    let id: UUID
    var activityText: String       // exact trimmed identity; Gym ≠ GYM
    var categoryIDs: [String]      // ordered, first position supplies icons
    var notes: String
    let startedAt: Date
    let endedAt: Date?
    var duration: TimeInterval { endedAt.map { $0.timeIntervalSince(startedAt) } ?? 0 }
    var source: String
    var sourceRef: String?
}
```

Text, ordered categories, and notes are denormalized onto the entry at write
time; there is no activity record and nothing is resolved at query time.
There is no `synced` flag on the model: sync is outbox-driven (every mutation
writes a transactional outbox row; the relay is the transport, not a
per-record state).

### Implementation checklist

- [ ] All colors use `Theme.*` tokens.
- [ ] All strings use `L10n.*` keys in English and Russian.
- [ ] Name field, tag selector, readout, and Start/Stop controls have stable identifiers.
- [ ] Numeric readout is centered, fixed, and `.monospacedDigit()`.
- [ ] Recents chips expose exact texts only.
- [ ] Recents chips show the first-position Category's icon only; no names.
- [ ] Start follows explicit selection and persists running state.
- [ ] Stop saves locally and preserves recoverable state on failure.
- [ ] Compact timer is available above History and Insights navigation.
- [x] VoiceOver, Dynamic Type, Reduce Motion, light/dark, and iOS 18 are tested.
- [ ] SwiftLint and warning-as-error builds pass.

## Localization keys

Add English and Russian values, then add corresponding `L10n` cases:

```text
"timer.title" = "Track";
"timer.idlePrompt" = "What are you doing?";
"timer.namePlaceholder" = "What did you work on?";
"timer.start" = "Start";
"timer.stop" = "Stop";
"timer.stopHint" = "Stops the timer and saves the entry";
"timer.saved" = "Saved";
"timer.recentsEmptyHint" = "Texts you track will appear here.";
```

## Capture behavior

Recents are computed on-device from committed entries and ranked by newest
`started_at` per exact text, capped at twelve. Each chip contains the exact
text and, when the entry has Categories, the icon of the first-position
Category — never a Category name. Category icons belong in Manage
Categories, the entry form, and Insights; on Track they
appear only in Recents chips. The name field and the running tag selector
remain category-name-free.

There is no quick-create and no catalog: typing a new name and starting
bakes the text (categoryless unless an exact recent match inherits its
ordered set), and never forces the user into category management.

Manage Categories is a separate destination. It remains available offline
and uses the existing sync-conflict and undo-until-restart rules.
