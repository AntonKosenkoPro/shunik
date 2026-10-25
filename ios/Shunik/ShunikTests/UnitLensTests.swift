import Testing
import Foundation
@testable import Shunik

/// `UnitLens` conversions, parsing, trend epsilon, and the locale default.
/// Mass only — dose units are untouched by the lens.
@Suite("UnitLens")
struct UnitLensTests {

    private func withCleanDefaults(_ body: () -> Void) {
        let key = UnitLens.currentDefaultsKey
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    @Test("metric display splits kg and g at 1000")
    func metricDisplay() {
        #expect(UnitLens.display(grams: 4300, system: .metric).value == "4.3")
        #expect(UnitLens.display(grams: 4300, system: .metric).unit == "kg")
        #expect(UnitLens.display(grams: 1000, system: .metric).value == "1.0")
        #expect(UnitLens.display(grams: 999, system: .metric).value == "999")
        #expect(UnitLens.display(grams: 999, system: .metric).unit == "g")
    }

    @Test("imperial display is decimal pounds only")
    func imperialDisplay() {
        let display = UnitLens.display(grams: 4300, system: .imperial)
        #expect(display.unit == "lb")
        #expect(display.value == "9.5")
    }

    @Test("grams parse round-trips 4300g, 4.3kg, and 9.5lb")
    func gramsRoundTrip() throws {
        #expect(UnitLens.grams(value: 4300, unit: "g") == 4300)
        #expect(UnitLens.grams(value: 4.3, unit: "kg") == 4300)

        // 4300 g renders as 9.5 lb; parsing 9.5 lb lands 9 g away — the
        // epsilon documents this as flat, never as change.
        let pounds = try #require(UnitLens.grams(value: 9.5, unit: "lb"))
        #expect(UnitLens.display(grams: pounds, system: .imperial).value == "9.5")
        #expect(UnitLens.trend(current: 4300, previous: pounds) == .flat)

        // Ounces and case-insensitivity.
        #expect(UnitLens.grams(value: 16, unit: "oz") == 454)
        #expect(UnitLens.grams(value: 1, unit: "KG") == 1000)
        #expect(UnitLens.grams(value: 2, unit: "lbs") == 907)
    }

    @Test("grams parse rejects garbage and negatives")
    func gramsRejectsBadInput() {
        #expect(UnitLens.grams(value: .nan, unit: "g") == nil)
        #expect(UnitLens.grams(value: .infinity, unit: "kg") == nil)
        #expect(UnitLens.grams(value: -1, unit: "g") == nil)
        #expect(UnitLens.grams(value: -0.5, unit: "lb") == nil)
        #expect(UnitLens.grams(value: 12, unit: "stone") == nil)
        #expect(UnitLens.grams(value: 12, unit: "") == nil)
    }

    @Test("trend is flat inside the 10 g epsilon")
    func trendEpsilon() {
        #expect(UnitLens.trend(current: 4200, previous: 4200) == .flat)
        #expect(UnitLens.trend(current: 4200, previous: 4205) == .flat)
        #expect(UnitLens.trend(current: 4205, previous: 4200) == .flat)
        #expect(UnitLens.trend(current: 4210, previous: 4200) == .up)
        #expect(UnitLens.trend(current: 4200, previous: 4210) == .down)
    }

    @Test("fresh-install default follows the locale measurement system")
    func localeDefault() {
        withCleanDefaults {
            let expected: UnitSystem =
                Locale.current.measurementSystem == .metric ? .metric : .imperial
            #expect(UnitLens.defaultSystem(for: Locale.current) == expected)
            #expect(UnitLens.current == expected)
        }
    }

    @Test("the system choice persists per device")
    func persistence() {
        withCleanDefaults {
            UnitLens.current = .imperial
            #expect(UnitLens.current == .imperial)
            UnitLens.current = .metric
            #expect(UnitLens.current == .metric)
        }
    }
}
