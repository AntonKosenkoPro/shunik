import Testing
import Foundation
@testable import Shunik

/// Bucket contract for Profile's "Last synced" row (fix-sync-status-row,
/// sync-client spec): minute buckets, no seconds/weeks, future clamps to
/// just-now, quantities through the real system formatter in en + ru.
/// The helper is a nonisolated enum, so no `@MainActor` is needed here
/// (unlike view-static contracts — see the PR #89 lesson in design.md).
@Suite("Sync Relative Time")
struct SyncRelativeTimeTests {
    private let en = Locale(identifier: "en")
    private let ru = Locale(identifier: "ru")

    // MARK: - Buckets

    @Test("elapsed maps to buckets at exact boundaries")
    func bucketBoundaries() {
        #expect(SyncRelativeTime.bucket(elapsed: -5) == .justNow)
        #expect(SyncRelativeTime.bucket(elapsed: 0) == .justNow)
        #expect(SyncRelativeTime.bucket(elapsed: 59.9) == .justNow)
        #expect(SyncRelativeTime.bucket(elapsed: 60) == .minutes(1))
        #expect(SyncRelativeTime.bucket(elapsed: 3599) == .minutes(59))
        #expect(SyncRelativeTime.bucket(elapsed: 3600) == .hours(1))
        #expect(SyncRelativeTime.bucket(elapsed: 86399) == .hours(23))
        #expect(SyncRelativeTime.bucket(elapsed: 86400) == .days(1))
        #expect(SyncRelativeTime.bucket(elapsed: 400 * 86400) == .days(400))
        #expect(SyncRelativeTime.bucket(elapsed: 9999 * 86400) == .days(9999))
    }

    // MARK: - Quantities

    @Test("english quantities truncate and never escalate units")
    func englishQuantities() {
        #expect(SyncRelativeTime.quantity(for: .minutes(1), locale: en) == "1 minute")
        #expect(SyncRelativeTime.quantity(for: .minutes(59), locale: en) == "59 minutes")
        #expect(SyncRelativeTime.quantity(for: .hours(1), locale: en) == "1 hour")
        #expect(SyncRelativeTime.quantity(for: .hours(23), locale: en) == "23 hours")
        #expect(SyncRelativeTime.quantity(for: .days(1), locale: en) == "1 day")
        #expect(SyncRelativeTime.quantity(for: .days(400), locale: en) == "400 days")
    }

    @Test("russian quantities carry correct plural forms")
    func russianQuantities() {
        #expect(SyncRelativeTime.quantity(for: .minutes(1), locale: ru) == "1 минута")
        #expect(SyncRelativeTime.quantity(for: .minutes(2), locale: ru) == "2 минуты")
        #expect(SyncRelativeTime.quantity(for: .minutes(5), locale: ru) == "5 минут")
        #expect(SyncRelativeTime.quantity(for: .minutes(11), locale: ru) == "11 минут")
        #expect(SyncRelativeTime.quantity(for: .minutes(21), locale: ru) == "21 минута")
        #expect(SyncRelativeTime.quantity(for: .minutes(22), locale: ru) == "22 минуты")
        #expect(SyncRelativeTime.quantity(for: .minutes(25), locale: ru) == "25 минут")
        #expect(SyncRelativeTime.quantity(for: .hours(1), locale: ru) == "1 час")
        #expect(SyncRelativeTime.quantity(for: .hours(2), locale: ru) == "2 часа")
        #expect(SyncRelativeTime.quantity(for: .hours(5), locale: ru) == "5 часов")
        #expect(SyncRelativeTime.quantity(for: .days(1), locale: ru) == "1 день")
        #expect(SyncRelativeTime.quantity(for: .days(2), locale: ru) == "2 дня")
        #expect(SyncRelativeTime.quantity(for: .days(5), locale: ru) == "5 дней")
    }

    // MARK: - Composition

    @Test("english subtitle composes quantity and ago-word")
    func englishSubtitle() {
        let now = Date()
        #expect(SyncRelativeTime.subtitle(
            since: now.addingTimeInterval(-30), now: now,
            ago: "%@ ago", justNow: "Less than a minute ago", locale: en
        ) == "Less than a minute ago")
        #expect(SyncRelativeTime.subtitle(
            since: now.addingTimeInterval(-90), now: now,
            ago: "%@ ago", justNow: "Less than a minute ago", locale: en
        ) == "1 minute ago")
        #expect(SyncRelativeTime.subtitle(
            since: now.addingTimeInterval(-400 * 86400), now: now,
            ago: "%@ ago", justNow: "Less than a minute ago", locale: en
        ) == "400 days ago")
    }

    @Test("future timestamp clamps to just-now in both locales")
    func futureClamp() {
        let now = Date()
        let future = now.addingTimeInterval(3600)
        #expect(SyncRelativeTime.subtitle(
            since: future, now: now,
            ago: "%@ ago", justNow: "Less than a minute ago", locale: en
        ) == "Less than a minute ago")
        #expect(SyncRelativeTime.subtitle(
            since: future, now: now,
            ago: "%@ назад", justNow: "Меньше минуты назад", locale: ru
        ) == "Меньше минуты назад")
    }

    @Test("russian subtitle composes quantity with correct plurals")
    func russianSubtitle() {
        let now = Date()
        #expect(SyncRelativeTime.subtitle(
            since: now.addingTimeInterval(-300), now: now,
            ago: "%@ назад", justNow: "Меньше минуты назад", locale: ru
        ) == "5 минут назад")
    }

    // MARK: - Glue keys

    @Test("glue and title keys resolve with exact copy in both locales")
    func glueKeysResolve() throws {
        let main = Bundle.main
        let enPath = try #require(main.path(forResource: "en", ofType: "lproj"))
        let ruPath = try #require(main.path(forResource: "ru", ofType: "lproj"))
        let enBundle = try #require(Bundle(path: enPath))
        let ruBundle = try #require(Bundle(path: ruPath))
        #expect(NSLocalizedString("profile.lastSynced.ago", bundle: enBundle, comment: "") == "%@ ago")
        #expect(NSLocalizedString("profile.lastSynced.ago", bundle: ruBundle, comment: "") == "%@ назад")
        #expect(NSLocalizedString("profile.lastSynced.justNow", bundle: enBundle, comment: "") == "Less than a minute ago")
        #expect(NSLocalizedString("profile.lastSynced.justNow", bundle: ruBundle, comment: "") == "Меньше минуты назад")
        #expect(NSLocalizedString("profile.syncedSuccessfully", bundle: enBundle, comment: "") == "Synced successfully")
        #expect(NSLocalizedString("profile.syncedSuccessfully", bundle: ruBundle, comment: "") == "Синхронизировано успешно")
    }
}
