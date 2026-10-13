## 1. Contract + plumbing

- [x] 1.1 Add top-level `LiveCategoryChip` (verbatim name + pre-validated icon symbol) and `ContentState.categoryChips` (default `[]`) in `LifioLiveActivityCore`, keeping `Codable`/`Hashable`
- [x] 1.2 Thread `categoryChips` through `LiveActivityControlling.runStarted` (defaulted), `NoopLiveActivityController`, and `LiveActivityService` (same-text → guarded `activity.update()`, identical chips skip)
- [x] 1.3 Resolve ordered chips in `TimerService` via the existing `store.categories()` id→name map (same pattern as `firstIconSymbol`)
- [x] 1.4 Update `FakeLiveActivities` + `LiveActivityLifecycleTests` to chip assertions, including retag-refresh (same text, new chips → update path) and identical-chips (no update)

## 2. Banner glass

- [x] 2.1 Extract `RunningBannerFace` (icon + name + live timer + Stop, 8pt padding) with transparent content: no tint color, no fill, no gloss, no hairline; sibling-`widgetURL` scoping preserved (no root URL, no outer combine — Stop keeps its stop URL)
- [x] 2.2 Gate `.activityBackgroundTint(.clear)` behind `#available(iOS 26, *)`; omit the tint below 26
- [x] 2.3 Keep Stop always rendered, dimmed and inert under `isLuminanceReduced`

## 3. Island relayout + truncation

- [x] 3.1 Leading region: big borderless `.title` monospaced timer via hidden-twin + `overlay` sizing, figure-space slack, `.lineLimit(1)` + `.minimumScaleFactor(0.8)`; remove capsule and icon
- [x] 3.2 Bottom region: name one line + icon chip row (cap 2 + `+n`, `lineLimit(1)`); trailing Stop unchanged

## 4. Verify

- [x] 4.1 `swiftlint lint --strict`, simulator `BUILD SUCCEEDED`, full `xcodebuild test` + `go test ./...` green, `gofmt -l .` empty
- [x] 4.2 `openspec validate --all` green; FURPS rows re-checked; `docs/project-context.md` updated
- [ ] 4.3 Device proof (acceptance): glass banner on iOS 26+ lock screen incl. light wallpaper + AoD dimmed face + Stop contrast; readable solid banner below 26; expanded chips with 0/2/3 categories; timer crossing `9:59`→`10:00`; mid-run retag refresh; fresh-install Allow prompt path
