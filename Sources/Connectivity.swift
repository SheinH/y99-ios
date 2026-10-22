import SwiftUI
import Network

extension Notification.Name {
    /// Posted when the app goes from offline to online: everything waiting on the network resyncs.
    static let y99Online = Notification.Name("y99Online")
}

// Online/offline for the whole app, judged like `ping 1.1.1.1` in a terminal: while the app is open it
// pings every second (Pinger), and silence for 3 s means offline. Any answer from y99 (an HTTP reply, a
// socket heartbeat) also counts as alive, so a network that blocks ping can't strand the app. Nothing
// network-bound tries while offline; coming back posts .y99Online once.
@MainActor final class Connectivity: ObservableObject {
    static let shared = Connectivity()

    enum Status { case online, slow, offline }
    @Published private(set) var status: Status = .online
    @Published private(set) var justReconnected = false   // a moment of "Online" after being offline
    var isOnline: Bool { status != .offline }
    /// The same, readable off the main thread (the socket's callbacks).
    nonisolated(unsafe) static var online = true

    private static let offlineAfter: TimeInterval = 3
    private static let slowOver: TimeInterval = 1   // a ping slower than this
    private let monitor = NWPathMonitor()
    private let pinger = Pinger()
    private var pathUp = true
    // Some networks (hotel or office Wi-Fi) drop ping. Until ping has answered on this network, its
    // silence proves nothing, and the system's own network status decides alone.
    private var pingWorks = false
    private var running = false
    private var lastAlive = Date()
    private var lastRTT: TimeInterval = 0
    private var calm: Task<Void, Never>?

    private init() {
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in Connectivity.shared.pathChanged(path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "y99.path"))
        pinger.onReply = { rtt in Task { @MainActor in Connectivity.shared.alive(rtt: rtt) } }
        pinger.onTick = { Task { @MainActor in Connectivity.shared.evaluate() } }
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
        lastAlive = Date()   // a fresh start gets the full grace period
        pinger.start()
    }

    func stop() {
        running = false
        pinger.stop()
    }

    /// y99 answered (HTTP or socket): proof of a working connection even where ping is blocked.
    nonisolated static func serverAnswered() {
        Task { @MainActor in shared.lastAlive = Date(); shared.evaluate() }
    }

    private func alive(rtt: TimeInterval) {
        if !pingWorks { DebugLog.log("ping answering (\(Int(rtt * 1000)) ms)") }
        pingWorks = true
        lastAlive = Date()
        lastRTT = rtt
        evaluate()
    }

    private func pathChanged(_ up: Bool) {
        pathUp = up
        pingWorks = false
        if up { lastAlive = Date() }   // give the new network a few seconds to answer
        evaluate()
    }

    private func evaluate() {
        let next: Status
        if !pathUp { next = .offline }
        else if !running { return }
        else if pingWorks, Date().timeIntervalSince(lastAlive) > Self.offlineAfter { next = .offline }
        else { next = lastRTT > Self.slowOver ? .slow : .online }
        guard next != status else { return }
        let wasOffline = status == .offline
        withAnimation { status = next }
        Self.online = next != .offline
        DebugLog.log("connectivity: \(next)")
        if wasOffline {
            NotificationCenter.default.post(name: .y99Online, object: nil)
            withAnimation { justReconnected = true }
            calm?.cancel()
            calm = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { withAnimation { justReconnected = false } }
            }
        } else if next == .offline {
            calm?.cancel()
            justReconnected = false
        }
    }
}

// Top-right status, Apple style: silent while all is well, a red "Offline" or yellow "Slow" when not,
// and a green "Online" for a moment when the connection comes back.
struct ConnectionBadge: View {
    @ObservedObject private var c = Connectivity.shared

    static var isVisible: Bool {
        let c = Connectivity.shared
        return c.status != .online || c.justReconnected
    }

    var body: some View {
        Group {
            switch c.status {
            case .offline: badge("Offline", "wifi.slash", .red)
            case .slow: badge("Slow", "wifi.exclamationmark", .yellow)
            case .online: badge("Online", "wifi", .green)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func badge(_ text: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.subheadline.weight(.semibold))
        }
        .fixedSize()
    }
}
