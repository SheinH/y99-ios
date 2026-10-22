import SwiftUI
import Network

extension Notification.Name {
    /// Posted when the app goes from offline to online: everything waiting on the network resyncs.
    static let y99Online = Notification.Name("y99Online")
}

// Online/offline for the whole app, judged like `ping 1.1.1.1` in a terminal: while the app is open it
// pings every second (Pinger), and LinkState turns the results, y99's own answers and the system's
// network status into online / slow / offline (its rules are listed there). Nothing network-bound tries
// while offline; coming back posts .y99Online once.
@MainActor final class Connectivity: ObservableObject {
    static let shared = Connectivity()

    typealias Status = LinkState.Status
    @Published private(set) var status: Status = .online
    var isOnline: Bool { status != .offline }
    /// The same, readable off the main thread (the socket's callbacks).
    nonisolated(unsafe) static var online = true

    private let monitor = NWPathMonitor()
    private let pinger = Pinger()
    private var link = LinkState()
    private var running = false

    private init() {
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in Connectivity.shared.update { $0.path(up: path.status == .satisfied) } }
        }
        monitor.start(queue: DispatchQueue(label: "y99.path"))
        pinger.onResult = { seq, rtt in
            Task { @MainActor in
                guard Connectivity.shared.running else { return }
                Connectivity.shared.update { $0.ping(seq: seq, rtt: rtt) }
            }
        }
    }

    /// Pinging runs while the app is in the foreground; in the background the last status stands.
    func start() {
        guard !running else { return }
        #if DEBUG
        // -forceStatus offline|slow: show the badge without pulling the plug.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-forceStatus"), i + 1 < args.count {
            status = args[i + 1] == "slow" ? .slow : .offline
            return
        }
        #endif
        running = true
        link.restart()
        pinger.start()
    }

    func stop() {
        running = false
        pinger.stop()
    }

    /// y99 answered (HTTP or socket): proof of a working connection even where ping is blocked.
    nonisolated static func serverAnswered() {
        Task { @MainActor in shared.update { $0.serverAnswered() } }
    }

    private func update(_ change: (inout LinkState) -> Void) {
        change(&link)
        let next = link.status
        guard next != status else { return }
        let wasOffline = status == .offline
        withAnimation { status = next }
        Self.online = next != .offline
        DebugLog.log("connectivity: \(next)")
        if wasOffline {
            NotificationCenter.default.post(name: .y99Online, object: nil)
        }
    }
}

// Top-right status: one colored symbol, always in the same spot (the toolbar gives it its glass circle).
// The globe, not Wi-Fi: the status bar already shows Wi-Fi, and this covers cellular too.
struct ConnectionBadge: View {
    @ObservedObject private var c = Connectivity.shared

    var body: some View {
        Image(systemName: c.status == .offline ? "network.slash" : "network")
            .foregroundStyle(c.status == .offline ? .red : c.status == .slow ? .yellow : .green)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: c.status)   // "look here": the status just changed
            .accessibilityLabel(c.status == .offline ? "Offline" : c.status == .slow ? "Slow connection" : "Online")
    }
}
