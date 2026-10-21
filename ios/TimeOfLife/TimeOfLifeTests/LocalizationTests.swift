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

    @Test("every catalog icon has a localized accessibility name")
    func catalogIconNamesResolve() throws {
        let main = Bundle.main
        for locale in ["en", "ru"] {
            let path = try #require(main.path(forResource: locale, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for icon in CatalogIcon.allCases {
                let value = L10n.catalogIconName(icon, in: bundle)
                #expect(value != icon.rawValue, "Missing icon name for \(icon.rawValue) in \(locale)")
                #expect(!value.isEmpty)
            }
        }
    }

    // MARK: - Notes placeholders

    /// Collapsed presenters keep "Optional notes" while the expanded editor
    /// page uses its own "Dear diary..." prompt (change-expanded-notes-placeholder).
    @Test("collapsed and expanded notes placeholders are exact and distinct")
    func notesPlaceholders() throws {
        let main = Bundle.main
        let enPath = try #require(main.path(forResource: "en", ofType: "lproj"))
        let ruPath = try #require(main.path(forResource: "ru", ofType: "lproj"))
        let en = try #require(Bundle(path: enPath))
        let ru = try #require(Bundle(path: ruPath))

        #expect(NSLocalizedString("entry.notesPlaceholder", bundle: en, comment: "") == "Optional notes")
        #expect(NSLocalizedString("entry.notesPlaceholder", bundle: ru, comment: "") == "Необязательные заметки")
        #expect(NSLocalizedString("notes.editorPlaceholder", bundle: en, comment: "") == "Dear diary...")
        #expect(NSLocalizedString("notes.editorPlaceholder", bundle: ru, comment: "") == "Дорогой дневник...")
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
        "activity.savedWithDuration",
        "app.name",
        "appleSignIn.error",
        "appleSignIn.title",
        "authGate.title",
        "category.nameRequired",
        "category.nameTooLong",
        "category.seed.education",
        "category.seed.entertainment",
        "category.seed.hobby",
        "category.seed.relax",
        "category.seed.sleep",
        "category.seed.sport",
        "category.seed.work",
        "categoryEditor.cancel",
        "categoryEditor.confirmSaveLabel",
        "categoryEditor.createTitle",
        "categoryEditor.delete",
        "categoryEditor.dismissLabel",
        "categoryEditor.editTitle",
        "categoryEditor.iconLabel",
        "categoryEditor.iconUnavailable",
        "categoryEditor.nameLabel",
        "categoryEditor.namePlaceholder",
        "categoryEditor.save",
        "common.and",
        "common.ok",
        "delete.category.confirm",
        "delete.category.message",
        "delete.category.title",
        "emailEntry.email",
        "emailEntry.submit",
        "emailEntry.subtitle",
        "emailEntry.title",
        "entry.categoriesLabel",
        "entry.confirmAddLabel",
        "entry.confirmSaveLabel",
        "entry.delete",
        "entry.deleteConfirm",
        "entry.deleteMessage",
        "entry.deleteTitle",
        "entry.dismissLabel",
        "entry.duration",
        "entry.editTitle",
        "entry.invalidInterval",
        "entry.lockedNote",
        "entry.lockedTitle",
        "entry.nameLabel",
        "entry.namePlaceholder",
        "entry.notesLabel",
        "entry.notesPlaceholder",
        "entry.staleError",
        "error.categoryExists",
        "error.conflict",
        "error.localPersistence",
        "history.day.today",
        "history.day.yesterday",
        "history.emptySubtitle",
        "history.emptyTitle",
        "history.hasNotes",
        "history.inProgress",
        "history.logTime",
        "history.pull.offline",
        "history.syncError.title",
        "history.tracked",
        "insights.empty.today",
        "insights.empty.week",
        "insights.emptySubtitle",
        "insights.emptyTitle",
        "insights.footnote",
        "insights.lens.activity",
        "insights.lens.category",
        "insights.noCategory",
        "insights.period.all",
        "insights.period.today",
        "insights.period.week",
        "logTime.cancel",
        "logTime.ends",
        "logTime.starts",
        "logTime.title",
        "manage.categories.add",
        "manage.categories.editHint",
        "manage.categories.emptySubtitle",
        "manage.categories.emptyTitle",
        "manage.categories.loading",
        "manage.categories.rowA11y",
        "manage.categories.title",
        "name.clear",
        "name.pickerNoMatchHint",
        "name.pickerTitle",
        "notes.editorCounter",
        "notes.editorPlaceholder",
        "notes.editorSubtitle",
        "otp.codeHint",
        "otp.codeLabel",
        "otp.resend",
        "otp.resendCountdown",
        "otp.sentTo",
        "otp.title",
        "profile.account",
        "profile.categories",
        "profile.eraseCancel",
        "profile.eraseConfirm",
        "profile.eraseLocalData",
        "profile.eraseLocalDataConfirmMessage",
        "profile.eraseLocalDataConfirmTitle",
        "profile.lastSynced.ago",
        "profile.lastSynced.justNow",
        "profile.onDevice",
        "profile.onDeviceFooter",
        "profile.signOut",
        "profile.syncError",
        "profile.syncNow",
        "profile.syncedSuccessfully",
        "profile.syncing",
        "profile.title",
        "profile.versionDebugSuffix",
        "provenance.name.calendar",
        "provenance.name.control",
        "provenance.name.garmin",
        "provenance.name.healthkit",
        "provenance.name.screentime",
        "provenance.name.siri",
        "provenance.name.widget",
        "provenance.via.calendar",
        "provenance.via.control",
        "provenance.via.garmin",
        "provenance.via.healthkit",
        "provenance.via.screentime",
        "provenance.via.siri",
        "provenance.via.widget",
        "signOut.cancel",
        "tab.history",
        "tab.insights",
        "tab.track",
        "timer.chooserRecent",
        "timer.compactReturnHint",
        "timer.compactRunning",
        "timer.compactStop",
        "timer.idlePrompt",
        "timer.namePlaceholder",
        "timer.ready",
        "timer.recentsEmptyHint",
        "timer.running",
        "timer.saved",
        "timer.saving",
        "timer.selectActivity",
        "timer.start",
        "timer.stop",
        "timer.stopHint",
        "undo.notSelected",
        "undo.selected",
        "undo.selectedPosition",
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
