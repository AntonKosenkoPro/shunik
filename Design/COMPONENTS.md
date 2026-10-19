# Component Library

This file defines reusable component contracts. Implementations may live under `Core/Design/Components/` or beside the feature that owns them; contracts for deferred surfaces may not have an implementation yet.

> **Rule:** prefer reusing an existing component over creating a new view. If a new component is needed, add it here first.

---

## `EditorSheetScaffold`

Shared presentation shell for editor sheets. It owns the native collapsing large-title navigation header, localized Cancel action, standard scroll-content width and padding, measured bottom-bar reserve, keyboard-safe pinned action bar, loading-time dismissal lock, and optional iOS 16+ medium/large detents. Editor-specific fields, focus state, validation, and save behavior remain in the feature view.

### Signature

```swift
struct EditorSheetScaffold<Content: View, BottomBar: View>: View {
    init(
        title: String,
        cancelTitle: String,
        isLoading: Bool,
        cancelAccessibilityId: String,
        usesMediumDetent: Bool,
        onCancel: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder bottomBar: () -> BottomBar
    )
}
```

### Use

- Use for entry, Category, and future editor sheets that combine scrollable fields with a pinned primary action.
- Supply existing localized title/Cancel strings and a stable Cancel accessibility identifier.
- Keep `@FocusState`, dismiss-on-save observation, validation, and field sections in the calling editor.
- Do not recreate the header with a custom title inside scroll content, scroll-offset tracking, top overlays, or `UINavigationBarAppearance` overrides.

---

## `PrimaryButton`

Full-width prominent action button.

### Signature

```swift
struct PrimaryButton: View {
    let title: String
    let icon: String?
    let isLoading: Bool
    let isDisabled: Bool
    let accessibilityId: String
    let tint: Color? // default nil → Theme.accentPrimary
    let action: () -> Void
}
```

### States

| State | Visual |
|---|---|
| Default | Fixed 54pt filled rectangle, `Theme.cornerRadius` continuous corners, filled with `tint ?? Theme.accentPrimary` |
| Loading | `ProgressView()` with white tint centered in the button; keeps full width; fill dimmed to 50% alpha |
| Disabled | `disabled(isLoading \|\| isDisabled)`; fill dimmed to 50% alpha |
| Error | No change; errors are shown near the related field, not the button |

### Requirements

- Title uses `.body.bold()`.
- Frame is `maxWidth: .infinity`, fixed height `54` — matches `AppleSignInButton` geometry.
- Fill is `tint ?? Theme.accentPrimary`; dimmed via `Theme.color(fill, alpha: 0.5)` while loading or disabled.
- Corners are a continuous `RoundedRectangle` with `Theme.cornerRadius`.
- Do NOT use `.borderedProminent`/`.controlSize(.large)` — the system prominent style renders as a floating liquid-glass capsule on iOS 27 and breaks shape parity and keyboard tracking.

### Usage

```swift
PrimaryButton(
    title: L10n.emailEntrySubmit.text,
    icon: nil,
    isLoading: vm.isLoading,
    isDisabled: vm.email.trimmingCharacters(in: .whitespaces).isEmpty,
    accessibilityId: "EmailContinueButton"
) {
    Task { await vm.submit() }
}
```

---

## `TextFieldWithError`

A labeled text field with a single unified error label below it.

### Signature

```swift
struct TextFieldWithError: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let error: String?
    let keyboardType: UIKeyboardType
    let textContentType: UITextContentType?
    let submitLabel: SubmitLabel
    let autocapitalization: UITextAutocapitalizationType
    let accessibilityId: String
    let onSubmit: () -> Void
    let focused: FocusState<Bool>.Binding // bound to the inner field
    var showClear: Bool // + onClear / clearAccessibilityId / clearAccessibilityLabel
}
```

### States

| State | Visual |
|---|---|
| Default | `Theme.backgroundSecondary` fill, `Theme.hairline` border |
| Error | Same fill, `Theme.danger` border and error text |
| Focus | System focus ring; no custom border change |

### Requirements

- Label appears above the field using `Theme.textSecondary` and `.caption`.
- Field uses `Theme.backgroundSecondary`, `.cornerRadius(Theme.cornerRadius)`, horizontal padding `Theme.spacingMedium` (compact ~44 pt card, NamePicker parity).
- Border is a 1 pt `RoundedRectangle` stroke: `Theme.hairline` normally, `Theme.danger` when `error != nil`.
- Error label uses `.caption` and `Theme.danger`, with `accessibilityIdentifier("<accessibilityId>Error")`.
- Clear error when `text` changes.
- The text input carries `minHeight Theme.minTapArea` (44 pt), so the opt-in trailing clear button never changes row height.
- Focus binds to the inner field via the `focused` parameter; callers must not attach `.focused` to the component itself.

### Usage

```swift
TextFieldWithError(
    title: L10n.emailEntryEmail.text,
    placeholder: L10n.emailEntryEmail.text,
    text: $vm.email,
    error: vm.fieldErrors.email,
    keyboardType: .emailAddress,
    textContentType: .emailAddress,
    submitLabel: .continue,
    autocapitalization: .none,
    accessibilityId: "EmailField",
    onSubmit: { Task { await vm.submit() } }
)
```

---

## `OtpCodeField`

One styled input box per digit, backed by a single hidden `TextField` so paste, SMS AutoFill, and typing work as one continuous code.

### Signature

```swift
struct OtpCodeField: View {
    @Binding var code: String
    var length: Int = 6
    let error: String?
    let isLoading: Bool
    let accessibilityId: String

    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
}
```

### Visual

- `ZStack`:
  - Hidden `TextField("", text: $code)`:
    - `.keyboardType(.numberPad)`
    - `.textContentType(.oneTimeCode)` for SMS AutoFill / QuickType
    - `.autocorrectionDisabled()`, `.textInputAutocapitalization(.never)`
    - `opacity(0)` and `.accessibilityHidden(true)` so only the boxes are visible
  - `HStack(spacing: Theme.spacingSmall)` with `length` boxes (default 6).
- Each box:
  - Size `44 × 56 pt` (minimum tap area 44 pt).
  - Background fill `Theme.backgroundSecondary` inside a `RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)` so the background matches the border shape and no square corners stick out.
  - Border 1 pt `RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)` stroke: `Theme.hairline` normally, `Theme.accentPrimary` on the active box while focused, `Theme.danger` when `error != nil`.
  - Digit shown in `Theme.textPrimary`, `.title2.monospacedDigit()` when filled; empty boxes are blank (no placeholder).
- The active box index is `min(code.count, length - 1)` while focused, else `-1` (no box highlighted).
- The whole group is horizontally centered.

### States

| State | Visual |
|---|---|
| Empty | Boxes blank; active box (index 0) has accent border while focused |
| Partial | Filled boxes show digits; remaining boxes blank; active box has accent border |
| Complete | All boxes filled; active box (last) has accent border |
| Error | All boxes use `Theme.danger` border; error text appears below the component |
| Loading | The hidden field is disabled; the parent shows loading via the primary action |

### Behavior

- The component focuses itself on appear (`.onAppear { isFocused = true }`). It owns its `@FocusState` internally and never needs an external focus binding; do not dismiss focus elsewhere.
- Tapping any box focuses the hidden field.
- Typing appends digits to `code`; focus management is irrelevant because there is only one real responder.
- `onChange(of: code)` sanitizes the value to digits only and truncates to `length`, writing back only when different to avoid feedback loops.
- Pasting a multi-character string fills as many boxes as possible from the start, truncated to `length`.
- Backspace removes the last digit.
- Auto-submit is the parent screen’s responsibility; the component only exposes the bound `code`.
- Clear `error` when `code` changes (parent logic).

### Accessibility

- Group the boxes into a single accessible element:
  - `.accessibilityElement(children: .combine)`
  - `.accessibilityLabel("One-time code, \(length) digits")`
  - `.accessibilityValue(code)`
  - `.accessibilityIdentifier(accessibilityId)`
- Hide individual visual boxes from VoiceOver with `.accessibilityHidden(true)`.
- The component focuses itself on appear via its own `@FocusState`; no external focus binding is needed. Do not force-focus while VoiceOver is running — do not fight the screen reader.

### Usage

```swift
OtpCodeField(
    code: $vm.code,
    length: 6,
    error: vm.fieldErrors.otp,
    isLoading: vm.isLoading,
    accessibilityId: "OtpCodeField"
)
```

### Notes

- If `length` exceeds 6, wrap the box row in a horizontal `ScrollView` so it does not clip on narrow screens.
- The component must not implement its own text engine, custom touch handling, or custom caret. The hidden `TextField` owns all text input.

---

## `OfflineBanner` (removed)

> **Removed** by `fix-offline-banner-duplication`: there is no global offline banner. Offline surfaces via the History pull-to-refresh inline notice and the Profile sync status; auth submit actions disable offline with `error.offline`. No component, no `L10n.offlineBanner` key, no call sites.

---

## `ErrorBanner`

Centered inline error message used when the error is not tied to a specific field.

### Signature

```swift
struct ErrorBanner: View {
    let message: String
    let accessibilityId: String
}
```

### Visual

- Text: `.caption`, `Theme.danger`, `.multilineTextAlignment(.center)`.
- No background or icon in the MVP.

### Usage

```swift
if let errorMessage = vm.errorMessage {
    ErrorBanner(
        message: errorMessage,
        accessibilityId: "EmailErrorBanner"
    )
}
```

---

## `EmptyState`

Centered placeholder with icon, headline, and subheadline.

### Signature

```swift
struct EmptyState: View {
    let icon: String // SF Symbol name
    let title: String
    let subtitle: String
}
```

### Visual

- `VStack(spacing: Theme.spacingSmall)` centered.
- Icon: `Image(systemName: icon)`, `.font(.system(size: 48, weight: .light))`, `Theme.textSecondary`.
- Title: `.title2.bold()`, `Theme.textPrimary`.
- Subtitle: `.subheadline`, `Theme.textSecondary`, `.multilineTextAlignment(.center)`.
- Padding horizontal `Theme.spacingLarge`.

### Usage

```swift
EmptyState(
    icon: "clock.arrow.circlepath",
    title: L10n.historyEmptyTitle.text,
    subtitle: L10n.historyEmptySubtitle.text
)
```

---

## `ListRow`

A single row in a settings or history list.

### Signature

```swift
struct ListRow<Trailing: View>: View {
    let icon: String?
    let title: String
    let subtitle: String?
    let tint: Color? // default nil → accent; pass Theme.danger so icon + title warn together
    @ViewBuilder let trailing: () -> Trailing
}
```

### Visual

- `HStack(spacing: Theme.spacingMedium)` with default (center) alignment.
- Optional leading icon: `tint ?? Theme.accentPrimary`, `.body`.
- Title: `.body`, `tint ?? Theme.textPrimary`.
- Subtitle: `.caption`, `Theme.textSecondary`.
- Trailing view aligned to the right.
- Full width, padding vertical `Theme.spacingSmall`.

### Usage

```swift
ListRow(
    icon: "clock",
    title: activity.name,
    subtitle: durationString
) {
    Text("Today")
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
}
```

---

## `IconPickerGrid`

Selectable grid of allowed SF Symbols for categories (F2/U1).

### Signature

```swift
struct IconPickerGrid: View {
    let options: [String]
    @Binding var selection: String
    let accessibilityId: String
}
```

**Callers should pass `CatalogIcon.renderableSymbols` (plus a currently selected valid raw value when it is unavailable on the running OS).** The cell renders the `tag` fallback for an unavailable but valid synchronized symbol and never changes the stored raw value.

### Visual

- `LazyVGrid` of icon-only button cells, 44 × 44 pt.
- Each cell: `Theme.backgroundSecondary` fill inside `RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)`, with `Image(systemName: symbol)` in `Theme.textPrimary`, `.body`.
- Selected cell gets a 2 pt `Theme.accentPrimary` border.

### States

| State | Visual |
|---|---|
| Default | 44 × 44 cell, `Theme.backgroundSecondary` fill, `Theme.cornerRadiusSmall` |
| Selected | Same fill + 2 pt `Theme.accentPrimary` border |

### Requirements

- `options` is the renderable subset of the allowed category SF Symbols set (F2/U1); `selection` is the chosen raw symbol name. A valid unavailable selection may be included so it remains visible and editable.
- Each cell `accessibilityIdentifier("\(accessibilityId)Cell(\(symbol))")` and a localized semantic icon label.
- Min tap area 44 — matches the cell size exactly.
- Tapping a cell sets `selection` to that symbol.

### Usage

```swift
IconPickerGrid(
    options: CatalogIcon.renderableSymbols,
    selection: $vm.icon,
    accessibilityId: "CategoryEditorIcon"
)
```

### Accessibility

- Each cell is a button element with a localized semantic icon label.
- Selected cell exposes `.accessibilityValue("Selected")`.

---

## `TagSelector`

Multi-select category chips for an entry (F3). A wrapping flow of content-sized tappable chips; toggling a chip adds/removes the category id from the parent-owned ordered selection.

### Signature

```swift
struct TagSelector: View {
    let options: [Category]
    let selected: [String]
    let onToggle: (String) -> Void
    let onCreate: (() -> Void)?
    let accessibilityId: String
}
```

`onCreate` is opt-in (default `nil`): when non-nil a trailing creation chip renders last; when nil the selector stays select-only.

### Visual

- Wrapping flow of content-sized chips (each chip as wide as its icon/checkmark/ordinal, name, and uniform padding), left-aligned, equal `Theme.spacingSmall` gaps between chips and rows, laid out by the shared `FlowLayout` (`Layout` protocol).
- Unselected chip: only the category icon (14 pt subheadline, scaling with Dynamic Type) + name (`.subheadline` regular); `Theme.backgroundSecondary` fill + 1 pt `Theme.hairline` border; no outline circle.
- Selected chip: the icon is swapped for a `checkmark` of the same enlarged size (`.semibold`) when exactly one chip is selected, or for the 1-based selection ordinal when two or more are selected (ordinals use the same enlarged semibold size; two-digit ordinals shrink to fit the slot); `Theme.accentPrimary` fill, `Theme.textOnAccent` glyph and text; no outline circle. Glyph changes fade in place.
- Chip typography (label + glyph size) is identical to `RecentActivitiesChips` (Recents as reference, `.subheadline` regular per HIG compact-control guidance).
- Each chip: `Theme.spacingChip` (10 pt) uniform padding on all sides, `minHeight Theme.minTapArea` (44 pt — Apple HIG / WCAG 2.2 SC 2.5.5 AAA), `Capsule` shape; long names truncate with `lineLimit(1)`.
- Creation chip (only when `onCreate` is non-nil): pinned last, same padding and 44 pt target so it packs like a chip, but styled as an action — dashed 1 pt `Theme.accentPrimary` outline, `plus` glyph, `Theme.accentPrimary` text on `Theme.backgroundSecondary` fill; never a category icon, checkmark, or ordinal. Toggling categories never moves, restyles, or selects it.
- Edge-aware hairline dividers: a `Theme.hairline` divider fades in above the viewport once chips scroll under it and below the viewport while content remains; the bottom divider fades out at the content end, and both stay hidden when the catalog fits without scrolling. Dividers render as `.overlay` on the capped `ScrollView` outer frame (zero layout height, `allowsHitTesting(false)`), so showing them never grows the viewport or intercepts taps/scroll.
- Chip viewport: hugs content and clamps at up to 4 visible rows of the finite budget measured in `TrackContent` outside the outer `ScrollView` (viewport minus measured top/name/action/caption + fixed gaps + `tabBarMargin`), with a 1-row floor so the page scrolls only as the accessibility fallback; fewer rows on short viewports, always scrolling internally beyond the visible rows; compact when smaller, timer/name/Stop preserved, never pushing siblings or underlapping the tab bar. The scrollable viewport adds 1 pt top/bottom scroll-content padding (`.padding(.vertical, borderBleed / 2)`, `ChipViewport.borderBleed = 2`) plus a matching +2 pt max cap above the row clamp so the lowest row's hairline border never clips at the cut (prior frame-only +2 proved insufficient — user screenshot of exactly-four-row content showed hugging with the bottom border still clipped); the natural-height (non-scrollable) entry-form rendering is unchanged. Shared `ChipViewport` contract with `RecentActivitiesChips`, including identical clearance. Focused verify per iOS worker: 21 tests across 3 suites + lint/build green; device screenshot check still pending.
- When `options` is empty and no `onCreate` is provided, the selector renders no chips and the parent editor shows the localized Add-category action. With `onCreate`, the creation chip still renders alone.

### States

| State | Visual |
|---|---|
| Unselected | `Theme.backgroundSecondary` fill + `Theme.hairline` border; enlarged category icon + name |
| Selected (lone) | `Theme.accentPrimary` fill, `Theme.textOnAccent` text, enlarged `checkmark` in place of the icon |
| Selected (2+) | `Theme.accentPrimary` fill, `Theme.textOnAccent` text, enlarged 1-based selection ordinal in place of the icon, fading in place on every change |
| Empty options | No category chips (creation chip still renders alone when `onCreate` is set); otherwise the parent editor renders the Add-category action |
| Creation chip | Dashed accent outline + `plus` + localized Add-category label, pinned last; outside the selection model |
| Adaptive up-to-4-row viewport | Hugs content, clamps at up to 4 rows of available height + 1 pt top/bottom content padding with matching +2 pt cap, scrolls internally; compact when smaller, never pushes siblings |

### Requirements

- Tapping a chip toggles its id in `selected` (F3); `selected` is in selection (tap) order and deselect-then-reselect appends at the end. Ordinals cap at 99.
- Chips are content-sized; gaps between chips are uniform (`Theme.spacingSmall`); toggling swaps the icon for the checkmark/ordinal without re-packing rows (the ordinal fits the existing fixed symbol slot).
- Each chip's tap target is at least 44×44 pt (`Theme.minTapArea`).
- Each chip `accessibilityIdentifier("\(accessibilityId)Chip(\(id))")`; the creation chip uses `"\(accessibilityId)NewCategory"` with the localized Add-category label (no trait word) as its VoiceOver label.
- Tags are optional; an entry with no tags is valid (F3). The selector never forces a selection.
- Empty-state action follows U8 — guides toward Category creation without blocking the editor.

### Usage

```swift
TagSelector(
    options: vm.allCategories,
    selected: vm.selectedCategoryIds,
    onToggle: { vm.toggleCategory($0) },
    onCreate: { isShowingCategoryEditor = true },
    accessibilityId: "RunningTags"
)
```

### Accessibility

- Each chip is a button element with a localized category label and localized selected/not-selected value; when two or more chips are selected the value also announces the ordinal position.
- The icon/checkmark/ordinal is `.accessibilityHidden(true)` decoration; selection state and order are conveyed visually by the icon↔checkmark↔ordinal swap in addition to fill color, and announced by the button's value.
- The parent screen owns the empty-state "create category" action.
- The creation chip is a button element announcing the localized Add-category action; its `plus` glyph is `.accessibilityHidden(true)` decoration.

---

## `RecentActivitiesChips`

The Track Recents chip flow (D2/D3/D4): a wrapping flow of at most twelve
most-recently-used exact entry texts with 44 pt tap targets; chips wrap onto
additional rows inside a fixed-height area (three chip rows) with its own
vertical scroll and never require horizontal scrolling. A single tap fills the
name field with that exact text plus its newest entry's ordered categories
without starting timing. There is no activity entity — chips represent entry
texts, never activities. (The type name is kept for code continuity.)

### Signature

```swift
struct RecentActivitiesChips: View {
    let recents: [ExactName]
    let categories: [String: Category]
    let selectedText: String?
    let onSelect: (ExactName) -> Void
}
```

### Visual

- Wrapping flow of content-sized chips, left-aligned, equal `Theme.spacingSmall`
  gaps between chips and rows, laid out by the shared `FlowLayout`
  (same greedy packing as `TagSelector`).
- Cap of twelve, most-recently-used first (`recents.prefix(12)`; the store
  already sorts by each text's newest `started_at`). The flow sits in an
  adaptive viewport (hug content, clamp at up to 4 rows of available
  height, scroll internally) with the same 1 pt top/bottom scroll-content
  padding plus matching +2 pt max cap as `TagSelector` (`ChipViewport`
  contract, including `borderBleed`), so small sets stay compact, short
  viewports show fewer rows with internal scroll, and overflow never grows
  the page or slides under the tab bar.
- Edge-aware `Theme.hairline` dividers (same contract as `TagSelector`):
  top fades in once scrolled, bottom fades out at the content end, both
  hidden when everything fits. Dividers render as `.overlay` on the capped
  `ScrollView` outer frame (zero layout height, `allowsHitTesting(false)`).
- Each chip: fixed icon slot with the first assigned Category's
  `CatalogIcon(validated:).displaySymbol` + exact text (`.subheadline`,
  one line, tail-truncated), `Theme.spacingMedium` horizontal / 12 pt vertical
  padding, `minHeight Theme.minTapArea` (44 pt), `Capsule` shape.
- Categoryless texts render name-only chips with no icon and no
  placeholder glyph.
- Unselected chip: `Theme.backgroundSecondary` fill + `Theme.hairline` border;
  icon and text in `Theme.textPrimary`.
- Selected chip (the prepared text, `selectedText == recent.text`): filled
  accent presentation — `Theme.accentPrimary` background, `Theme.textOnAccent`
  text and icon, accent border; the Category icon is kept; no checkmark.
- When `recents` is empty the component renders no chips; the parent screen
  shows the dedicated empty copy (`timer.recentsEmptyHint`).

### States

| State | Visual |
|---|---|
| Unselected | `Theme.backgroundSecondary` fill + `Theme.hairline` border; icon + text |
| Selected | `Theme.accentPrimary` fill, `Theme.textOnAccent` text/icon, accent border; icon kept |
| Empty | No chips; parent shows `timer.recentsEmptyHint` |

### Requirements

- Tapping a chip calls `onSelect` — the parent fills the field and inherits the ordered categories without
  starting timing.
- Chips are content-sized with uniform `Theme.spacingSmall` gaps; a chip wider
  than the container renders at container width with a truncated name.
- Each chip's tap target is at least 44×44 pt (`Theme.minTapArea`) in every
  presentation (icon, no-icon, selected).
- Recents are hidden while a timer is running.
- Category names are never shown on chips; the prepared-text chip and the
  running tag selector remain category-name-free (D16 revision).

### Accessibility

- Each chip is a button element with `.accessibilityLabel("Select \(recent.text)")`
  (`L10n.timerSelectActivity`).
- The prepared text's chip additionally gets `.accessibilityAddTraits(.isSelected)`
  and `.accessibilityValue("Selected")`; unselected chips carry no value.
- The icon is `.accessibilityHidden(true)` decoration.
- `accessibilityIdentifier("TimerSuggestion(\(recent.text))")`.

### Usage

```swift
RecentActivitiesChips(
    recents: vm.recents,
    categories: vm.categoryMap,
    selectedText: state.text
) { vm.prefill(from: $0) }
```

---

## `AdaptiveVerticalLayout`

Deterministic spacing budget for the Track dual-flow layout (D34/D1): a
scrollable dual-flow vertical stack whose three flexible regions resolve from
the remaining space instead of relying on `Spacer` flexibility (which cannot
be capped).

### Signature

```swift
struct AdaptiveVerticalLayout<TopContent: View, BottomContent: View>: View {
    let spacerCap: CGFloat
    let topContent: TopContent
    let bottomContent: BottomContent

    init(
        spacerCap: CGFloat,
        @ViewBuilder topContent: () -> TopContent,
        @ViewBuilder bottomContent: () -> BottomContent
    )
}
```

### Behavior

- `spacerCap` is the shared maximum height for the top and bottom spacers
  (48 pt on Track, selected by the user from the 24/48/72/96 Pro Max spike
  comparison).
- With `slack = viewportHeight - contentHeight`:
  - `slack <= 0` — no adaptive spacing; the ordered content scrolls.
  - `0 < slack <= 2 * cap` — the slack splits evenly between the top and
    bottom spacers (`min(cap, slack / 2)` each); the central separator is
    zero.
  - `slack > 2 * cap` — both spacers hold at the shared cap and the surplus
    goes to the central separator between the top flow (completion mark…
    error region) and the bottom flow (search/refine…main action).
- Top and bottom flow heights are measured separately via `GeometryReader` +
  preference keys.
- On Track the top flow holds the completion-mark region through the error
  region; the bottom flow holds the search/refine row through the main action,
  with Recents below the main action inside the bottom flow.

### Requirements

- The three flexible regions never exceed the cap and never go negative; they
  collapse to zero before content clips, overlaps, or becomes unreachable.
- The main action sits above Recents so the name prompt / Start / Stop stays
  reachable without scrolling on short screens.

---

## `NumericTimerReadout`

The centered numeric timer on Track (D2/D23). Its only purpose is displaying the exact elapsed duration; it has no dial, ring, sweep, goal, daily-total, or decorative progress visualization.

### Signature

```swift
struct NumericTimerReadout: View {
    let state: TrackState // idle / ready / running / saving / saved / error
    let elapsed: TimeInterval
}
```

### Visual

- Elapsed time formatted as `MM:SS` or `H:MM:SS` (hours included once elapsed), `.monospacedDigit()`.
- Font: `Theme.timerFont()` (`.system(size: 64, weight: .semibold, design: .rounded)`), `Theme.textPrimary`.
- Centered in the main content region; keeps a stable frame across all timer states.
- No checkmark overlay — the saved-state confirmation lives in the completion
  region above the readout (refine-track-recents D1), so the readout itself
  never renders a checkmark and the saved state does not move the timer.
- A short state caption below the readout (`READY`, `RUNNING`, `SAVING`, `SAVED`, or the idle prompt) in `.caption`, `Theme.textSecondary`.
- `accessibilityIdentifier("TimerDisplay")`.

### States

| State | Visual |
|---|---|
| Idle | `00:00` + name prompt |
| Ready | `00:00` + `READY` caption |
| Running | Live exact elapsed value + `RUNNING` caption |
| Saving | Readout stable; primary action shows progress |
| Saved | `SAVED` caption; confirmation is shown in the completion region above the readout; readout returns to `00:00` without moving |
| Error | Readout stable; localized non-field error in the reserved region above the central separator |

### Accessibility

- Single accessible element: `.accessibilityElement(children: .combine)`.
- `.accessibilityLabel` announces the entry text, timer state, and elapsed duration; `.accessibilityValue` carries the exact formatted duration.
- `.accessibilityAddTraits(.updatesFrequently)` while running so VoiceOver announces the live value.

---

## `CompactTimer`

The persistent running-timer surface shown above the tab bar on History and Insights (D5). Track does not render it — the full numeric readout is already visible there.

### Signature

```swift
struct CompactTimer: View {
    let entryText: String
    let startedAt: Date
    let openTrack: () -> Void
    let stop: () -> Void
}
```

### Visual

- Inset above the tab bar via `.safeAreaInset(edge: .bottom)` on History/Insights roots.
- `HStack`: a non-destructive main area (entry text + live elapsed duration, `.monospacedDigit()`) that returns to Track, and a separate 44 pt circular Stop button (`stop.fill`, `Theme.danger` or accent tint).
- Surface: `Theme.backgroundSecondary` fill, `Theme.cornerRadius` continuous corners, `Theme.hairline` 1 pt stroke.
- `accessibilityIdentifier("CompactTimer")`; Stop button `accessibilityIdentifier("CompactTimerStopButton")`.

### States

| State | Visual |
|---|---|
| Running | Entry text + live elapsed duration + Stop |
| Stopped | Removed from the shell (entry saved in place) |

### Accessibility

- Main area: `.accessibilityLabel("<entry text>, timer running")`, `.accessibilityHint("Returns to Track")`.
- Stop button: `.accessibilityLabel("Stop and save timer")`.
- VoiceOver announces entry text, elapsed duration, running state, and available actions.
- The Stop target is a distinct 44 pt target separated from the navigation area (D5 risk mitigation).

---

## `RunningBannerFace`

The Lock Screen Live Activity banner face for a running timer (lives in the `LifioLiveActivities` widget target, not the app). Icon + exact entry name + live ticking elapsed + circular Stop link, rendered as transparent content over the system card (Liquid Glass on iOS 26+, solid card below). Full behavior contract: `live-activities` spec.

### Signature

```swift
struct RunningBannerFace: View {
    let text: String
    let iconSymbol: String
    let startedAt: Date
    let trackURL: URL?
    let trackStopURL: URL?
}
```

### Visual

- Content-row insets: **12 pt leading** (icon side), **8 pt trailing**, **8 pt vertical**.
- `HStack`: icon (`.title`) + name (`.headline`, 1 line) over live elapsed (`.subheadline.monospacedDigit()`, system timer view) + 44 pt circular Stop link; no custom container, fill, gloss, or hairline.
- Body taps deep-link to Track; Stop opens the app at the stop URL. Dimmed rendering keeps the layout with the Stop control dimmed and inert.

### Accessibility

- Label zone is one combined element announcing the running entry text; the Stop circle keeps its own stop accessibility label.

---

## `ActivitySearchSheet` and `ActivitySearchContent` (removed)

> **Removed** by `remove-activities-layer`: Track has no search sheet — capture is the `TimerNameRow` push row plus the shared `NamePicker` page (see `SCREENS/NamePicker.md`) and Recents chips. No implementation, no call sites.

---
## `TimerActivityRefineButton` (removed)

> **Removed** in refine-track-recents: Track has no editing affordance. No implementation.

---
## `SuggestionRow` (removed)

> **Removed** in refine-track-recents: replaced by `RecentActivitiesChips`. No implementation.

---
## `ActivityRow` (removed)

> **Removed** by `remove-activities-layer`: no Manage Activities screen, no activity editor. No implementation, no call sites.

---
## `EntryRow`

Read-only History row for a committed time entry (history-entry-list spec, Variant H layout). Purely presentational — grouping, category resolution, and duration formatting are owned by `HistoryViewModel`.

### Signature

```swift
struct EntryRow: View {
    let entry: TimeEntry
    let icon: String
    let categoryNames: String
    let timeframeText: String
    let durationText: String
    let isInProgress: Bool
    var viaText: String = ""   // localized "via <Source>"; empty for manual
    var hasNotes: Bool = false // non-empty notes show the notes indicator
}
```

### Visual

Variant H (spike-confirmed, design.md D4):

```
  [icon]  Entry text                       1h 20m
          Health, Morning, via Garmin  14:00 – 15:20
```

- `HStack(alignment: .top, spacing: Theme.spacingMedium)`:
  - Leading icon: first category's SF Symbol, `.title3`, `Theme.textSecondary`, 28 pt column, vertically spanning both text lines. Its optical top is top-aligned with the entry text's **cap-height top** (top of capital letters), not the text frame top — achieved with a negative top padding tuned for `.title3` icon + `.headline` name (`EntryRow.iconTopAdjustment`). If the font stack changes, the offset needs re-tuning.
  - `VStack(alignment: .leading, spacing: 2)`:
    - Line 1: entry text `.headline`, `Theme.textPrimary` (left, flexible) + duration `.headline`, `Theme.textPrimary`, `.monospacedDigit()` (right).
    - Line 2: category names + provenance label `.caption`, `Theme.textSecondary` (left, flexible) + timeframe `.caption`, `Theme.textSecondary`, `.monospacedDigit()` (right). The "via <Source>" label (entry-provenance spec) is appended to the category caption after a comma; `manual` entries show nothing. When `hasNotes` is true, a `note.text` glyph (`.caption`, `Theme.accentPrimary`) renders immediately left of the timeframe — the position is identical on every row, so neither line reflows. Whitespace-only notes count as empty (no icon).
- Min height `Theme.minTapArea`; dividers between rows lead after the icon column.

### States

| State | Visual |
|---|---|
| With categories | First category's icon leading; name + duration line 1; category names + timeframe line 2 |
| With provenance | The "via <Source>" label appended to line 2's left caption (after category names, or alone when no categories) |
| With notes | `note.text` glyph (`.caption`, `Theme.accentPrimary`) on line 2, immediately left of the timeframe; `HistoryViewModel.hasNotes(for:)` owns the trimmed non-empty check |
| No categories | `questionmark` fallback icon; line 2 shows only the timeframe (plus the "via" label when present) |
| In progress (no `endedAt`) | Duration slot shows the localized in-progress indicator; timeframe shows the start time |

### Requirements

- `accessibilityIdentifier("EntryRow(\(entry.id))")`.
- Read-only: no tap action in this component (history-entry-list spec).
- The caller (`HistoryViewModel`) resolves the icon and category names from the entry's own ordered category set (entries own their categories at write time; nothing is resolved at query time).

### Usage

```swift
EntryRow(
    entry: entry,
    icon: vm.icon(for: entry),
    categoryNames: vm.categoryNames(for: entry),
    timeframeText: vm.timeframeText(for: entry),
    durationText: vm.durationText(for: entry),
    isInProgress: vm.isInProgress(entry),
    viaText: vm.viaText(for: entry),
    hasNotes: vm.hasNotes(for: entry)
)
```

### Accessibility

- `accessibilityIdentifier("EntryRow(\(entry.id))")`.
- The whole row is a single element: category names, timeframe, and duration are `.accessibilityHidden(true)` and folded into the row label, so VoiceOver reads one line per entry. When `hasNotes` is true the label appends the localized `historyHasNotes` segment ("has notes").

---

## `CategoryRow`

Manage-categories list row for a category (F2). Tap opens `CategoryEditor`.

### Signature

```swift
struct CategoryRow: View {
    let category: Category
    let action: () -> Void
}
```

### Visual

- `HStack(spacing: Theme.spacingMedium)`:
  - Leading `Image(systemName: category.icon.rawValue)` in `Theme.textSecondary`.
  - Name in `.body`, `Theme.textPrimary`.
  - Trailing `Image(systemName: "chevron.right")` in `Theme.textSecondary`.
- Min height `Theme.minTapArea`; full width.

### States

| State | Visual |
|---|---|
| Default | Category icon + name + trailing chevron |

### Requirements

- `accessibilityIdentifier("CategoryRow(\(category.id))")`.
- Swipe-to-delete is owned by the parent `List`.
- Tapping calls `action` — the parent navigates to `CategoryEditor`.

### Usage

```swift
List {
    ForEach(vm.categories) { c in
        CategoryRow(category: c) { vm.edit(c) }
    }
}
```

### Accessibility

- `accessibilityIdentifier("CategoryRow(\(category.id))")`.
- The whole row is a single button element: `.accessibilityLabel("Category, \(category.name)")`.

---

## `SectionHeader`

Day-group header in History — its only production caller. `CategoryEditorView` renders a plain `Text` label for its icon section instead of this component.

### Signature

```swift
struct SectionHeader: View {
    let title: String
    /// Optional second line under the title (History day total). Nil renders
    /// the single-line editor presentation.
    let subtitle: String?
}
```

### Visual

- `Text(title).font(.title2.bold()).foregroundStyle(Theme.textPrimary)` in both the single-line and History day-group usage.
- Optional subline `Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()` under the title (History day total; nil renders the single-line presentation).
- No padding or trailing view of its own — History day-group paddings live at the call site (see `SCREENS/History.md`).
- History day-group usage (D8): static two-line block (day label + total subline, Calendar-Agenda-like), identical in-list and pinned — no scroll-state gating, zero top padding. Bare `List(.plain)` section headers: no background fill, no `.bar` material, no hairline — the user rejected the boxed slab look, and the pinned bleed (row text crossing beneath headers) is accepted on every OS.

### States

| State | Visual |
|---|---|
| Default (single-line) | `.title2.bold()` title in `Theme.textPrimary` |
| Day-group (in-list and pinned) | Day label + total subline ("2h 35m tracked"), no gating |

### Requirements

- Pure presentational — no state, no action.
- No production editor caller exists — `CategoryEditorView` renders a plain `Text` label for its icon section.
- History usage: day-group header with always-visible total subline. The component itself has no notion of scrolling.

### Usage

```swift
// History day group (D8/D10):
SectionHeader(
    title: dayGroup.label,
    subtitle: "\(dayGroup.total) \(L10n.historyTracked.text)"
)
```

### Accessibility

- `.accessibilityAddTraits(.isHeader)` so VoiceOver announces it as a section header.

---

## `FlowLayout`

Greedy wrapping flow (`Layout` protocol) shared by `TagSelector` and `RecentActivitiesChips`. Packs content-sized chips left-aligned with uniform `Theme.spacingSmall` gaps between chips and rows; a chip wider than the container renders at container width.

### Signature

```swift
struct FlowLayout: Layout {
    var spacing: CGFloat
}
```

### Requirements

- Toggling a chip swaps its content without re-packing rows.
- Min tap area per chip is the caller's responsibility (`Theme.minTapArea`).

---

## `ClearTextButton`

Opt-in trailing clear (`xmark`) button for text fields. Keeps a 44 pt row height stable whether visible or not.

### Signature

```swift
struct ClearTextButton: View {
    let action: () -> Void
    let accessibilityId: String
}
```

- Callers: timer name, entry name/notes, category name (`TimerNameClearButton` / `EntryNameClearButton` / `EntryNotesClearButton` / `CategoryNameClearButton`).

---

## `FieldCard` / `FormCard`

Shared card container for name rows and entry-form sections. `Theme.backgroundSecondary` fill, `Theme.cornerRadius` continuous corners, `Theme.spacingMedium` horizontal padding, `minHeight Theme.minTapArea`. Tap-away keyboard dismissal lives in `FormCard` as a plain tap (child buttons consume their taps).

---

## `EditorChrome`

Shared navigation-bar chrome for editor sheets: toolbar `xmark` cancel + `checkmark` confirm (CREATE sheet) or Back + `checkmark` (pushed EDIT). Both dismiss paths lock while saving; confirm is validity-gated by the caller.

---

## `ShakeFirstResponderHost`

Passive transparent `UIViewRepresentable` holding first responder so the iOS system shake-to-undo prompt reaches the surface's `@Environment(\.undoManager)`. Handles no motion itself; one host per deletable surface (Track, History, Manage Categories, entry form). No custom accelerometer logic.

---

## `MainActionSlot`

Fixed-height slot for Track's state-specific main action (name prompt / Start / Stop). The frame equals the tallest state title at the active Dynamic Type size; the swap itself never animates.

---

## `NamePicker` (page)

Shared dedicated name-picking page — full spec lives in `SCREENS/NamePicker.md`. Component contract: `init(initialText:recents:categories:placeholder:emptyHint:onCompleteSuggestion:onCompleteText:)`; local draft only, two caller-owned completions, Back cancels.

---

## `NotesEditorPage` (page)

Shared dedicated notes-editing page pushed from the entry-form Notes presenter and the running Track notes row. Copy-on-open local draft; X discards, ✓ writes back via `onSave`. No system Back button (swipe-back still pops and discards, like X).

### Copy

- Collapsed presenters (entry-form Notes row, running Track notes row) show `entry.notesPlaceholder`: EN "Optional notes" / RU "Необязательные заметки".
- The expanded editor empty state shows `notes.editorPlaceholder`: EN "Dear diary..." / RU "Дорогой дневник...". The two keys are intentionally distinct.

### Visual

- Empty-state overlay: `.body`, `Theme.textSecondary`, hit-test-transparent, hidden from VoiceOver (the nav-bar title + live `<name> • <count>/2000` counter subtitle carry the accessible context).
- Over-limit counter renders `Theme.danger`; ✓ stays enabled and an over-limit save shakes the subtitle with the error haptic instead of saving.

---

## `UndoToast` (removed)

> **Removed** by `unify-catalog-deletion`: deletions undo through the DEFAULT system Undo confirmation only (see `INTERACTIONS.md` → Undo flow). No component, no `L10n.undo.*` toast keys, no call sites. The undo buffer stays restorable until the app restarts — there is no toast and no 30-second window.

---
## `ScopeConfirmation` (removed)

> **Removed** by `remove-activities-layer` + `unify-catalog-deletion`: entry deletion is a single destructive confirm naming the entry text; category deletion is a single tag-only confirm. No component, no call sites.

---
## `ActivityDetailView` (removed)

> **Removed** by `remove-activities-layer`: History row taps push the unified entry form directly (see `SCREENS/EntryForm.md`). No implementation, no call sites.

---
## `ActivityEntryRow` (removed)

> **Removed** by `remove-activities-layer`: no activity detail sheet. No implementation, no call sites.

