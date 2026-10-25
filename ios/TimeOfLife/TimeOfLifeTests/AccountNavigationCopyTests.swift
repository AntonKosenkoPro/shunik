import Testing
import Foundation
@testable import TimeOfLife

/// Account navigation and copy contract (Account.md + app-shell D1/D2):
/// Profile links to Account with a stable id and keeps sync/Categories/
/// version; Account carries the email, Sign out, Delete local data, and the
/// single explicit permanent-deletion action. The destructive row, alert
/// title, and confirmation button share the exact same naming in EN + RU.
@Suite("Account navigation and copy")
struct AccountNavigationCopyTests {

    private func bundle(_ locale: String) throws -> Bundle {
        let main = Bundle.main
        let path = try #require(main.path(forResource: locale, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private func string(_ key: String, locale: String) throws -> String {
        NSLocalizedString(key, bundle: try bundle(locale), comment: "")
    }

    // MARK: - Stable identifiers

    // MainActor: the referenced view statics are MainActor-isolated.
    @MainActor
    @Test("Profile links to Account with a stable row id")
    func profileAccountRowId() {
        #expect(ProfileView.accountRowAccessibilityId == "ProfileAccountRow")
    }

    @MainActor
    @Test("Account rows and progress keep the Account.md identifiers")
    func accountRowIds() {
        #expect(AccountView.emailAccessibilityId == "AccountEmailValue")
        #expect(AccountView.deleteLocalDataAccessibilityId == "AccountDeleteLocalDataButton")
        #expect(AccountView.deleteAccountAccessibilityId == "AccountDeleteAccountButton")
        #expect(AccountView.deletionProgressAccessibilityId == "AccountDeletionProgress")
    }

    @MainActor
    @Test("Sign out keeps its icon and accessibility id in Account")
    func signOutIdentityKept() {
        #expect(ProfileView.signOutAccessibilityId == "ProfileSignOutButton")
        #expect(ProfileView.signOutIcon == "rectangle.portrait.and.arrow.right")
    }

    // MARK: - Explicit naming (D2): row, title, and button match

    @Test("permanent deletion names account + local data everywhere in EN")
    func explicitNamingEN() throws {
        let row = try string("account.deleteConfirm", locale: "en")
        let title = try string("account.deleteTitle", locale: "en")
        let message = try string("account.deleteMessage", locale: "en")
        #expect(row == "Delete account and local data")
        #expect(title == "Delete account and local data?")
        #expect(message.contains("permanently deletes"))
        #expect(message.contains("synced data"))
        #expect(message.contains("Other devices will be signed out")
            || message.contains("Your other devices will be signed out"))
    }

    @Test("permanent deletion names account + local data everywhere in RU")
    func explicitNamingRU() throws {
        let row = try string("account.deleteConfirm", locale: "ru")
        let title = try string("account.deleteTitle", locale: "ru")
        let message = try string("account.deleteMessage", locale: "ru")
        #expect(row == "Удалить аккаунт и локальные данные")
        #expect(title == "Удалить аккаунт и локальные данные?")
        #expect(message.contains("навсегда"))
    }

    @Test("section helpers distinguish session, device, and permanent scopes")
    func helperCopy() throws {
        for locale in ["en", "ru"] {
            let identity = try string("account.identityFooter", locale: locale)
            let device = try string("account.thisDeviceFooter", locale: locale)
            let permanent = try string("account.permanentFooter", locale: locale)
            #expect(!identity.isEmpty)
            #expect(!device.isEmpty)
            #expect(!permanent.isEmpty)
            #expect(identity != device)
            #expect(device != permanent)
        }
        #expect(try string("account.thisDeviceSection", locale: "en") == "This Device")
        #expect(try string("account.permanentSection", locale: "en") == "Permanent Deletion")
    }

    @Test("titles are short and distinct from their messages")
    func noticeTitlesDistinct() throws {
        let pairs = [
            ("account.deleteFailedTitle", "account.deleteError"),
            ("account.deleteOfflineTitle", "account.deleteOffline"),
            ("account.stillExistsTitle", "account.stillExists"),
            ("account.cleanupRetryTitle", "account.cleanupRetryMessage"),
        ]
        for locale in ["en", "ru"] {
            for (titleKey, messageKey) in pairs {
                let title = try string(titleKey, locale: locale)
                let message = try string(messageKey, locale: locale)
                #expect(!title.isEmpty)
                #expect(title != message, "\(titleKey) must differ from its message in \(locale)")
            }
        }
        #expect(try string("account.deleteFailedTitle", locale: "en") == "Couldn't delete account")
        #expect(try string("account.deleteOfflineTitle", locale: "en") == "You're offline")
        #expect(try string("account.stillExistsTitle", locale: "en") == "Account still exists")
    }

    @Test("status, progress, and retry copy resolve in both locales")
    func statusCopy() throws {
        for locale in ["en", "ru"] {
            #expect(!(try string("account.deletingProgress", locale: locale)).isEmpty)
            #expect(!(try string("account.deleteError", locale: locale)).isEmpty)
            #expect(!(try string("account.deleteOffline", locale: locale)).isEmpty)
            #expect(!(try string("account.stillExists", locale: locale)).isEmpty)
            #expect(!(try string("account.pendingAppleUnlink", locale: locale)).isEmpty)
            #expect(!(try string("account.cleanupRetryTitle", locale: locale)).isEmpty)
            #expect(!(try string("account.cleanupRetryMessage", locale: locale)).isEmpty)
            #expect(!(try string("account.cleanupRetryConfirm", locale: locale)).isEmpty)
        }
        #expect(try string("account.deletingProgress", locale: "en") == "Deleting account…")
    }

    // MARK: - L10n coverage

    @Test("every new key resolves through L10n in both bundles")
    func l10nKeysResolve() {
        let keys: [L10n] = [
            .accountTitle, .accountIdentitySection, .accountIdentityFooter,
            .accountThisDeviceSection, .accountThisDeviceFooter, .accountDeleteLocalData,
            .accountPermanentSection, .accountPermanentFooter,
            .accountDeleteTitle, .accountDeleteMessage, .accountDeleteConfirm,
            .accountDeletingProgress, .accountDeleteError, .accountDeleteFailedTitle,
            .accountDeleteOffline, .accountDeleteOfflineTitle,
            .accountStillExists, .accountStillExistsTitle, .accountPendingAppleUnlink,
            .accountCleanupRetryTitle, .accountCleanupRetryMessage, .accountCleanupRetryConfirm,
        ]
        for key in keys {
            #expect(!key.text.isEmpty)
            #expect(key.text != key.rawValue)
        }
    }
}
