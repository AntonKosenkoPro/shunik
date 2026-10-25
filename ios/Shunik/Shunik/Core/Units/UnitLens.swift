import Foundation

/// The per-device mass display system (unit-system spec). Never synced:
/// the choice lives in the standard defaults under `currentDefaultsKey` and
/// only affects how gram integers render. Mass only — dose units are
/// untouched (doses stay raw strings end to end).
enum UnitSystem: String, CaseIterable, Sendable {
    case metric
    case imperial
}

/// Weight direction between two weigh-ins (epsilon: single-digit gram
/// jitter from lb/kg round-trips is not change).
enum WeightTrend: Sendable, Equatable {
    case up
    case down
    case flat

    /// Localized label for the trend badge.
    var label: String {
        switch self {
        case .up: return L10n.weightTrendUp.text
        case .down: return L10n.weightTrendDown.text
        case .flat: return L10n.weightTrendFlat.text
        }
    }
}

/// Mass conversions between stored integer grams and display strings.
/// A namespace enum (never instantiated).
enum UnitLens {
    /// Defaults key for the per-device system choice. Standard suite on
    /// purpose: the lens is per-device, never synced, never per-account.
    static let currentDefaultsKey = "com.shunik.unitSystem"

    /// Grams per imperial/mass unit, exact by definition.
    private static let gramsPerOunce = 28.349523125
    private static let gramsPerPound = 453.59237

    /// The epsilon below which two weigh-ins count as unchanged (flat).
    private static let flatEpsilonGrams: Int64 = 10

    /// The device's chosen system, persisted in standard defaults. Fresh
    /// installs default from `Locale.current.measurementSystem`
    /// (metric → `.metric`, everything else → `.imperial`).
    static var current: UnitSystem {
        get {
            let raw = UserDefaults.standard.string(forKey: currentDefaultsKey)
            if let raw, let system = UnitSystem(rawValue: raw) {
                return system
            }
            return defaultSystem(for: Locale.current)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: currentDefaultsKey)
        }
    }

    /// The out-of-the-box system for a locale, without touching persistence.
    /// Exposed for tests; `current` is the persisted accessor.
    static func defaultSystem(for locale: Locale) -> UnitSystem {
        locale.measurementSystem == .metric ? .metric : .imperial
    }

    /// Splits stored grams into a display value + unit. Metric shows kg
    /// with one decimal at or above 1000 g, plain grams below. Imperial
    /// shows decimal pounds only — never lb+oz.
    static func display(grams: Int64, system: UnitSystem) -> (value: String, unit: String) {
        switch system {
        case .metric:
            if grams >= 1000 {
                return (String(format: "%.1f", Double(grams) / 1000), "kg")
            }
            return ("\(grams)", "g")
        case .imperial:
            return (String(format: "%.1f", Double(grams) / gramsPerPound), "lb")
        }
    }

    /// Parses a user-entered value + unit chip into integer grams (rounded).
    /// Accepts g/kg/oz/lb (case-insensitive, "lbs" included). Returns nil for
    /// unknown units, non-finite input, or negative values.
    static func grams(value: Double, unit: String) -> Int64? {
        guard value.isFinite, value >= 0 else { return nil }
        switch unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "g":
            return Int64((value).rounded())
        case "kg":
            return Int64((value * 1000).rounded())
        case "oz":
            return Int64((value * gramsPerOunce).rounded())
        case "lb", "lbs":
            return Int64((value * gramsPerPound).rounded())
        default:
            return nil
        }
    }

    /// Direction from a previous weigh-in to the current one. An absolute
    /// difference under 10 g is `.flat`.
    static func trend(current: Int64, previous: Int64) -> WeightTrend {
        let delta = current - previous
        if abs(delta) < flatEpsilonGrams {
            return .flat
        }
        return delta > 0 ? .up : .down
    }
}
