import ActivityKit
import SwiftUI
import WidgetKit

import LifioLiveActivityCore

/// Live Activity presentations for the running timer (live-activities
/// spec: "Island and banner presentations").
///
/// Content rule: exact name + first-category icon only — no category
/// names, provenance labels, notes, or started-at lines. Elapsed faces
/// tick on-system via `Text(timerInterval:)` (no `update()` calls); the
/// icon arrives pre-validated from the app (`CatalogIcon.displaySymbol`
/// at request time, `"timer"` fallback), so the extension never validates.
struct TimerLiveActivityWidget: Widget {
    /// Deep link to Track (D5): every face navigates here on tap. Delegates
    /// to the shared contract — never a local literal (drift kills taps).
    private var trackURL: URL? {
        LiveActivityDeepLink.trackURL
    }

    /// Stop link for the expanded Island pill (fix-terminated-stop-saved-face
    /// Spike D): tapping it opens the app and the app stops itself. Shares
    /// the `trackURL` contract family — never a local literal.
    private var trackStopURL: URL? {
        LiveActivityDeepLink.stopURL
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            if let saved = context.state.savedDurationSeconds {
                savedBanner(duration: TimerClock.formatted(saved))
            } else {
                runningBanner(
                    text: context.attributes.entryText,
                    iconSymbol: context.attributes.iconSymbol,
                    startedAt: context.state.startedAt
                )
            }
        } dynamicIsland: { context in
            DynamicIsland {
                // Layout (device finding): timer top-left, Stop top-right,
                // name full-width along the bottom for longer texts. No
                // visible Go-to control — tapping anywhere outside Stop
                // navigates via widgetURL.
                DynamicIslandExpandedRegion(.leading) {
                    expandedTimer(context: context)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        // Hugging capsule, restored after the debug-blue
                        // removal took the border with it: subtle white —
                        // the island is always black (see LiveActivityTheme).
                        .overlay(Capsule().stroke(LiveActivityTheme.timerBorder, lineWidth: 1))
                        .widgetURL(trackURL)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack {
                        if context.state.savedDurationSeconds == nil {
                            // Spike D: a Link, not the intent button — the
                            // widget cannot stop anything with the app dead
                            // (Spikes A–C), so opening the app IS the stop.
                            // Nil URL is impossible (literal contract), but
                            // the intent pill stays as the fail-safe so Stop
                            // never vanishes.
                            if let stopURL = trackStopURL {
                                LiveActivityStopLink(destination: stopURL)
                            } else {
                                LiveActivityStopPill()
                            }
                        } else {
                            Image(systemName: "checkmark")
                                .font(.title2)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .widgetURL(trackURL)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Image(systemName: context.attributes.iconSymbol)
                        Text(context.attributes.entryText)
                            .font(.headline)
                            .lineLimit(2)
                    }
                    // Same trailing breathing room as the timer above —
                    // keeps long names clear of the island's curve.
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .accessibilityLabel(LiveActivityStrings.runningAccessibilityLabel(text: context.attributes.entryText))
                    .widgetURL(trackURL)
                }
            } compactLeading: {
                Image(systemName: context.attributes.iconSymbol)
                    .widgetURL(trackURL)
            } compactTrailing: {
                islandElapsed(context: context)
                    // Explicit width (proven on-device; the twin-overlay
                    // experiment does not constrain in the compact slot).
                    // The timer view has no intrinsic size — it fills any
                    // proposal (edge-to-edge pill) and collapses to zero
                    // under fixedSize. 52pt fits H:MM:SS in the ~52–62pt
                    // slot; monospaced digits keep shorter values stable.
                    .frame(width: 52, alignment: .trailing)
                    .widgetURL(trackURL)
            } minimal: {
                Image(systemName: context.attributes.iconSymbol)
                    .widgetURL(trackURL)
            }
        }
    }

    // MARK: - Lock Screen banner

    // Banner: icon + name + live ticking timer + Stop. No luminance
    // branch, no accent wrappers: the AoD blank was a device setting
    // (Face ID & Passcode → Allow Access When Locked → Live Activities),
    // not rendering — the system dims the live timer itself, like Apple's.
    private func runningBanner(text: String, iconSymbol: String, startedAt: Date) -> some View {
        HStack(spacing: 12) {
            // Deep-link zone scoped to the label: the root must NOT carry
            // widgetURL — a root URL also engages on Stop taps and demands
            // unlock on a locked phone (device finding), fighting the
            // alwaysAllowed intent. Body taps still go to Track.
            // NOTE (Spike E log-proven): the outer stack must NOT combine
            // accessibility children — `.accessibilityElement(children:
            // .combine)` collapses both widgetURLs into one element and the
            // label-zone track URL wins every Stop tap (log showed
            // `lifio://track` on a Stop tap). Each zone stays its own
            // accessible element so the Stop circle keeps its stop URL.
            HStack(spacing: 12) {
                Image(systemName: iconSymbol)
                    .font(.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(.headline)
                        .lineLimit(1)
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        // Subheadline monospaced: legible dimmed without
                        // crowding the name line (device-tuned).
                        .font(.subheadline.monospacedDigit())
                        .lineLimit(1)
                }
            }
            .widgetURL(trackURL)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(LiveActivityStrings.runningAccessibilityLabel(text: text))
            Spacer()
            // Spike E: a stop-URL link, not the intent button — tapping it
            // opens the app and the app stops itself (same mechanism as the
            // Island pill). Sibling widgetURL scoping (no root URL, no outer
            // combine — see above). Nil URL is impossible (literal
            // contract), but the intent button stays as the fail-safe so
            // Stop never vanishes.
            if let stopURL = trackStopURL {
                LiveActivityStopCircleLink(destination: stopURL)
            } else {
                LiveActivityStopButton()
            }
        }
        // Banner breathing room, verified on-device: 8pt vertical (flush
        // edges otherwise) + 8pt horizontal.
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    }

    private func savedBanner(duration: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.headline)
            Text(LiveActivityStrings.savedCardTitle(duration: duration))
                .font(.headline)
        }
        .widgetURL(trackURL)
    }

    // MARK: - Dynamic Island

    /// Compact trailing timer: plain live view; the width contract lives
    /// at the call site (`.frame(width: 52)` — see there for why).
    private func islandElapsed(context: ActivityViewContext<TimerActivityAttributes>) -> some View {
        Group {
            if let saved = context.state.savedDurationSeconds {
                Text(TimerClock.formatted(saved))
            } else {
                Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
            }
        }
        .font(.caption.monospacedDigit())
        // View-level alignment comes from the call-site frame; this aligns
        // the glyph run inside the (filled) text box — without it the
        // digits sit leading despite the trailing frame.
        .multilineTextAlignment(.trailing)
        .accessibilityLabel(LiveActivityStrings.runningAccessibilityLabel(text: context.attributes.entryText))
    }
    
    /// Expanded leading timer with a dynamically hugging border: the
    /// capsule wraps the visible digits only and grows with them
    /// (`0:01` narrow → `1:23:45` wide). The live timer view has no
    /// intrinsic size (it fills any proposal and collapses to zero under
    /// fixedSize), so the size comes from a hidden static twin in the same
    /// format (`TimerClock.liveStyle`) that the live view fills exactly —
    /// no fixed points, so Dynamic Type stays safe. The twin freezes at
    /// render time: a phase crossing (59→1:00) without a re-render keeps
    /// the previous width until the next render.
    private func expandedTimer(context: ActivityViewContext<TimerActivityAttributes>) -> some View {
        let totalSeconds: Int = {
            if let saved = context.state.savedDurationSeconds {
                return saved
            }
            return max(0, Int(Date().timeIntervalSince(context.state.startedAt)))
        }()
        return Group {
            if context.state.savedDurationSeconds != nil {
                Text(TimerClock.liveStyle(totalSeconds))
            } else {
                // Overlay (not ZStack): overlay content takes no part in
                // layout, so the hidden twin alone sizes the capsule and
                // the live view fills exactly that rect. (A ZStack sizes
                // to every child including the stretchy live view, which
                // is why the border went full-width again.)
                Text(TimerClock.liveStyle(totalSeconds))
                    .hidden()
                    .overlay(alignment: .leading) {
                        Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                    }
            }
        }
        .font(.subheadline.monospacedDigit())
        .accessibilityLabel(LiveActivityStrings.runningAccessibilityLabel(text: context.attributes.entryText))
    }
}

/// Circular Stop control shared by the banner and the expanded card (the
/// `CompactTimer` language: white glyph on a danger-red circle).
///
/// Always rendered, including dimmed faces: the button lives in the same
/// HStack row as the timer, so it cannot change the banner height, and
/// the postmortem showed the AoD blank was a device setting (Face ID &
/// Passcode → Allow Access When Locked → Live Activities), not rendering —
/// hiding the control would only remove a working lock-screen action.
struct LiveActivityStopButton: View {
    @Environment(\.isLuminanceReduced)
    private var isLuminanceReduced

    var body: some View {
        Button(intent: StopTimerIntent()) {
            LiveActivityStopCircleLabel()
        }
        .buttonStyle(.plain)
        // AoD: dimmed and inert (pocket-stop protection — the auth policy
        // covers the woken-locked case, this covers the dimmed case).
        .disabled(isLuminanceReduced)
        .opacity(isLuminanceReduced ? 0.4 : 1.0)
        .accessibilityLabel(LiveActivityStrings.stopAccessibilityLabel)
    }
}

/// The circle's visuals, shared by the intent button (banner `Link`
/// fallback) and the stop `Link` (Spike E) — one shape, never two,
/// mirroring `LiveActivityStopPillLabel` for the pill.
struct LiveActivityStopCircleLabel: View {
    var body: some View {
        Image(systemName: "stop.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(LiveActivityTheme.stopForeground)
            .frame(width: 44, height: 44)
            .background(LiveActivityTheme.stopBackground)
            .clipShape(Circle())
    }
}

/// Circular Stop link for the banner (Spike E): the `Link` twin of the
/// Island's pill — the sibling-`widgetURL` shape log-proved to lose (Stop
/// taps delivered `lifio://track`), so the banner now mirrors the
/// device-proven Island shape (`Link` inside a `widgetURL` zone). Tapping it
/// opens the app at the stop URL and the app stops itself; the banner keeps
/// the intent button only as the nil-URL fail-safe. Identical circle visuals
/// and AoD-dimmed/inert rule.
struct LiveActivityStopCircleLink: View {
    @Environment(\.isLuminanceReduced)
    private var isLuminanceReduced

    let destination: URL

    var body: some View {
        Link(destination: destination) {
            LiveActivityStopCircleLabel()
        }
        .disabled(isLuminanceReduced)
        .opacity(isLuminanceReduced ? 0.4 : 1.0)
        .accessibilityLabel(LiveActivityStrings.stopAccessibilityLabel)
    }
}

/// Pill Stop control for the expanded card (circle lives on the banner —
/// one shape per face, no experiment pending).
/// Same always-render rule as `LiveActivityStopButton`.
struct LiveActivityStopPill: View {
    @Environment(\.isLuminanceReduced)
    private var isLuminanceReduced

    var body: some View {
        Button(intent: StopTimerIntent()) {
            LiveActivityStopPillLabel()
        }
        .buttonStyle(.plain)
        // Same AoD-dimmed/inert rule as `LiveActivityStopButton`.
        .disabled(isLuminanceReduced)
        .opacity(isLuminanceReduced ? 0.4 : 1.0)
        .accessibilityLabel(LiveActivityStrings.stopAccessibilityLabel)
    }
}

/// The pill's visuals, shared by the intent button (Link fallback) and the
/// stop `Link` (Spike D) — one shape, never two.
struct LiveActivityStopPillLabel: View {
    var body: some View {
        Label(LiveActivityStrings.stopTitle, systemImage: "stop.fill")
            .font(.subheadline)
            .foregroundStyle(LiveActivityTheme.stopForeground)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(LiveActivityTheme.stopBackground)
            .clipShape(Capsule(style: .continuous))
    }
}

/// Link Stop control for the expanded Island card
/// (fix-terminated-stop-saved-face Spike D): opens the app at the stop URL
/// and the app stops itself — the widget cannot stop anything with the app
/// dead (Spikes A–C device-proven). Identical pill visuals; the banner uses
/// the `widgetURL` circle twin (Spike E), keeping the intent pill only as
/// the nil-URL fail-safe.
struct LiveActivityStopLink: View {
    @Environment(\.isLuminanceReduced)
    private var isLuminanceReduced

    let destination: URL

    var body: some View {
        Link(destination: destination) {
            LiveActivityStopPillLabel()
        }
        // Same AoD-dimmed/inert rule as the intent controls.
        .disabled(isLuminanceReduced)
        .opacity(isLuminanceReduced ? 0.4 : 1.0)
        .accessibilityLabel(LiveActivityStrings.stopAccessibilityLabel)
    }
}
