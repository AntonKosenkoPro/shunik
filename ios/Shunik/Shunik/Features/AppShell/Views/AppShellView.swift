import SwiftUI

/// The adaptive shell (§6.1): a `TabView` over Timeline, Pets, Meds,
/// Documents, and Profile. Each tab owns a `NavigationStack` so pushes stay
/// inside the tab. `TimelineView`, `MedicationsView`, and `DocumentsView` are
/// owned by sibling agents and referenced directly — missing definitions fail
/// the build until those changes land (reported to the merger).
struct AppShellView: View {
    @StateObject var vm: AppShellViewModel
    @EnvironmentObject var container: AppContainer

    init(vm: AppShellViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    var body: some View {
        TabView(selection: $vm.selectedTab) {
            NavigationStack {
                TimelineView()
                    .environmentObject(container)
            }
            .tabItem {
                Label(L10n.timelineTitle.text, systemImage: "list.bullet")
            }
            .tag(ShellTab.timeline)

            NavigationStack {
                PetsView()
                    .environmentObject(container)
            }
            .tabItem {
                Label(L10n.petsTitle.text, systemImage: "pawprint")
            }
            .tag(ShellTab.pets)

            NavigationStack {
                MedicationsView()
                    .environmentObject(container)
            }
            .tabItem {
                Label(L10n.medsTitle.text, systemImage: "pill")
            }
            .tag(ShellTab.meds)

            NavigationStack {
                DocumentsView()
                    .environmentObject(container)
            }
            .tabItem {
                Label(L10n.docsTitle.text, systemImage: "folder")
            }
            .tag(ShellTab.documents)

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
            .tabItem {
                Label(L10n.profileTitle.text, systemImage: "person")
            }
            .tag(ShellTab.profile)
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
