import Testing
import Foundation
import UIKit
@testable import Shunik

/// Sign-out row contract (fix-profile-signout-row, issue #68): Profile's
/// Sign Out SHALL share the `ListRow` geometry, leading icon, and danger
/// tint of the Erase local data row. Views are not introspected in this
/// suite, so the test pins what logic can pin — the profile-scoped key, the
/// unchanged copy in both locales, the icon constant and its SF Symbol
/// resolution, and the stable accessibility id. The tint itself stays
/// manual-smoke + review (`Theme.danger` is a named asset `Color`).
@MainActor
@Suite("Profile Sign Out Row")
struct ProfileSignOutRowTests {

    @Test("sign-out key is profile-scoped")
    func keyIsProfileScoped() {
        #expect(L10n.profileSignOut.rawValue == "profile.signOut")
    }

    @Test("sign-out copy is unchanged in both locales")
    func copyUnchanged() throws {
        let main = Bundle.main
        let enPath = try #require(main.path(forResource: "en", ofType: "lproj"))
        let ruPath = try #require(main.path(forResource: "ru", ofType: "lproj"))
        let en = try #require(Bundle(path: enPath))
        let ru = try #require(Bundle(path: ruPath))
        #expect(NSLocalizedString("profile.signOut", bundle: en, comment: "") == "Sign Out")
        #expect(NSLocalizedString("profile.signOut", bundle: ru, comment: "") == "Выйти")
    }

    @Test("sign-out icon constant resolves as an SF Symbol")
    func iconResolves() {
        #expect(!ProfileView.signOutIcon.isEmpty)
        #expect(UIImage(systemName: ProfileView.signOutIcon) != nil)
    }

    @Test("sign-out accessibility id is stable")
    func accessibilityIdStable() {
        #expect(ProfileView.signOutAccessibilityId == "ProfileSignOutButton")
    }
}
