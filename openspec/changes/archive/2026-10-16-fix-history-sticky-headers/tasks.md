## 1. Repro + external docs

- [x] 1.1 Reproduce issue #35 on the current tree: run History with 2+ day groups on iPad landscape simulator (plus iPhone for scale contrast), record screenshot/screen-recording showing the opaque header slab seaming against the transparent nav bar; file evidence with the change.
  - DONE 2026-10-14: `UITEST_SCREEN=history` DEBUG harness (`AppContainer+UITesting.swift`, 3 day groups × 10/6/4 entries) on iPad Pro 11" (iOS 27) + reporter screenshot filed in `evidence/` (`1.1-before-ipad-portrait-pinned.png`, `1.1-issue35-reporter-ipad.png`). Findings: (a) rows slide under the floating glass toolbar and collide with its controls — the custom ScrollView has no scroll-edge transition; (b) reporter shot shows a day total on an in-list (non-pinned) header → elevation-tracker staleness in the wild; (c) app is portrait-only (`project.yml`), so iPadOS 26 flexible windowing forces the portrait layout into wide windows (width reflow stays a follow-up non-goal).
- [x] 1.2 Confirm ctx7 fetch recorded (done in proposal): `/websites/developer_apple_swiftui` — `scrollEdgeEffectStyle`, `Material ultraThinMaterial toolbar background`, `pinnedViews LazyVStack section headers`; iOS 18 floor.

## 2. Spikes (throwaway, on-device evidence)

- [x] 2.1 Spike A — translucent-ize in place: header material (`.bar` first) + `.scrollEdgeEffectStyle` (`.automatic` vs `.hard`); capture iPhone + iPhone landscape, light + dark, sparse + dense days, pin/unpin transition frame; record winner + legibility verdict.
  - DONE 2026-10-14 (iPad Pro 11", iOS 27, light): `.bar` + `.hard` WINS. `.hard` renders a defined translucent band continuous with the nav blur; rows visibly blur beneath the pinned header; total stays legible. `.automatic` is too weak — the band vanishes into the background and the total floats over rows (legibility risk). Evidence: `evidence/2.1-spikeA-hard-{rest,pinned-midscroll}.png` vs `evidence/2.1-spikeA-automatic-rest.png`. Dark-mode + a11y verdict in 2.4 on the final build.
- [x] 2.2 Spike B + Spike A-scrolling + re-pin (superseded path, 2026-10-14): List.plain verified sticky+vibrancy (`2.2-spikeB-ipad-rest.png`); scrolling baseline verified headers scroll away (`2.2-spikeA-ipad-*`); re-pin without slab (`ultraThinMaterial` + Divider, no scrollEdge) verified + Release-installed to iPhone. User then ordered from-scratch rebuild to 6 reqs.
- [x] 2.3 Continuous top surface (2026-10-14, SUPERSEDED by 2.5): structural `topClearance` + frame-anchored fade cover — produced the giant void above the list (user-rejected) and then a fade over the first header on iPhone (user-rejected); all custom-cover anchoring attempts ultimately failed pixel probes on iOS 18 (design.md D4). Evidence retained in git history.
- [x] 2.5 Native `List.plain` migration (final, 2026-10-14, consolidated reqs incl. "as native as possible"): `ScrollView+LazyVStack` → `List` (`.plain`, hidden separators, zeroed insets, `scrollContentBackground(.hidden)`); native sticky headers in `.bar`; tap-to-edit, pull-to-refresh, empty state preserved. Pixel-probe verified on iPad iOS 27 + iPhone 16 Pro iOS 18 light/dark, rest + scrolled: no void, no fade-over-header, no painted rows in the chrome-free nav zone (native bar blur only, Calendar/Mail-like) — `evidence/3.1-list-{ipad,iphone}-*.png`.
- [x] 2.4 Verify Reduce Transparency / Increase Contrast opaque fallback and accessibility-large Dynamic Type (no label/total overlap) on the winning spike.
  - DONE 2026-10-14 (iPad Pro 11"): Reduce Transparency ON → whole UI flattens opaque, two-line headers fully legible, zero code needed (system materials honor it) — `evidence/2.4-final-reduce-transparency.png`. Max AX Dynamic Type → label + subline stack with no overlap (VStack structural) — `evidence/2.4-final-maxAX-dynamic-type.png`. Dark rest + dark pinned-midscroll (rows visibly blur under the pinned band) — `evidence/2.4-final-dark-*.png`. Sim reset to pristine afterwards (erase + reinstall).

## 3. Implementation

- [x] 3.1 Implement in `HistoryView` + `SectionHeader` (optional subline): two-line static header (label + total subline, no elevation gating — DELETE `elevatedGroupID`, `HeaderFramePreferenceKey`, header `GeometryReader`, `onPreferenceChange`), translucent `.bar` material; keep day labels, totals math, column alignment of rows; no new strings.
  - DONE 2026-10-14: `SectionHeader(title:subtitle:)` additive; `HistoryView.dayGroupHeader` two-line + `.bar`; tracker fully removed (state, prefs, coordinate space). Final form: native `List.plain` (task 2.5) hosting the headers. Build green, no new warnings.
- [x] 3.2 Update `Design/SCREENS/History.md` (header treatment + checklist) and `Design/COMPONENTS.md` (`SectionHeader` visual, only if changed).
  - DONE 2026-10-14: both updated (two-line static header, `.bar`, native `List.plain` body, no elevation tracking; `SectionHeader(title:subtitle:)` signature + usage). RE-PASSED under 4.8 for the UIKit bridge.
- [x] 3.3 UIKit `UITableView(.plain)` bridge (user verdict: header `.bar` slab = "rectangles"; List pinned headers cannot occlude on iOS 18 — design.md D6): new `HistoryListTable.swift` (`HistorySectionModel` diff-applied, `EntryRow`/`SectionHeader` via `UIHostingConfiguration`, opaque page-color header band, tap/pull closures, `HistoryList` identifier preserved); `HistoryView` rewired (`daySectionModels` builder); `xcodegen generate` for the new file.
  - DONE 2026-10-14: lint 0 violations, warning-as-error build SUCCEEDED; pull-to-refresh retirement guarded against the mid-gesture retrigger/frozen-offset edge (in-flight flag, deferred end, drag-end/deceleration net, post-dismiss settle net).

## 4. Verify + close out

- [x] 4.1 Re-run the identical 1.1 repro on the fixed tree; record after-evidence (iPad + iPhone, light/dark).
  - DONE 2026-10-14 (final, List.plain build): `evidence/3.1-list-{ipad,iphone}-{light,dark}-{rest,scrolled}.png` — no void, no fade-over-header, no painted rows in the chrome-free nav zone, pinned headers in `.bar` continuous with the bar. Earlier-path evidence (`4.1-after-ipad-pristine.png`, `2.1-final-iphone-rest.png`) covers the intermediate builds.
- [x] 4.2 Run `swiftlint lint --strict`, warning-as-error `xcodebuild` build, and the iOS test suite green (one `xcodebuild` at a time per `docs/ios-test-loop.md`).
  - DONE 2026-10-14 (List.plain tree): swiftlint 0 violations; build **SUCCEEDED**; full suite green (re-run on the List.plain tree after the suite finished; see 4.5). The full suite re-run for the UIKit bridge tree is 4.7.
- [x] 4.3 Re-check `Requirements/FURPS/Timetracking.md` rows for History; fix conflicts if any.
  - DONE 2026-10-14: no conflicts — no FURPS row prescribes header opacity or elevation-gated totals; P2 (60fps scrolling) intact (native List recycling ≥ LazyVStack; the bridge keeps native UIKit cell recycling).
- [x] 4.4 Update `docs/project-context.md` if architecture/contract/run steps changed; run `openspec validate --all --strict`.
  - DONE 2026-10-14: History bullet updated (native `List.plain` sticky headers over `.bar`); Design docs aligned; validate green. RE-PASSED under 4.8 for the UIKit bridge.
- [x] 4.5 Release build + install to the physical iPhone for the user's visual pass.
  - DONE 2026-10-14 (List.plain build). The Release re-install for the UIKit bridge build is 4.9.
- [x] 4.6 On-device verification of the UIKit bridge (user's rectangle complaint resolved): iPhone 16 Pro (iOS 18.6) light+dark, iPad Pro 11" (iOS 27) light — rest: bare two-line headers, no boxes, continuous with the page and nav bar; scrolled: pinned header deterministically occludes rows, nothing above it or in the nav/status zone (pixel-probed bright-glyph scan on the iPhone full-res capture); tap-to-edit push + back with scroll preserved verified on both.
  - Evidence: `evidence/3.2-uikit-table-{iphone-{dark,light},ipad-light}-{rest,scrolled}.png`. Known self-healing edge documented in D6 (synthetic momentum fling into a fast-resolving pull's stretch).
- [x] 4.7 Full gates on the final UIKit-bridge tree: swiftlint all, warning-as-error build, full iOS test suite green.
  - DONE 2026-10-14: swiftlint 0 violations in 179 files; build SUCCEEDED; `xcodebuild test` (iPhone 16 Pro iOS 18.6 sim) **662 tests / 64 suites passed**; `openspec validate --all --strict` 29 passed.
- [x] 4.8 Docs re-pass for the bridge: `Design/SCREENS/History.md` body + implementation checklist, `Design/COMPONENTS.md` (SectionHeader chrome change: `.bar` band removed → page-color occluder baked into the bridge), `docs/project-context.md` History bullet, `openspec validate --all --strict`.
  - DONE 2026-10-14: SCREENS/History.md (Layout bullet → bridge + occluder band; States table; checklist row), COMPONENTS.md (History usage: occluder in `HistoryListTable`, no `.bar`), project-context.md History bullet (bridge + pinned-occlusion rationale), design.md D5 marked superseded + D6 added; validate green earlier in 4.7.
- [x] 4.9 Release build + install to Tony's iPhone for the user's final on-device pass.
  - DONE 2026-10-14: Release build SUCCEEDED; `devicectl device install app` to Tony's iPhone succeeded.

## 5. Tab-bar transparency (in-PR regression, 2026-10-15)

- [x] 5.1 Reproduce on the PR head (`be5eda4`): `UITEST_SCREEN=history` harness, iPhone sim (iOS 18 + 26 if available); slow-scroll screen-recording with a row crossing the tab-bar line, compact timer off then on; file `evidence/5.1-tabbar-{rest,midscroll}[-timer].*`. Confirm Track/Insights still blur (History-local check).
  - DONE 2026-10-15 (agent loop, iPhone 16 Pro iOS 18.6 sim, PR head `703e9ba` incl. rebase): fresh DEBUG build + `SIMCTL_CHILD_UITEST_SCREEN=history` launch; seeded 3 day groups render. Evidence: `5.1-tabbar-rest.png` (rest), `5.1-tabbar-midscroll.png` (row + "12 Oct 2026" header cut hard at the bar's top edge, no blur behind the glass), `5.1-tabbar-scroll.mp4` (slow scroll down+up), `5.1-tabbar-timer.png` (compact timer up mid-list), `5.1-tabbar-bottom-timer.png` (scrolled to bottom: final row fully above the timer — bottom inset already correct, only the under-bar region is missing). History-locality: PR touches only `HistoryView`/`HistoryListTable`/`SectionHeader` (file list) — Track/Insights containers unchanged SwiftUI, so no cross-tab check needed.
- [x] 5.2 Confirm ctx7 bundle recorded in proposal (done above — no separate fetch needed).
- [x] 5.3 Implement design.md D7 (bottom edge-to-edge + bottom inset); top pinning/occlusion untouched; no new strings; `Theme` colors only.
  - DONE 2026-10-15: `HistoryView.historyList` gains `.ignoresSafeArea(.container, edges: .bottom)`; bottom safe area (tab bar + compact timer) measured via a background `GeometryReader` preference outside the ignored subtree (`BottomSafeInsetPreferenceKey`, static per rotation/timer visibility) and passed as `HistoryListTable.bottomContentInset`, applied explicitly to `contentInset.bottom` with `contentInsetAdjustmentBehavior = .never` (first attempt with ignore-only parked the final row behind the timer — the ignore also discards the timer's added safe area; `additionalSafeAreaInsets` does not exist on `UIView`, hence the explicit content inset). Top untouched.
- [x] 5.4 Re-run the identical 5.1 repro on the fixed tree; file after-evidence; rows blur under the bar, final row reachable, timer on/off.
  - DONE 2026-10-15 (same harness/sim): `5.4-tabbar-rest-fixed.png`, `5.4-tabbar-midscroll-fixed.png` ("12 Oct 2026" header ghosted behind the glass bar — blur restored), `5.4-tabbar-timer-fixed.png`, `5.4-tabbar-bottom-timer-fixed.png` (final row fully above the timer at max scroll). Pull-to-refresh retirement re-confirmed en passant (no-backend sync-failure dialog, no wedge).
- [x] 5.5 Gates: `swiftlint lint --strict`, warning-as-error build, focused History tests green (full `xcodebuild test` if the loop allows); `openspec validate --all --strict`.
  - DONE 2026-10-15: swiftlint 0 violations; warning-as-error `xcodebuild build` SUCCEEDED; full `xcodebuild test` (iPhone 16 Pro iOS 18.6 sim) **670 passed / 0 failed, TEST SUCCEEDED**; `openspec validate --all --strict` 26 passed. No backend changes — Go gates N/A.
- [x] 5.6 Docs re-pass (`Design/SCREENS/History.md` checklist if it describes the tab-bar behavior, `docs/project-context.md` only if architecture wording changed); PR description updated with evidence links.
  - DONE 2026-10-15 (docs): `Design/SCREENS/History.md` Body bullet + new checklist row (under-bar content, final-row reachability); `docs/project-context.md` History bullet clause; FURPS re-check — no row prescribes tab-bar opacity (F9 pull flow re-verified live). REMAINS (human): push the branch + update the PR description with the §5 evidence (branch was rebased on `origin/main` locally, so push needs `push --force-with-lease`).

## 6. OS-gated tab bar + expanded scroll seeds (2026-10-15, user verdict)

- [x] 6.1 Gate the D7 bleed on iOS 26+ (`if #available(iOS 26, *)`): ignore + measured inset only there; iOS 18 keeps the default safe-area frame with zero explicit inset. Expand the DEBUG harness to ~264 entries across 12 day groups (deterministic intraday times, a few long names for wrap coverage); production code untouched by seeds.
  - DONE 2026-10-15: `drawsUnderTabBar` gates `ignoresSafeArea` edges + `bottomContentInset` (0 on iOS 18); seeds 12×22=264 (00:05 + hourly slots, ≤89m durations end before midnight; long names ≤50 chars < 60 limit; `createEntry` idempotent on re-run, verified in `LocalStore`).
- [x] 6.2 Verify on both sims with the fresh build: iOS 18 (default bar, no rows beneath it; 264-row scroll; final-row reachability timer off/on) + iOS 27 (glass blur preserved); file `evidence/6.2-*`.
  - DONE 2026-10-15 (same binary, fresh installs): iOS 18 iPhone 16 Pro — 264 rows / 23-page scroll bar across 12 day groups scrolled end to end; tab bar clean at every position (no ghost content); final row `h-11-0` parks fully above the bar at 100%, and above the compact timer with it up (`6.2-ios18-bottom-timer-defaultbar.png`). iOS 27 iPhone 17 — rows ghost behind the floating glass bar mid-scroll (blur preserved). Evidence: `6.2-ios18-bottom-defaultbar.png`, `6.2-ios18-bottom-timer-defaultbar.png`, `6.2-ios27-midscroll-glassbar.png`. (One harness rerun needed uninstall+reinstall: a stale live process skipped re-init and showed a foreign `Repro` row — procedural note, not a product finding.)
- [x] 6.3 Gates: `swiftlint lint --strict`, warning-as-error build, full `xcodebuild test`; `openspec validate --all --strict`.
  - DONE 2026-10-15: swiftlint 0 violations; warning-as-error build SUCCEEDED (proves `if #available(iOS 26, *)` compiles on the project toolchain); full suite **670 passed / 0 failed** on the final code. Validate below.
- [x] 6.4 Docs re-pass for the gating wording (this spec/design already updated here; `Design/SCREENS/History.md` checklist + `docs/project-context.md` only if the OS split isn't reflected).
  - DONE 2026-10-15: `History.md` Body bullet + two checklist rows carry the iOS 18 / 26+ split; `project-context.md` History bullet carries it. REMAINS (human, same as §5): push + PR description update.

## 7. Tighten History header top padding (2026-10-16, user verdict with photo)

- [x] 7.1 Zero the top padding of the History day-group header in the bridge hosting only (editors keep `spacingSmall`); pinned and in-list share the view so both tighten together.
  - DONE 2026-10-16: `.padding(.top, -Theme.spacingSmall)` on the hosted header content (bridge-local; shared component untouched).
- [x] 7.2 Verify on the iOS 27 sim: rest + pinned screenshots, pixel-measure capsule-bottom → title-top before/after; rows/occlusion/timer behavior unchanged.
  - DONE 2026-10-16: header text top moved up exactly 8pt (387px → 363px @3x); pinned header docks tighter with rows occluded underneath, no bleed; rest of behavior untouched.
- [x] 7.3 Docs touch-up (`Design/SCREENS/History.md` History day-group paddings line) + `openspec validate --strict`.
  - DONE 2026-10-16: History.md header bullet carries the zero-top-padding regime. Validate below.

## 8. Adopt native List; delete the bridge (2026-10-16, user verdict — D8)

- [x] 8.1 `HistoryView.historyList` becomes native `List(.plain)` (bare two-line headers with zero top padding, stripped chrome, `.refreshable`, tap parity, `HistoryList` identifier); bar-visibility gating (opaque tab bar on iOS 18, glass on 26+). DELETE `HistoryListTable.swift` + `bottomSafeInset`/preference/`drawsUnderTabBar`/`daySectionModels` machinery; `xcodegen generate` to drop the file reference.
  - DONE 2026-10-16: `List` with stripped chrome + call-site top tightening; `.toolbarBackground(.visible/.automatic, for: .tabBar)` gated by `usesGlassTabBar`; bridge file deleted via `git rm`, `xcodegen generate` dropped the pbxproj reference; lint clean, warning-as-error build SUCCEEDED.
- [x] 8.2 Verify on both sims: rest/pinned/bottom/timer; pinned bleed present-and-accepted (screenshot it); iOS 18 opaque bar, iOS 26+ glass blur; file `evidence/8.2-*`.
  - DONE 2026-10-16 (same binary, fresh installs, 264 seeds): iOS 18 — pinned bleed visible (accepted), tab bar opaque at every position, final row parks above bar/timer (`8.2-ios18-pinned-bleed-opaquebar.png`, `8.2-ios18-bottom-opaquebar.png`, `8.2-ios18-bottom-timer-opaquebar.png`). iOS 27 — pinned bleed + glass-bar ghosts (`8.2-ios27-pinned-bleed-glassbar.png`). (Procedural: stale-process skip + direct-chip-tap misses — uninstall+reinstall and name-picker path used.)
- [x] 8.3 Gates: `swiftlint lint --strict`, warning-as-error build, full `xcodebuild test`; `openspec validate --all --strict`.
  - DONE 2026-10-16: swiftlint 0 violations; build SUCCEEDED; full suite **670 passed / 0 failed**; validate 26 passed.
- [x] 8.4 Docs (`Design/SCREENS/History.md` back to `List`, `COMPONENTS.md` History usage, `docs/project-context.md` History bullet).
  - DONE 2026-10-16: History.md Body bullet + header bullet (zero top padding kept); COMPONENTS.md History usage (bare List headers, bleed accepted); project-context History bullet (List, no bridge). REMAINS (human, same as §§5–7): push + PR description update.

## 9. Remove SectionHeader dead knobs (2026-10-16, user verdict)

- [x] 9.1 Delete `trailing` + `contentLeadingInset` (both unused at every call site; `trailing()` already commented out at runtime); collapse to a plain `View`. Clean the leftover commented modifiers in `HistoryView`.
  - DONE 2026-10-16: plain `struct SectionHeader: View` (title + subtitle); previews dropped `{ EmptyView() }`; HistoryView comment cruft removed. GitHub issue #168 filed for the systematic dead-code sweep.
- [x] 9.2 Gates: `swiftlint lint --strict`, warning-as-error build, full `xcodebuild test`; `openspec validate --all --strict`. Quick sim check that headers render unchanged.
  - DONE 2026-10-16: lint clean; build SUCCEEDED; full suite **670 passed / 0 failed**; validate 26 passed; sim re-check shows identical headers. (Detour worth recording: `let` + default excludes the property from memberwise init — proven with isolated `swiftc` probes — so the simplified struct keeps an explicit `init(title:subtitle:)`.)
- [x] 9.3 Docs (`COMPONENTS.md` signature already updated here).
  - DONE 2026-10-16: signature block shows the plain struct; usage example already matched.
