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
    // y99 sends {"cmd":"ping"} every few seconds. Like the web (deob ~20441 "No ping 15s. Disconnect"), a
    // connection that goes 15 s without one is treated as silently dead and replaced: on a phone, sockets
    // die without any error (network switch, weak signal, app suspended), and sends then go nowhere.
    private var lastPing = Date()
    private var sawPing = false   // only watch for silence once this connection has actually pinged
    private var watchdog: Timer?

    func start(auth: String) {
        guard !running else { return }   // one socket per account: a second one gets the other logged out
        self.auth = auth
        running = true
        retryDelay = 1
        connect()
        DispatchQueue.main.async {
            self.watchdog?.invalidate()
            self.watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkPing() }
        }
    }

    private func checkPing() {
        guard running, isConnected, sawPing, Date().timeIntervalSince(lastPing) > 15 else { return }
        DebugLog.log("socket: no ping for 15 s, reconnecting")
        isConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        retryDelay = 1
        connect()
    }

    func stop() {
        DebugLog.log("socket stop")
        running = false
        isConnected = false
        DispatchQueue.main.async { self.watchdog?.invalidate(); self.watchdog = nil }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Tells the sender we've read up to msg_id (what the web sends when a chat is open and focused).
    /// Returns false when there's no live connection to send it on (the caller retries on .y99SocketReady).
    @discardableResult
    func markSeen(target: String, msgId: Int) -> Bool {
        guard isConnected else { DebugLog.log("seen \(target) \(msgId) NOT sent: socket down"); return false }
        DebugLog.log("socket -> message_seen \(target) \(msgId)")
        send(["cmd": "message_seen", "target": target, "msg_id": msgId])
        return true
    }

    private func connect() {
        guard running, let url = URL(string: "wss://api1.y99.in:8443") else { return }
        DebugLog.log("socket connecting")
        sawPing = false
        let session = URLSession(configuration: .default)
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
    }

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        task?.send(.data(d)) { err in if let err { DebugLog.log("socket send error: \(err.localizedDescription)") } }
    }

    private func receive() {
        let current = task
        current?.receive { [weak self] result in
            // A replaced connection's callbacks (failure from being cancelled) must not touch the new one.
            guard let self, current === self.task else { return }
            switch result {
            case .success(let message):
                var data: Data?
                if case .data(let d) = message { data = d }
                if case .string(let s) = message { data = Data(s.utf8) }
                if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.handle(obj)
                }
                self.receive()
            case .failure(let err):
                DebugLog.log("socket failed: \(err.localizedDescription)")
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
        let cmd = o["cmd"] as? String ?? "?"
        if cmd == "ping" {
            if !sawPing { DebugLog.log("socket: pings arriving") }
            lastPing = Date(); sawPing = true
            return
        }
        let sub = (o["dispatch"] ?? o["commit"]).map { " \($0)" } ?? ""
        let params = o["params"].map { " \($0)" } ?? ""
        DebugLog.log("socket <- \(cmd)\(sub)\(params)\(cmd == "message" ? " from \(o["hunter"] ?? "?") id \(o["id"] ?? "?")" : "")")
        switch o["cmd"] as? String {
        case "welcome":
            send(["cmd": "authenticate", "auth_token": auth ?? "", "clientV": 4049])
        case "auth_success":
            lastPing = Date()
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
