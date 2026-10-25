import Testing
import Foundation
@testable import Shunik

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
        "common.add",
        "common.all",
        "common.and",
        "common.cancel",
        "common.close",
        "common.delete",
        "common.done",
        "common.edit",
        "common.ok",
        "common.retry",
        "common.save",
        "common.search",
        "common.share",
        "docs.add",
        "docs.deleteMessage",
        "docs.deleteTitle",
        "docs.empty",
        "docs.emptyHint",
        "docs.linkedPets",
        "docs.noPets",
        "docs.notReady",
        "docs.rename",
        "docs.search",
        "docs.title",
        "docs.titleLabel",
        "docs.uploadFailed",
        "docs.uploading",
        "docs.waitingUpload",
        "emailEntry.email",
        "emailEntry.submit",
        "emailEntry.subtitle",
        "emailEntry.title",
        "error.localPersistence",
        "event.add",
        "event.batch",
        "event.deleteMessage",
        "event.deleteTitle",
        "event.kind.grooming",
        "event.kind.vaccination",
        "event.kind.weight",
        "event.nextDue",
        "event.nextDue.none",
        "event.notes",
        "event.occurredOn",
        "event.place",
        "event.service",
        "event.title",
        "event.vaccine",
        "event.vet",
        "meds.adherence",
        "meds.course.add",
        "meds.course.edit",
        "meds.courses",
        "meds.dose",
        "meds.doseUnit",
        "meds.drug",
        "meds.due",
        "meds.duration",
        "meds.empty",
        "meds.emptyHint",
        "meds.endsOn",
        "meds.infoRef",
        "meds.instructions",
        "meds.intake.missed",
        "meds.intake.pending",
        "meds.intake.skipped",
        "meds.intake.taken",
        "meds.intakes",
        "meds.logDose",
        "meds.markMissed",
        "meds.markSkipped",
        "meds.markTaken",
        "meds.route",
        "meds.schedule",
        "meds.schedule.daily",
        "meds.schedule.prn",
        "meds.schedule.weekdays",
        "meds.status",
        "meds.status.active",
        "meds.status.done",
        "meds.status.paused",
        "meds.status.stopped",
        "meds.stop",
        "meds.stopMessage",
        "meds.stopTitle",
        "meds.times",
        "meds.times.hint",
        "meds.title",
        "meds.weekdays",
        "name.clear",
        "otp.codeHint",
        "otp.codeLabel",
        "otp.resend",
        "otp.resendCountdown",
        "otp.sentTo",
        "otp.title",
        "petDetail.courses",
        "petDetail.documents",
        "petDetail.events",
        "petDetail.weight",
        "pets.add",
        "pets.birthdate",
        "pets.birthdate.none",
        "pets.deleteMessage",
        "pets.deleteTitle",
        "pets.deleted",
        "pets.edit",
        "pets.empty",
        "pets.emptyHint",
        "pets.name",
        "pets.notes",
        "pets.species",
        "pets.species.cat",
        "pets.species.dog",
        "pets.species.other",
        "pets.title",
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
        "reminders.deniedHint",
        "reminders.openSettings",
        "reminders.title",
        "reminders.toggle",
        "signOut.cancel",
        "timeline.empty",
        "timeline.emptyHint",
        "timeline.title",
        "units.imperial",
        "units.metric",
        "units.system",
        "validation.email.prefix",
        "validation.email.rule.invalid",
        "validation.email.rule.tooLong",
        "validation.emailEmpty",
        "validation.otp.prefix",
        "validation.otp.rule.invalid",
        "validation.otpEmpty",
        "weight.history",
        "weight.log",
        "weight.trend.down",
        "weight.trend.flat",
        "weight.trend.up",
        "weight.value",
        "welcome.continueWithEmail",
        "welcome.tagline",
    ]
}
