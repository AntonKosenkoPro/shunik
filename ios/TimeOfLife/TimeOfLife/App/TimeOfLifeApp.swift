import SwiftUI

/// Entry point of the Lifio app.
///
/// Owns the composition root (`AppContainer`). Auth is passwordless: the user
/// enters their email, receives a 6-digit code, and types it on the OTP
/// screen to verify. There is no magic link / deep link — a custom URL scheme
/// only works in Apple Mail (Gmail/Outlook/Proton strip non-https schemes),
/// so the code is simply shown in the email body for the user to read and
/// type on every mail client.
@main
struct TimeOfLifeApp: App {
    @StateObject private var container: AppContainer
    @StateObject private var session: SessionStore
    @StateObject private var navigation: AppNavigationStack

    init() {
        // UI-feedback loop: when launched with `UITEST_SCREEN=<screen>` (or
        // `SIMCTL_CHILD_UITEST_SCREEN=<screen>`, which `simctl launch` preserves)
        // in DEBUG, build a deterministic, stub-backed graph seeded to that
        // screen so the agent can inspect any UI without a real backend. See
        // `AppContainer.uiTesting(screen:)` and the `ios-ui-loop` skill.
        let container: AppContainer
        #if DEBUG
        let uiTestingScreen = Self.uiTestingScreen()
        if let screen = uiTestingScreen, !screen.isEmpty {
            container = AppContainer.uiTesting(screen: screen)
        } else {
            container = AppContainer.production()
        }
        #else
        container = AppContainer.production()
        #endif
        self._container = StateObject(wrappedValue: container)
        self._session = StateObject(wrappedValue: container.sessionStore)
        self._navigation = StateObject(wrappedValue: container.navigation)
    }

    /// Resolves the UI-feedback screen from the environment or launch
    /// arguments. `simctl launch` forwards `KEY=VALUE` pairs, but on modern
    /// simulators iOS does not expose them through `ProcessInfo.environment`,
    /// so also parse `ProcessInfo.arguments` for both `UITEST_SCREEN` and
    /// `SIMCTL_CHILD_UITEST_SCREEN` forms.
    private static func uiTestingScreen() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let screen = env["UITEST_SCREEN"], !screen.isEmpty { return screen }
        if let screen = env["SIMCTL_CHILD_UITEST_SCREEN"], !screen.isEmpty { return screen }

        let args = ProcessInfo.processInfo.arguments
        for (index, arg) in args.enumerated() {
            let key: String
            if arg.hasPrefix("UITEST_SCREEN=") {
                key = "UITEST_SCREEN="
            } else if arg.hasPrefix("SIMCTL_CHILD_UITEST_SCREEN=") {
                key = "SIMCTL_CHILD_UITEST_SCREEN="
            } else if arg == "UITEST_SCREEN" || arg == "SIMCTL_CHILD_UITEST_SCREEN" {
                let next = index + 1
                guard next < args.count else { continue }
                let screen = args[next]
                if !screen.isEmpty { return screen }
                continue
            } else {
                continue
            }
            let screen = String(arg.dropFirst(key.count))
            if !screen.isEmpty { return screen }
        }
        return nil
    }

    var body: some Scene {
        WindowGroup {
            appRoot
        }
    }

    private var appRoot: some View {
        RootView()
            .environmentObject(container)
            .environmentObject(session)
            .environmentObject(navigation)
            // Live Activity taps (`lifio://track`): select the Track tab.
            // Stop links (`lifio://track?stop=1`, Spikes D+E): the app
            // itself performs the stop on open — the widget cannot stop
            // anything with the app dead. Unknown links are ignored
            // (DeepLink.parse returns nil).
            .onOpenURL { url in
                switch DeepLink.parse(url) {
                case .track:
                    navigation.requestTrack()
                case .stopTimer:
                    navigation.requestIslandStop()
                case nil:
                    break
                }
            }
            // Sync status is read directly by Profile (status row, Sync now
            // state) and Manage Categories (reload on idle): it needs its own
            // object in the environment — nested reads through `container`
            // never invalidate the view (the container publishes nothing).
            .environmentObject(container.syncController)
            .preferredColorScheme(nil) // follow system
    }
}
