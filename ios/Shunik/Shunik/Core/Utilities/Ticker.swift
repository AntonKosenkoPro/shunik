import Combine
import Foundation

/// Shared 1-second elapsed-time ticker (the Track readout idiom): one place
/// for the publish/autoconnect/cancel shape instead of a per-screen
/// `Timer.publish` duplicate. No behavior change.
enum Ticker {
    /// Publishes every second on the main run loop, delivering to `receive`.
    /// The caller holds the returned cancellable and cancels it to stop.
    static func everySecond(_ receive: @escaping () -> Void) -> AnyCancellable {
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in receive() }
    }
}
