import SwiftUI
import WidgetKit

import LifioLiveActivityCore

/// Transparent banner face. Content row only — icon + name + live timer +
/// Stop — with breathing-room padding and NO custom container: no
/// `activityBackgroundTint` color, no fill, no gloss, no hairline.
///
/// Why: the system already renders the banner card (blur/material, shape,
/// shadow). A custom smoked fill + gloss + hairline sits *inside* that
/// card — a card-in-a-card with a double edge that reads unnatural. The
/// iOS-native pattern is transparent content; the system owns the glass.
struct RunningBannerFace: View {
    let text: String
    let iconSymbol: String
    let startedAt: Date
    let trackURL: URL?
    let trackStopURL: URL?

    var body: some View {
        // iOS 26+ renders its default Liquid Glass card for `.clear`;
        // older systems have no glass, and `.clear` there degrades to a
        // dark card with unreadable dark content (iOS 18.6
        // simulator-proven) — so omit the tint below 26 and keep the
        // solid system card. Verify on device — Previews and the
        // simulator render this modifier wrong.
        if #available(iOS 26, *) {
            content.activityBackgroundTint(.clear)
        } else {
            content
        }
    }

    private var content: some View {
        // Banner: icon + name + live ticking timer + Stop. No luminance
        // branch, no accent wrappers: the AoD blank was a device setting
        // (Face ID & Passcode → Allow Access When Locked → Live Activities),
        // not rendering — the system dims the live timer itself, like Apple's.
        HStack(spacing: 12) {
            // Deep-link zone scoped to the label: the root must NOT carry
            // widgetURL — a root URL also engages on Stop taps and demands
            // unlock on a locked phone (device finding), fighting the
            // alwaysAllowed intent. Body taps still go to Track.
            // NOTE (log-proven): the outer stack must NOT combine
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
            // A stop-URL link, not the intent button — tapping it
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
        // edges otherwise) + 8pt horizontal. Transparent: the system card
        // behind provides the glass (or the solid card below iOS 26).
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    }
}
