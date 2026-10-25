import UIKit

/// Thin wrapper around `UIImpactFeedbackGenerator` and
/// `UINotificationFeedbackGenerator` so views and view models do not import
/// UIKit directly. Haptics are UI feedback and must run on the main actor.
@MainActor
enum Haptics {
    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }
}
