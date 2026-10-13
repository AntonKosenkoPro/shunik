import SwiftUI
import UIKit

/// Extension-safe subset of the app `Theme` tokens for the Live Activity
/// widget (live-activities change).
///
/// `Theme.swift` itself is code-safe for extensions (pure SwiftUI, no
/// `UIApplication`), but its colors resolve via `Color("…", bundle: .main)`
/// against the app asset catalog — which is not compiled into the appex
/// (the extension ships only `Localizable.strings`; see `project.yml`). In
/// the extension `.main` is the appex bundle, so those lookups would miss.
/// Rather than duplicating the whole catalog into the appex, this subset
/// mirrors just the tokens the widget needs with bundle-free colors:
///
/// - `stopBackground` mirrors `Theme.danger` (`#FF3B30` light / `#FF453A`
///   dark — the iOS system-red pair), so it tracks light/dark without an
///   asset lookup.
/// - `stopForeground` mirrors `Theme.textOnAccent` (`Color.white`).
enum LiveActivityTheme {
    static let stopBackground = Color(.systemRed)
    static let stopForeground = Color.white
}
