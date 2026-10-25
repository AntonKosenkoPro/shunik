import Foundation
import Combine

/// Shell destinations (§6.1 adaptive IA): the four pet-care tabs plus the
/// Profile pushed page.
enum ShellRoute: Hashable {
    case profile
    case timeline
    case pets
    case meds
    case documents
}

/// The shell's tabs (one per §6 destination + Profile).
enum ShellTab: Hashable {
    case timeline
    case pets
    case meds
    case documents
    case profile
}

/// View model for the tab shell: the selected tab plus the Profile
/// navigation path (Profile pushes Account the same way as before).
@MainActor
final class AppShellViewModel: ObservableObject {
    /// The Profile navigation path. Profile is a pushed page inside its own
    /// tab; Account pushes from it via caller-local links.
    @Published var profilePath: [ShellRoute] = []
    /// The selected tab.
    @Published var selectedTab: ShellTab = .timeline

    init() {}

    /// Pushes Profile. A no-op when Profile is already on the path.
    func openProfile() {
        if !profilePath.contains(.profile) { profilePath.append(.profile) }
    }

    /// Whether a path transition popped Profile (was present, now absent).
    static func profileWasPopped(old: [ShellRoute], new: [ShellRoute]) -> Bool {
        old.contains(.profile) && !new.contains(.profile)
    }
}
