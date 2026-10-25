import Foundation
import Combine

// swiftlint:disable:next todo
// SHUNIK-TODO: scaffold — single-destination shell hosting the Profile page.
// Pet-care destinations will be added here as new routes.
enum ShellRoute: Hashable {
    case profile
}

// swiftlint:disable:next todo
// SHUNIK-TODO: extend with pet-care destinations.
/// View model for the scaffold shell: owns the single profile path.
@MainActor
final class AppShellViewModel: ObservableObject {
    /// The profile navigation path. Profile is the shell's single
    /// destination; Account pushes from it via caller-local links.
    @Published var profilePath: [ShellRoute] = []

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
