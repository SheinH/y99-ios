import Foundation
import Network

extension Notification.Name {
    /// Posted when the app goes from offline to online.
    static let y99Online = Notification.Name("y99Online")
}

// Online/offline signal for the app. For now from NWPathMonitor (is there any usable network path).
@MainActor final class Connectivity: ObservableObject {
    static let shared = Connectivity()
    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in Connectivity.shared.set(path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "y99.path"))
    }

    func set(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        if online { NotificationCenter.default.post(name: .y99Online, object: nil) }
    }
}
