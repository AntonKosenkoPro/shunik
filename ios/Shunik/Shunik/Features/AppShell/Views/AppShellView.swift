import SwiftUI

// swiftlint:disable:next todo
// SHUNIK-TODO: scaffold — single-destination shell hosting the existing
// ProfileView. Pet-care destinations will be added here.
struct AppShellView: View {
    @StateObject var vm: AppShellViewModel
    @EnvironmentObject var container: AppContainer

    init(vm: AppShellViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    var body: some View {
        NavigationStack(path: $vm.profilePath) {
            ProfileView()
                .environmentObject(container)
                .environmentObject(container.sessionStore)
                .environmentObject(container.syncController)
                .navigationDestination(for: ShellRoute.self) { route in
                    if route == .profile {
                        ProfileView()
                            .environmentObject(container)
                            .environmentObject(container.sessionStore)
                            .environmentObject(container.syncController)
                    }
                }
        }
    }
}

#if DEBUG
#Preview("App Shell") {
    let container = AppContainer.production()
    AppShellView(vm: AppShellViewModel())
        .environmentObject(container)
        .environmentObject(AppNavigationStack())
        .environmentObject(container.syncController)
}
#endif
