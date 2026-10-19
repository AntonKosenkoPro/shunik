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
                RunningBannerFace(
                    text: context.attributes.entryText,
                    iconSymbol: context.state.liveIconSymbol,
                    startedAt: context.state.startedAt,
                    trackURL: trackURL,
                    trackStopURL: trackStopURL
                )
            }
        } dynamicIsland: { context in
            DynamicIsland {
                // Layout: big borderless timer top-left, Stop top-right,
                // name + icon category chips stacked full-width along the
                // bottom. No visible Go-to control — tapping anywhere
                // outside Stop navigates via widgetURL.
                DynamicIslandExpandedRegion(.leading) {
                    expandedTimer(context: context)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.attributes.entryText)
                            .font(.headline)
                            .lineLimit(1)
                        if !context.state.categoryChips.isEmpty {
                            categoryChips(chips: context.state.categoryChips)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Same trailing breathing room as the timer above —
                    // keeps long names clear of the island's curve.
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .accessibilityLabel(LiveActivityStrings.runningAccessibilityLabel(text: context.attributes.entryText))
                    .widgetURL(trackURL)
                }
            } compactLeading: {
                Image(systemName: context.state.liveIconSymbol)
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
                Image(systemName: context.state.liveIconSymbol)
                    .widgetURL(trackURL)
            }
        }
    }

    // MARK: - Lock Screen banner

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
    
    /// Expanded leading timer, big and borderless: the hero
    /// readout of the card. The live timer view has no intrinsic size (it
    /// fills any proposal and collapses to zero under fixedSize), so the
    /// size still comes from a hidden static twin in the same format
    /// (`TimerClock.liveStyle`) that the live view fills exactly via
    /// `overlay` (overlay content takes no part in layout) — no fixed
    /// points, so Dynamic Type stays safe.
    ///
    /// Truncation fix: the twin carries one trailing figure space
    /// (digit-width slack), so a width phase crossing (`9:59`→`10:00`,
    /// `59:59`→`1:00:00` — always a single-digit growth) without a
    /// re-render still fits instead of spilling into the Island curve.
    /// `.lineLimit(1)` + `.minimumScaleFactor` is the backstop: shrink
    /// slightly, never clip.
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
                // is why the border went full-width again.) The trailing
                // figure space is the phase-crossing slack (see above).
                    Text(TimerClock.liveStyle(totalSeconds) + "\u{2007}")
                    .hidden()
                    .overlay(alignment: .leading) {
                        Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                    }
            }
        }
        .font(.title.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityLabel(LiveActivityStrings.runningAccessibilityLabel(text: context.attributes.entryText))
    }

    /// Category chip row for the expanded bottom region: validated SF
    /// Symbol + name per chip. User data, never localized. Cap 2 chips +
    /// `+n` overflow — never a half-clipped third chip. Subtle hairline
    /// capsules (the island is always black).
    private func categoryChips(chips: [LiveCategoryChip]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(chips.prefix(2)), id: \.self) { chip in
                HStack(spacing: 4) {
                    Image(systemName: chip.iconSymbol)
                        .font(.caption2)
                    Text(chip.name)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
            }
            if chips.count > 2 {
                Text("+\(chips.count - 2)")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .lineLimit(1)
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

// Widget-extension previews must go through the Widget (plain View previews
// are "unsupported preview type" in an appex). Pick the Lock Screen banner
// variant in the canvas to see the banner face.
#Preview("Glass banner", as: .content, using: TimerActivityAttributes(entryText: "Glass prototype", iconSymbol: "briefcase.fill")) {
    TimerLiveActivityWidget()
} contentStates: {
    TimerActivityAttributes.ContentState(startedAt: Date().addingTimeInterval(-24))
}
