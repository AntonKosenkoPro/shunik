# Design: inline category creation

## Context

See proposal.md (Why) for motivation. Current state (verified on this tree):

- `TagSelector` (`Core/Design/Components/TagSelector.swift`) is a dumb select-only chip flow shared by `LogTimeView.categoriesCard` (`ManualEntry/Views/LogTimeView.swift:296-316`, id `EntryCategories`) and Track's `runningTagSelector` (`TimeTracking/Views/TrackContent.swift:305-321`, id `RunningTags`). No creation affordance anywhere near either.
- `CategoryEditorView` (`Catalog/Views/CategoryEditorView.swift`) is a full-height sheet that owns its `NavigationStack`, toolbar X/✓ (`EditorToolbar`), name field + `IconPickerGrid`, and create/edit modes (`category == nil`). Its only callers present it as a `.sheet` from `ManageCategoriesView`.
- `LogTimeView` is dual-homed: CREATE is a sheet with an internal `NavigationStack` (`LogTimeView.swift:81-83`, presented from `HistoryView.swift:133-137`); EDIT/LOCKED is pushed on `historyPath` (`HistoryView.swift:177-203`, `embeddedInNavigationStack: true`). Name (`NamePicker`) and Notes (`NotesEditorPage`) rows already push from both homes.
- Track owns `trackPath` (`AppShellView.swift:133-179`); `ShellRoute` today is `profile | entry | namePicker | notesEditor` (`AppShellViewModel.swift:24-29`). Manage Categories is a caller-local link under Profile, not a route.
- Store contract: `LocalStore.createCategory(draft:id:now:)` validates (trimmed non-empty, ≤60, case-insensitive unique) and commits category + sync outbox atomically; `.duplicate(winner)` on clash. `CategoryEditorViewModel.save()` keeps the editor open with `errorCategoryExists` on duplicate.

Pin: iOS 18 SDK via Xcode 16+ throughout.

## Goals / Non-Goals

Goals: one creation chip implementation serving both surfaces; push-only presentation (no stacked sheet); full-editor reuse with zero validation/sync divergence; auto-select on save in all live-draft contexts.

Non-goals (beyond proposal scope): restyling existing chips; changing Manage Categories; undo/toast; backend/OpenAPI. (Recents viewport parity is in scope via the shared `ChipViewport` contract.)

## Decisions

**D1 — Opt-in trailing chip inside `TagSelector` (`onCreate: (() -> Void)?`, `nil` = select-only).**
Why: both surfaces want the identical chip; one implementation keeps styling, FlowLayout packing, and accessibility in a single place. `nil`-default preserves the current contract for any future host and keeps the "select-only" default honest. Alternative (button in each card's chrome) was rejected after the user chose the trailing chip: two copies of chip styling that must never drift.

**D2 — Trailing action chip (`plus` + localized label, dashed accent outline, `Theme`-only), pinned last in the flow.**
Why: the chip must differ from unselected (secondary fill + hairline stroke + category icon) and selected (accent fill + checkmark/ordinal) chips by shape, not just hue — perceivable in both appearances and without color vision. Same `spacingChip` padding and 44 pt target so it packs identically in the `FlowLayout`; pinned last so alphabetical re-sorting never moves the anchor. Edge-aware hairlines guard the viewport (top fades in once scrolled, bottom fades out at the end, both hidden when everything fits — `onScrollGeometryChange`). The chip region hugs content and clamps at up to 4 visible rows bounded by the finite available height, scrolling internally beyond the visible rows; small catalogs render compactly with no reserved dead space, short viewports (e.g. SE) show fewer rows with internal scroll, the timer/name/Stop frames are preserved, and the viewport never grows the page or slides under the tab bar; entire-page scroll engages only as an accessibility fallback when the core controls cannot fit. Both chip groups share the same border clearance as 1 pt top/bottom scroll-content padding (`.padding(.vertical, borderBleed / 2)`, `ChipViewport.borderBleed = 2`) plus a matching +2 pt max cap above the row clamp, so the lowest row's 1 pt hairline border never clips at the cut (prior frame-only +2 proved insufficient — user screenshot of exactly-four-row content showed hugging with the bottom border still clipped; decision: content padding + cap, not frame alone; the natural-height entry-form rendering is unchanged). Implemented (iOS worker, this tree): `TrackContent` measures the finite budget outside the outer `ScrollView` (viewport minus measured top/name/action/caption heights plus fixed gaps and `tabBarMargin`) and passes it down; `ChipViewport` clamps to `min(4-row clamp + bleed, available budget)` with a 1-row floor so the outer page scrolls only as the accessibility fallback when core controls cannot fit. `ChipViewport.borderBleed = 2` is shared by both groups as 1 pt top/bottom scroll-content inset plus matching +2 pt cap. Verify: `swiftlint lint --strict` 0 violations, full suite 690 tests / 67 suites green. Simulator (default Dynamic Type L, recaptured after earlier XS/XXXL): SE shows ~2.5 rows with internal scroll and no tab-bar overlap; mini/max show 4 rows with the bottom edge divider; SE scroll-end shows the `+Add` dashed border complete with top divider visible, bottom hidden, timer/name/Stop stationary; SE overflowing Recents (existing history fixture, 12 recents) adapts its cap with internal scroll, last-row borders intact, Start stationary; idle single Recent hugs with no dividers. Evidence (simulator only, binaries kept out of git): `/private/var/folders/8c/pwh55jk140g1shxfnwm7zxf80000gn/` `track-se-L.png`, `track-mini-L.png`, `track-max-L.png`, `track-se-scrolled.png`, `track-se-recents-L.png`, `track-se-recents-end-L.png`. Physical-phone adaptive update NOT deployed — no done claim beyond simulator. Research: SwiftUI `/websites/developer_apple_swiftui` — `ScrollView frame clipping border` (docs: `scrollClipDisabled`, scroll-views: `ScrollView` clips to bounds by default — clearance via frame sizing rather than disabling clipping) + `view frame layout padding safe area` (docs: `safeAreaPadding`, `safeAreaInset` — not applicable inside a clamped chip viewport; no safe-area change); library query `ScrollView finite height proposal GeometryReader` + docs `ScrollView content unbounded proposed height finite container` (`ProposedViewSize.height == nil` means unspecified/ideal height, so the finite budget must be measured outside the outer `ScrollView` and passed down). `GeometryReader` docs query failed on shell quoting — not claimed as fetched. HIG waived: no changed interaction, typography, or grouping — bounded-geometry fix only. HIG residue (in-context creation entry points are idiomatic; `/websites/developer_apple_design_human-interface-guidelines`, query `adding creation affordances buttons in context`) supports in-place creation; no chip-group prose was retrieved — partial waiver, evidence: all four returned sections were `contextMenu`/pull-down/widget-gallery samples.

**D3 — Extract a pushable editor form; keep a thin sheet wrapper for Profile.**
Why: the editor's `NavigationStack` + toolbar + scroll content must be separable so the *form* can be a `navigationDestination` while Manage Categories keeps presenting the *sheet*. Alternatives: (a) uniform `.sheet` everywhere — rejected: sheet-over-sheet in CREATE (double drag handle, keyboard focus-settle tuned for a single sheet per `CategoryEditorView.swift:118-126`); (b) duplicate the form — rejected: validation/sync divergence risk. The pushed form shows no toolbar X — system Back is the only cancel (LogTime pushed-form parity); the sheet keeps X/✓.

**D4 — Push per host: CREATE sheet's internal stack, `historyPath` for EDIT, new `ShellRoute` case for Track.**
Why: matches the Name/Notes precedent on every host (all push today). NavigationStack path mechanics per SwiftUI docs (`/websites/developer_apple_swiftui`, query `NavigationStack push navigation programmatic navigation path iOS 18`): `NavigationLink(value:)` + `.navigationDestination(for:)` per type; a sheet-hosted stack owns its path scoped to the sheet. Track needs a new route value (e.g. carrying a completion that reloads + appends to the running draft); the `LogTimeView` CREATE sheet can use a value link on its internal stack; EDIT can append to `historyPath` or link locally — implementer picks the smallest diff consistent with `HistoryView` owning entry-form reload.

**D5 — Save path reuses `CategoryEditorViewModel` + `LocalStore.createCategory` unchanged; hosts only reload + append.**
Why: zero divergence in validation, duplicate, outbox, and sync-collision behavior. Post-save, each host reloads its options (`loadCategoriesIfNeeded`-equivalent / Track category map) and appends the new id in tap order; pops happen via the editor's existing dismiss-on-save. Idle Track reloads options only. Duplicate from any entry host follows the existing stay-open + banner rule (user-confirmed Option 1) — no winner-selection shortcut.

**D6 — Accessibility: `Button`-based chip announces automatically; localized label, no trait word, distinct id.**
Per SwiftUI a11y docs (`/websites/developer_apple_swiftui`, query `accessibility custom button accessibilityLabel accessibilityValue VoiceOver`): the icon-only `+` needs `accessibilityLabel` (localized "new category" wording, no "…button"), no `accessibilityValue` (static action), an id distinct from `…Chip(id)` (e.g. `…NewCategory`), 44 pt target. All strings through `L10n` en+ru (U4).

**D7 — Plain-text capture requirement untouched.**
`timer-capture-experience` "no catalog, no search sheet, no quick-create" governs the Track *name* field; a full-editor push from the *tag row* is neither a search sheet nor a quick-create, so that requirement needs no delta. (Recorded here so the omission is deliberate, not missed.)

## Risks / Trade-offs

- [Form-extraction regression risk] → Manage Categories sheet behavior must stay pixel-identical; cover with existing editor tests + a sheet-parity UI check before/after.
- [CREATE save-gate interplay] → while the editor is pushed, the entry's X/✓ is replaced by Back + editor ✓; the entry draft (StateObject at sheet root) survives the push. No autosave or draft-merging introduced.
- [New-category re-pack] → inserting a category alphabetically re-flows `FlowLayout` rows once; selection toggles still never re-pack (fixed symbol slot preserved). Accepted: one-time, post-save, behind a pop transition.
- [Track mid-run editor] → timer keeps running under the pushed editor; save appends to the live draft snapshot. No pause, no timing side effects; `toggleDraftCategory`-equivalent path only.
- [HIG chip-group guidance gap] → no retrieved HIG prose for trailing-action chips (waiver above); mitigate with the shape-not-hue rule and a11y labels, and eyeball against Calendar/Reminders inline-add patterns in manual smoke.

## Migration Plan

None. Pre-release, no on-disk format change, no API change. Rollback = revert the change; catalog data created through the new entry points is ordinary category records.

## Open Questions

None — presentation (push), editor scope (full), surfaces (both), duplicates (stay open), attach rule (all live drafts; idle = pool only) were all resolved with the user in discovery.
