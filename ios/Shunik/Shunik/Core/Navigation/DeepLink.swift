import Foundation

// swiftlint:disable:next todo
// SHUNIK-TODO: scaffold — the shared Live Activity contract module is gone.
// The scheme/host literals are inlined from the deleted contract.
private enum TrackLink {
    static let scheme = "shunik"
    static let host = "track"
    static let stopQueryKey = "stop"
    static let stopQueryValue = "1"
}

/// Deep links into the app. Pure parsing — navigation effects live in
/// `AppNavigationStack` (`requestTrack`) so this stays unit-testable with
/// no SwiftUI dependency.
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
        guard url.scheme == TrackLink.scheme,
              url.host == TrackLink.host
        else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.contains(where: {
            $0.name == TrackLink.stopQueryKey
                && $0.value == TrackLink.stopQueryValue
        }) {
            return .stopTimer
        }
        return .track
    }
}
