import Foundation
import Network
import SwiftUI

/// Publishes current connectivity for offline-correct UX (U3).
///
/// An `ObservableObject` wrapping `NWPathMonitor`; `@Published isConnected`
/// drives the offline banner and disables submit in view models. Tests
/// inject `MockConnectivity` (a subclass that just sets `isConnected`).
@MainActor
class Connectivity: ObservableObject {
    @Published var isConnected: Bool = true

    init() {}
}

final class NetworkMonitor: Connectivity {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.shunik.NetworkMonitor")

    override init() {
        self.monitor = NWPathMonitor()
        super.init()
        self.monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isConnected = path.status == .satisfied
            }
        }
        self.monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

/// Test double. Same shape as `Connectivity` so view models can take a
/// `Connectivity` and tests can drive `isConnected` directly.
@MainActor
final class MockConnectivity: Connectivity {
    init(connected: Bool = true) {
        super.init()
        self.isConnected = connected
    }
}
