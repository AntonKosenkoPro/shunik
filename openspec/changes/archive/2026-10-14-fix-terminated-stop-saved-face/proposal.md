## Why

Stopping the running timer from the Live Activity (Dynamic Island expanded card or Lock Screen banner) while the app process is dead — swiped away from the App Switcher or jetsammed by the system — saves the entry correctly but leaves the widget frozen on the ticking running face indefinitely. The widget looks unresponsive even though the recording ended. Dismissal without the app is not required; the widget must at least show the `✓ Saved` state so the user sees their entry was saved.

Spike B (2026-10-10, device) killed the file-sidecar approach: with the full sidecar path live, a terminated-app Island Stop saved the entry, cleared the draft, and wrote the sidecar — but the face stayed "timer running" with Stop offered (AX-verified across minutes). The `Text(timerInterval:)` tick does not re-evaluate the `ActivityConfiguration` body, and no intent-process API can push new content (Spike A: enumeration empty even as `LiveActivityIntent`). Spike C then killed the `openAppWhenRun` pivot: the OS rejects it in extensions (`LNContextErrorDomain Code=2001`, button goes fully dead — device-proven). This change therefore lands the Link-based open-and-stop for the expanded Island (Spike D, user decision 2026-10-10, device-proven single-tap): the Island Stop pill is a `Link` to `lifio://track?stop=1`, and the opened app stops/saves through the exact in-app path. The banner keeps the intent button (saves, no open — its terminated-app tick-until-contact is a known, banner-scoped limitation).

## What Changes

- The expanded Island Stop pill becomes a `Link` to `lifio://track?stop=1` (shared `LiveActivityDeepLink` contract): tapping Stop opens the app, which performs reload-then-stop through the exact in-app path (`AppShellView` observes `AppNavigationStack.islandStopRequestID`, selects Track, `reloadTrack()` then `trackVM.stop()`; no draft → graceful no-op). The save path itself is unchanged (same `LocalStore` transaction, `source='manual'`).
- The sidecar approach (D2–D4: save-record contract, face resolution, reap cleanup) is SUPERSEDED — its code is reverted, not landed — as is the `openAppWhenRun` flag (Spike C: OS-rejected in extensions). No new visual language: the same Saved face the app-side reap already produces.
- `StopTimerIntent` was evaluated for `LiveActivityIntent` conformance as Spike A: the intent process gains no `ActivityKit` enumeration, so the intent updates/ends nothing directly — it only saves and signals, and the opened app ends.
- Non-goals: push-token remote updates (APNs + relay push path — also offline-blind); changing the dismissal timing; any backend/OpenAPI change; any change to the entry save path or provenance (`source='manual'`); banner-face Link (unsupported by the OS — banner stays intent-based).
- Spec change: "Stop works without opening the app" is dropped for the expanded Island — every Island Stop now opens Track (including background-alive stops, which previously ended silently). Banner Stop behavior is unchanged.

## Capabilities

### New Capabilities

None — no new capability; this is a fix inside existing behavior.

### Modified Capabilities

- `live-activities`: Stop from the expanded Island SHALL open the app and stop/save through the in-app path (single tap, including with a terminated app), instead of ticking the running face indefinitely. Banner Stop keeps the intent save path (entry saved, face ticks until app contact when dead). The "Stop with a terminated app dismisses silently" scenario is narrowed: silent dismiss remains only when no save is known; a known Island save opens the app and shows the Saved card.

## Impact

- iOS only: `LifioLiveActivityCore/LiveActivityDeepLink.swift` (`stopURL`), `TimeOfLife/Core/Navigation/DeepLink.swift` (`.stopTimer`), `TimeOfLife/Core/Navigation/AppNavigationStack.swift` (`islandStopRequestID`), `TimeOfLife/App/TimeOfLifeApp.swift` (`onOpenURL` routing), `TimeOfLife/Features/AppShell/Views/AppShellView.swift` (counter observers), `LifioLiveActivities/TimerLiveActivityWidget.swift` (`LiveActivityStopLink`), `TimeOfLife/Features/TimeTracking/ViewModels/TrackViewModel.swift` (`loadIfNeeded` in-flight wait); reverts of the superseded sidecar code and the `openAppWhenRun` flag; `BackgroundReapScheduler` chain unchanged.
- No backend, OpenAPI, on-disk DB schema, or auth/session changes. No new entitlements or targets.
- External dependency: `Link` in Live Activity extended presentation. ctx7: `/websites/developer_apple_activitykit` — queries "AppIntent button in Live Activity updating activity UI", "LiveActivityIntent openAppWhenRun", "LiveActivityIntent protocol start update end Live Activity", "Link widgetURL Live Activity button open app deep link". Pin: iOS 18 SDK via Xcode 16+.

Affected baseline: `openspec/specs/live-activities/spec.md` (Stop and return actions; Saved card then dismissal). Authoritative docs: `docs/project-context.md` (LocalStore chokepoint, App Group sharing, BG chain), archived `2026-10-10-live-activities` design D8 (intent saves + signals, app ends; extension enumeration empty — device-proven with plain `AppIntent`).
