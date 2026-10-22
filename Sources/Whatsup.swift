import Foundation

extension Notification.Name {
    /// userInfo: target, delivered (Int?), seen (Int?) — read receipts pushed over the socket.
    static let y99Seen = Notification.Name("y99Seen")
}

// One app-wide whatsup heartbeat, like the web client (deob/modules/H45J.js getWhatsup/prepareWhatsup).
// It runs while the app is in the foreground and logged in, not just while a chat is open, and sends what
// the web sends: `gnt` (the last response's `haw`, reversed — an anti-bot echo), `messageshash` and
// `new_messages_t` (so the server only resends the conversation list when it changed), and it waits the
// server's `interval` between polls. Skipping these made the server treat us as a bot (captcha after idle).
@MainActor final class Whatsup {
    static let shared = Whatsup()

    struct Chat {
        let target: String
        var privateLast: Int
        let onResponse: ([String: Any]) -> Void
    }
    /// The open chat; its messages come back in `private`.
    var chat: Chat?
    /// Who we're typing to right now (TypingReporter); whatsup carries it too, like the web.
    var typingTarget: String?

    private var auth: String?
    private var username = ""
    private var loop: Task<Void, Never>?
    private var messagesHash: String?
    private var newMessagesT: String?
    private var interval: Duration = .seconds(2)
    private var inFlight = false
    private var kick = false
    private var observing = false

    // Persisted so a background refresh can echo it too.
    private var haw: String? {
        get { UserDefaults.standard.string(forKey: "whatsupHaw") }
        set { UserDefaults.standard.set(newValue, forKey: "whatsupHaw") }
    }

    func start(auth: String, username: String) {
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: .y99Online, object: nil, queue: .main) { _ in
                Task { @MainActor in Whatsup.shared.pollNow() }
            }
        }
        self.auth = auth
        self.username = username
        pollNow()
    }

    func stop() {
        loop?.cancel()
        loop = nil
        inFlight = false
        kick = false
    }

    /// Logout: stop and forget the session and per-session hashes.
    func reset() {
        stop()
        auth = nil
        chat = nil
        typingTarget = nil
        messagesHash = nil
        newMessagesT = nil
        haw = nil
    }

    /// Poll as soon as possible (e.g. a chat just opened). Never overlaps a request in flight: back-to-back
    /// whatsups (app start + chat open landed 4 ms apart) are the kind of burst that draws the captcha.
    func pollNow() {
        guard auth != nil else { return }
        if inFlight { kick = true; return }
        loop?.cancel()
        loop = Task {
            while !Task.isCancelled {
                // Offline: wait for .y99Online (which polls right away) instead of failing every 2 s.
                if !Connectivity.shared.isOnline { try? await Task.sleep(for: .seconds(3600)); continue }
                inFlight = true
                await pollOnce(focused: true)
                inFlight = false
                if kick { kick = false; continue }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// One request. `extra` adds fields (e.g. panel); returns the response for one-off callers.
    @discardableResult
    func pollOnce(focused: Bool, extra: [String: String] = [:], auth: String? = nil, username: String? = nil) async -> [String: Any]? {
        guard let auth = auth ?? self.auth else { return nil }
        var f: [String: String] = [
            "clientVersion": "4049",
            "m": "1",
            "ws": SocketManager.shared.isConnected ? "1" : "0",
            "window_focus": focused ? "true" : "false",
            "cookie": API.deviceCookie,
        ]
        if let haw { f["gnt"] = String(haw.reversed()) }
        if let messagesHash { f["messageshash"] = messagesHash }
        if let newMessagesT { f["new_messages_t"] = newMessagesT }
        let chat = self.chat
        if let chat {
            f["target"] = chat.target
            f["private_last"] = String(chat.privateLast)
        }
        if let typingTarget {
            f["typing"] = "true"
            f["typingTarget"] = typingTarget
        }
        f.merge(extra) { _, new in new }

        guard let dict = await API.post("whatsup", f, auth: auth, username: username ?? self.username) as? [String: Any] else { return nil }
        if let v = dict["haw"] { haw = "\(v)" }
        if let v = dict["messageshash"] { messagesHash = "\(v)" }
        if let v = dict["new_messages_t"] { newMessagesT = "\(v)" }
        if let ms = Int("\(dict["interval"] ?? "")") { interval = .milliseconds(max(2000, ms)) }   // web floors it at 2s
        if let chat, self.chat?.target == chat.target { chat.onResponse(dict) }
        return dict
    }
}
