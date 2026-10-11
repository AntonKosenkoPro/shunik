import SwiftUI

/// Navigation path ownership.
///
/// `AppNavigationStack` is the `ObservableObject` that owns the path so
/// `EmailEntryView` can push routes into it.
@MainActor
final class AppNavigationStack: ObservableObject {
    @Published var path: [AppRoute] = []
    /// Monotonic counter bumped on every `lifio://track` deep link (Live
    /// Activity tap). `AppShellView` observes it and selects the Track tab.
    /// A counter (not a Bool) so rapid taps never coalesce.
    @Published var trackRequestID = 0
    /// Monotonic counter bumped on every Island-Stop link
    /// (`lifio://track?stop=1` — fix-terminated-stop-saved-face Spike D).
    /// `AppShellView` observes it, selects Track, reloads, and stops the
    /// timer through the exact in-app path. Counter (not Bool) so rapid
    /// taps never coalesce; a tap with no running draft is a graceful
    /// no-op at the stop call.
    @Published var islandStopRequestID = 0

    init(path: [AppRoute] = []) {
        self.path = path
    }

    func push(_ route: AppRoute) {
        path.append(route)
    }

    func requestTrack() {
        trackRequestID += 1
    }

    func requestIslandStop() {
        islandStopRequestID += 1
    }

    /// Clears both tap counters (AI-review round 1: a `filter { $0 > 0 }`
    /// observer replays the counter's CURRENT value on every shell
    /// (re)subscription, and the shell remounts on every sign-in while this
    /// stack outlives it at app scope — without a reset, the NEXT shell
    /// mount after any Island/Track tap re-fires the stale request and can
    /// stop a run the user never stopped). Called from `beginSignOut` next
    /// to the existing path reset; a fresh process starts at zero, so cold
    /// opens are unaffected.
    func resetTapRequests() {
        trackRequestID = 0
        islandStopRequestID = 0
    }
}

/// SwiftUI container view that renders content inside a `NavigationStack`
/// bound to `AppNavigationStack.path`.
struct AppStack<Root: View, Destination: View>: View {
    @ObservedObject var stack: AppNavigationStack
    let destination: (AppRoute) -> Destination
    @ViewBuilder var root: () -> Root

    init(
        stack: AppNavigationStack,
        @ViewBuilder destination: @escaping (AppRoute) -> Destination,
        @ViewBuilder root: @escaping () -> Root
    ) {
        self.stack = stack
        self.destination = destination
        self.root = root
    }

    var body: some View {
        NavigationStack(path: $stack.path) {
            root()
                .navigationDestination(for: AppRoute.self) { route in
                    destination(route)
                }
        }
    }
}
