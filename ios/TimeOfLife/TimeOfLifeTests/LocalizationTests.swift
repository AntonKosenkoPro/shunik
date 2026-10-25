import Testing
import Foundation
@testable import TimeOfLife

@Suite("Localization")
struct LocalizationTests {

    /// All L10n cases enumerated at runtime.
    private var l10nCases: [L10n] {
        L10n.allCases
    }

    // MARK: - Key resolution

    @Test("all L10n keys resolve to non-empty strings in en.lproj")
    func allKeysResolveEN() throws {
        let main = Bundle.main
        let path = try #require(main.path(forResource: "en", ofType: "lproj"),
                                "Missing en.lproj in main bundle")
        let bundle = try #require(Bundle(path: path))

        for caseValue in l10nCases {
            let value = NSLocalizedString(caseValue.rawValue, bundle: bundle, comment: "")
            #expect(value != caseValue.rawValue,
                    "Unresolved key \(caseValue.rawValue) in en")
            #expect(!value.isEmpty,
                    "Empty value for key \(caseValue.rawValue) in en")
        }
    }

    @Test("all L10n keys resolve to non-empty strings in ru.lproj")
    func allKeysResolveRU() throws {
        let main = Bundle.main
        let path = try #require(main.path(forResource: "ru", ofType: "lproj"),
                                "Missing ru.lproj in main bundle")
        let bundle = try #require(Bundle(path: path))

        for caseValue in l10nCases {
            let value = NSLocalizedString(caseValue.rawValue, bundle: bundle, comment: "")
            #expect(value != caseValue.rawValue,
                    "Unresolved key \(caseValue.rawValue) in ru")
            #expect(!value.isEmpty,
                    "Empty value for key \(caseValue.rawValue) in ru")
        }
    }

    @Test("both locales have the same set of keys")
    func keyParity() throws {
        let main = Bundle.main
        let enPath = try #require(main.path(forResource: "en", ofType: "lproj"))
        let ruPath = try #require(main.path(forResource: "ru", ofType: "lproj"))
        let enBundle = try #require(Bundle(path: enPath))
        let ruBundle = try #require(Bundle(path: ruPath))

        for caseValue in l10nCases {
            let enValue = NSLocalizedString(caseValue.rawValue, bundle: enBundle, comment: "")
            let ruValue = NSLocalizedString(caseValue.rawValue, bundle: ruBundle, comment: "")

            #expect(enValue != caseValue.rawValue,
                    "Key \(caseValue.rawValue) missing in en")
            #expect(ruValue != caseValue.rawValue,
                    "Key \(caseValue.rawValue) missing in ru")
        }
    }

    // MARK: - Error codes

    @Test("known error codes resolve via ErrorLocalization without falling back to unknown")
    func errorCodesResolve() throws {
        let codes = [
            "invalid_body", "internal_error", "rate_limited",
            "invalid_otp", "otp_expired", "otp_attempts_exceeded",
            "invalid_refresh", "token_reuse", "refresh_expired",
            "refresh_attempt_completed", "refresh_attempt_conflict",
        ]
        let unknownText = NSLocalizedString("error.unknown", comment: "")

        for code in codes {
            let msg = L10n.text(in: .default, code: code)
            #expect(!msg.isEmpty)
            #expect(msg != unknownText,
                    "Code \(code) fell back to error.unknown")
        }
    }

    @Test("offline error maps to offline error text")
    func offlineMapping() {
        let msg = ErrorLocalization.message(for: .offline)
        #expect(!msg.isEmpty)
    }

    @Test("refresh recovery codes resolve in en + ru bundles")
    func refreshRecoveryCodesResolve() throws {
        let keys = [
            "error.refresh_attempt_completed",
            "error.refresh_attempt_conflict",
        ]
        let main = Bundle.main

        for code in ["en", "ru"] {
            let path = try #require(main.path(forResource: code, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))

            for key in keys {
                let value = NSLocalizedString(key, bundle: bundle, comment: "")
                #expect(value != key, "Unresolved key \(key) in \(code)")
                #expect(!value.isEmpty, "Empty value for key \(key) in \(code)")
            }
        }
    }

    // MARK: - Validation fragment keys

    @Test("validation fragment keys resolve in en + ru bundles")
    func validationFragmentKeysResolve() throws {
        let keys = [
            "common.and",
            "validation.emailEmpty",
            "validation.email.prefix",
            "validation.email.rule.invalid",
            "validation.email.rule.tooLong",
            "validation.otpEmpty",
            "validation.otp.prefix",
            "validation.otp.rule.invalid",
        ]
        let main = Bundle.main

        for code in ["en", "ru"] {
            let path = try #require(main.path(forResource: code, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))

            for key in keys {
                let value = NSLocalizedString(key, bundle: bundle, comment: "")
                #expect(value != key, "Unresolved key \(key) in \(code)")
                #expect(!value.isEmpty, "Empty value for key \(key) in \(code)")
            }
        }
    }

    // MARK: - L10n enum allCases matches strings files

    /// Sorted-keys snapshot of the `L10n` contract: adding, removing, or
    /// renaming a key fails here with an exact diff (the former
    /// `allCasesCount == 148` only caught count drift and went stale on
    /// every copy change). Update the snapshot deliberately when copy
    /// changes land; the en+ru resolution tests above pin the values.
    @Test("L10n sorted-keys snapshot matches the recorded contract")
    func sortedKeysSnapshot() {
        #expect(l10nCases.map(\.rawValue).sorted() == Self.expectedKeys)
    }

    private static let expectedKeys: [String] = [
        "account.cleanupRetryConfirm",
        "account.cleanupRetryMessage",
        "account.cleanupRetryTitle",
        "account.deleteConfirm",
        "account.deleteError",
        "account.deleteFailedTitle",
        "account.deleteLocalData",
        "account.deleteMessage",
        "account.deleteOffline",
        "account.deleteOfflineTitle",
        "account.deleteTitle",
        "account.deletingProgress",
        "account.identityFooter",
        "account.identitySection",
        "account.pendingAppleUnlink",
        "account.permanentFooter",
        "account.permanentSection",
        "account.signOutConfirmMessage",
        "account.signOutConfirmTitle",
        "account.stillExists",
        "account.stillExistsTitle",
        "account.thisDeviceFooter",
        "account.thisDeviceSection",
        "account.title",
        "app.name",
        "appleSignIn.error",
        "appleSignIn.title",
        "authGate.title",
        "common.and",
        "common.ok",
        "emailEntry.email",
        "emailEntry.submit",
        "emailEntry.subtitle",
        "emailEntry.title",
        "error.localPersistence",
        "name.clear",
        "otp.codeHint",
        "otp.codeLabel",
        "otp.resend",
        "otp.resendCountdown",
        "otp.sentTo",
        "otp.title",
        "profile.account",
        "profile.eraseCancel",
        "profile.eraseConfirm",
        "profile.eraseLocalDataConfirmMessage",
        "profile.lastSynced.ago",
        "profile.lastSynced.justNow",
        "profile.signOut",
        "profile.syncError",
        "profile.syncNow",
        "profile.syncedSuccessfully",
        "profile.syncing",
        "profile.title",
        "profile.versionDebugSuffix",
        "signOut.cancel",
        "validation.email.prefix",
        "validation.email.rule.invalid",
        "validation.email.rule.tooLong",
        "validation.emailEmpty",
        "validation.otp.prefix",
        "validation.otp.rule.invalid",
        "validation.otpEmpty",
        "welcome.continueWithEmail",
        "welcome.tagline",
    ]
}
