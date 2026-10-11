import Foundation

import LifioLiveActivityCore

/// Deep links into the app (live-activities change: every Live Activity
/// face taps `lifio://track`). Pure parsing — navigation effects live in
/// `AppNavigationStack` (`requestTrack`) so this stays unit-testable with
/// no SwiftUI dependency. Scheme/host come from the shared contract, so
/// construction (widget) and parsing (app) cannot drift apart.
enum DeepLink: Equatable {
    /// Select the Track tab (the running timer lives there).
    case track
    /// Select the Track tab AND stop the running timer (Island-Stop link —
    /// fix-terminated-stop-saved-face Spike D). Parsed only from the shared
    /// stop URL; anything else matching scheme/host stays plain `.track`.
    case stopTimer

    /// Parses an incoming URL, or nil when it is not a known link
    /// (unknown links are ignored — never routed, never crashed on).
    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme == LiveActivityDeepLink.trackScheme,
              url.host == LiveActivityDeepLink.trackHost
        else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.contains(where: {
            $0.name == LiveActivityDeepLink.stopQueryKey
                && $0.value == LiveActivityDeepLink.stopQueryValue
        }) {
            return .stopTimer
        }
        return .track
    }
}
