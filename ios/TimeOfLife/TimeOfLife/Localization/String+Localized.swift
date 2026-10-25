import Foundation

/// Compile-time-safe localization keys. Each case maps to a key in
/// `Localizable.strings` (en + ru). The single test in `LocalizationTests`
/// asserts every case resolves in both bundles.
enum L10n: String, CaseIterable {
    // App
    case appName = "app.name"

    // Welcome
    case welcomeTagline = "welcome.tagline"
    case welcomeContinueWithEmail = "welcome.continueWithEmail"

    // Auth gate (account-bound-local-data: required-voice launch gate)
    case authGateTitle = "authGate.title"

    // Email entry (passwordless)
    case emailEntryTitle = "emailEntry.title"
    case emailEntryEmail = "emailEntry.email"
    case emailEntrySubtitle = "emailEntry.subtitle"
    case emailEntrySubmit = "emailEntry.submit"

    // OTP entry
    case otpTitle = "otp.title"
    case otpSentTo = "otp.sentTo"
    case otpResend = "otp.resend"
    case otpResendCountdown = "otp.resendCountdown"
    // OTP field VoiceOver copy (was hardcoded in `OtpCodeField`).
    case otpCodeLabel = "otp.codeLabel"
    case otpCodeHint = "otp.codeHint"

    // Apple
    case appleSignInTitle = "appleSignIn.title"
    case appleSignInError = "appleSignIn.error"

    // Timer (plain-text capture, remove-activities-layer)

    // Live Activity end-card (renders in the widget extension from the
    // shared strings; the case exists so LocalizationTests pins the key
    // in both bundles).

    // App shell
    case profileTitle = "profile.title"
    case profileAccount = "profile.account"
    case profileSignOut = "profile.signOut"
    case profileSyncNow = "profile.syncNow"
    case profileSyncing = "profile.syncing"
    case profileSyncedSuccessfully = "profile.syncedSuccessfully"
    case profileLastSyncedAgo = "profile.lastSynced.ago"
    case profileLastSyncedJustNow = "profile.lastSynced.justNow"
    case profileSyncError = "profile.syncError"
    case profileEraseLocalDataConfirmMessage = "profile.eraseLocalDataConfirmMessage"
    case profileEraseConfirm = "profile.eraseConfirm"
    case profileEraseCancel = "profile.eraseCancel"
    case profileVersionDebugSuffix = "profile.versionDebugSuffix"

    // Destination empty states

    // History day groups (history-entry-list spec)

    // History pull-to-refresh (history-pull-to-sync change)

    // Common
    case commonOk = "common.ok"
    case commonAnd = "common.and"

    // Validation (AuthValidator unified messages, Requirements U4)
    case validationEmailEmpty = "validation.emailEmpty"
    case validationEmailPrefix = "validation.email.prefix"
    case validationEmailRuleInvalid = "validation.email.rule.invalid"
    case validationEmailRuleTooLong = "validation.email.rule.tooLong"
    case validationOtpEmpty = "validation.otpEmpty"
    case validationOtpPrefix = "validation.otp.prefix"
    case validationOtpRuleInvalid = "validation.otp.rule.invalid"

    // Unified entry form (entry-editor spec: CREATE + EDIT + LOCKED modes)
    // Calendar-grammar icon buttons (fix-50-nav-buttons): VoiceOver labels
    // for the X dismiss (CREATE sheet) and the checkmark confirms.

    // History manual entry (add-manual-entry)

    // Name picker (dedicated-name-picker: shared push page)
    case nameClear = "name.clear"
    // Notes editor live counter (extend-notes-limit: `<name> • <n>/2000`,
    // name omitted when empty)
    // Manage categories (category-management D4)
    case errorLocalPersistence = "error.localPersistence"

    // Sign out confirmation
    case signOutCancel = "signOut.cancel"

    // Account (Profile → Account; app-shell + account-deletion specs)
    case accountTitle = "account.title"
    case accountIdentitySection = "account.identitySection"
    case accountIdentityFooter = "account.identityFooter"
    case accountThisDeviceSection = "account.thisDeviceSection"
    case accountThisDeviceFooter = "account.thisDeviceFooter"
    case accountDeleteLocalData = "account.deleteLocalData"
    case accountSignOutConfirmTitle = "account.signOutConfirmTitle"
    case accountSignOutConfirmMessage = "account.signOutConfirmMessage"
    case accountPermanentSection = "account.permanentSection"
    case accountPermanentFooter = "account.permanentFooter"
    case accountDeleteTitle = "account.deleteTitle"
    case accountDeleteMessage = "account.deleteMessage"
    case accountDeleteConfirm = "account.deleteConfirm"
    case accountDeletingProgress = "account.deletingProgress"
    case accountDeleteError = "account.deleteError"
    case accountDeleteFailedTitle = "account.deleteFailedTitle"
    case accountDeleteOffline = "account.deleteOffline"
    case accountDeleteOfflineTitle = "account.deleteOfflineTitle"
    case accountStillExists = "account.stillExists"
    case accountStillExistsTitle = "account.stillExistsTitle"
    case accountPendingAppleUnlink = "account.pendingAppleUnlink"
    case accountCleanupRetryTitle = "account.cleanupRetryTitle"
    case accountCleanupRetryMessage = "account.cleanupRetryMessage"
    case accountCleanupRetryConfirm = "account.cleanupRetryConfirm"

    /// Resolves the key via `NSLocalizedString` against `Localizable.strings`.
    var text: String {
        NSLocalizedString(rawValue, comment: "")
    }

}

extension String {
    /// Convenience for ad-hoc keys not enumerated in `L10n` (e.g. server error
    /// codes). Falls back to the key itself if missing.
    static func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

/// Maps an `APIError` to a localized user-facing string via its error `code`.
enum ErrorLocalization {
    static func message(for error: APIError) -> String {
        switch error {
        case .offline: return L10n.text(in: .default, code: "error.offline")
        case let .server(code, _, _): return L10n.text(in: .default, code: "error.\(code)")
        case let .authenticationRejected(code, _, _): return L10n.text(in: .default, code: "error.\(code)")
        case .unauthorized: return L10n.text(in: .default, code: "error.unauthorized")
        case .storage: return L10n.text(in: .default, code: "error.localPersistence")
        default: return L10n.text(in: .default, code: "error.unknown")
        }
    }
}

extension L10n {
    /// Looks up a server-error-style key (`error.<code>`) with fallback to
    /// `error.unknown`. Shared by view models and tests.
    static func text(in bundle: BundleProvider, code: String) -> String {
        let key = "error.\(code)"
        let value = NSLocalizedString(key, bundle: bundle.bundle, comment: "")
        return value == key ? NSLocalizedString("error.unknown", bundle: bundle.bundle, comment: "") : value
    }
}

/// Indirection over `Bundle` so tests can swap bundles for the localization
/// parity check.
struct BundleProvider {
    let bundle: Bundle
    static var `default`: BundleProvider { BundleProvider(bundle: .main) }
}
