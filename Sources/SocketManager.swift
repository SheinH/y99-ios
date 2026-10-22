import Foundation

// WebSocket (deob/modules/WI9n.js): binary frames of UTF-8 JSON.
// welcome -> authenticate -> auth_success. Incoming DMs arrive as cmd:"message".
// The server can also run client actions remotely via cmd:"dispatch"/"commit" {dispatch|commit, params}.
extension Notification.Name {
    static let y99Message = Notification.Name("y99Message")
    /// The socket is (re)authenticated: anything that needs it (read receipts) can go now.
    static let y99SocketReady = Notification.Name("y99SocketReady")
}

final class SocketManager: NSObject {
    static let shared = SocketManager()
    private var task: URLSessionWebSocketTask?
    private var auth: String?
    private var running = false
    private var retryDelay: TimeInterval = 1
    private(set) var isConnected = false   // whatsup reports this as `ws`

    func start(auth: String) {
        guard !running else { return }   // one socket per account: a second one gets the other logged out
        self.auth = auth
        running = true
        retryDelay = 1
        connect()
    }

    func stop() {
        running = false
        isConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Tells the sender we've read up to msg_id (what the web sends when a chat is open and focused).
    /// Returns false when there's no live connection to send it on (the caller retries on .y99SocketReady).
    @discardableResult
    func markSeen(target: String, msgId: Int) -> Bool {
        guard isConnected else { return false }
        send(["cmd": "message_seen", "target": target, "msg_id": msgId])
        return true
    }

    private func connect() {
        guard running, let url = URL(string: "wss://api1.y99.in:8443") else { return }
        let session = URLSession(configuration: .default)
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
    }

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        task?.send(.data(d)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                var data: Data?
                if case .data(let d) = message { data = d }
                if case .string(let s) = message { data = Data(s.utf8) }
                if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.handle(obj)
                }
                self.receive()
            case .failure:
                self.isConnected = false
                guard self.running else { return }
                // Back off instead of hammering the server every second.
                let delay = self.retryDelay
                self.retryDelay = min(self.retryDelay * 2, 60)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.connect() }
            }
        }
    }

    private func handle(_ o: [String: Any]) {
        switch o["cmd"] as? String {
        case "welcome":
            send(["cmd": "authenticate", "auth_token": auth ?? "", "clientV": 4049])
        case "auth_success":
            isConnected = true
            retryDelay = 1
            DispatchQueue.main.async { NotificationCenter.default.post(name: .y99SocketReady, object: nil) }
        case "message":
            NotificationCenter.default.post(name: .y99Message, object: nil, userInfo: o)
        case "dispatch":
            remote(o["dispatch"] as? String, o["params"])
        case "commit":
            remote(o["commit"] as? String, o["params"])
        default:
            break
        }
    }

    // Remote client actions we act on. The server can only name actions the web client has; read
    // receipts there are commit private/updateMessagesSeen|updateMessagesDelivery {id, target} and
    // dispatch private/processMessagesSeen {arrLastSeen: [delivered, seen], target} (XBnl.js).
    private func remote(_ name: String?, _ params: Any?) {
        let p = params as? [String: Any] ?? [:]
        let target = p["target"] as? String
        switch name {
        case "socket/logout":
            // The server allows one socket per account and just told this one to go (another session
            // connected). Stop instead of reconnecting in a loop; whatsup then reports ws=0 and carries
            // everything itself, like the web does.
            stop()
        case "private/updateMessagesSeen":
            post(target, seen: Int("\(p["id"] ?? "")"))
        case "private/updateMessagesDelivery":
            post(target, delivered: Int("\(p["id"] ?? "")"))
        case "private/processMessagesSeen":
            let arr = p["arrLastSeen"] as? [Any] ?? []
            post(target, delivered: arr.first.flatMap { Int("\($0)") }, seen: arr.dropFirst().first.flatMap { Int("\($0)") })
        default:
            #if DEBUG
            print("[socket] unhandled", name ?? "nil")
            #endif
        }
    }

    private func post(_ target: String?, delivered: Int? = nil, seen: Int? = nil) {
        guard let target else { return }
        var info: [String: Any] = ["target": target]
        if let delivered { info["delivered"] = delivered }
        if let seen { info["seen"] = seen }
        NotificationCenter.default.post(name: .y99Seen, object: nil, userInfo: info)
        // Keep it even if that chat isn't open, so its Read/Delivered status is right when it opens.
        Task { @MainActor in
            guard let store = Store.current else { return }
            var st = store.state(chat: target)
            st.deliveredId = max(st.deliveredId, delivered ?? 0, seen ?? 0)
            st.readId = max(st.readId, seen ?? 0)
            store.save(chat: target, state: st)
        }
    }
}
