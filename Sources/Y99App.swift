import SwiftUI
import BackgroundTasks
import SDWebImage

@main
struct Y99App: App {
    @StateObject private var session = Session()
    @StateObject private var captcha = Captcha.shared
    @Environment(\.scenePhase) private var phase
    @State private var pushConnected = false

    init() {
        // Animated WebP (the baked blobs) through ImageIO; GIF/APNG coders are registered by default.
        SDImageCodersManager.shared.addCoder(SDImageAWebPCoder.shared)
        #if DEBUG
        // Harness runs (seeded chats) never touch the network: only what's already cached shows.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-emojiPreview") || args.contains("-videoPreview") || args.contains("-rawSeed") {
            URLProtocol.registerClass(NoNetwork.self)
        }
        if let i = args.firstIndex(of: "-transcribeTest"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in await TranscribeTest.run(url) }
        }
        if let i = args.firstIndex(of: "-micFile"), i + 1 < args.count { Mic.debugFile = URL(fileURLWithPath: args[i + 1]) }
        if let i = args.firstIndex(of: "-fakeTranscript"), i + 1 < args.count { Transcription.debugFake = args[i + 1] }
        #endif
        Task.detached(priority: .background) { DiskCache.trim() }   // keep media under 500 MB
        // Must be registered before launch finishes.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Notifier.refreshTask, using: nil) { task in
            Notifier.scheduleRefresh()
            let work = Task {
                await Notifier.checkInBackground()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-openChat"),
                   i + 1 < ProcessInfo.processInfo.arguments.count {
                    // Opens a real chat directly (needs a saved session).
                    NavigationStack { ChatView(friend: ProcessInfo.processInfo.arguments[i + 1]) }
                } else if ProcessInfo.processInfo.arguments.contains("-emojiPreview") {
                    NavigationStack { ChatView(friend: "emoji test", seed: [
                        Msg(id: "1", text: "hey :bg_attentionreverse: look at this", mine: false),
                        Msg(id: "2", text: ":bg_ablobattentionreverse: :bp_b1nzy: :haha: :smile2: :d-smile:", mine: true),
                        Msg(id: "3", text: "twemoji :tp_1f600: :tp_2764: :tp_1f468-1f469-1f467: :tp_1f1fa-1f1f8: :tp_1f44d-1f3fd: done", mine: false),
                        Msg(id: "4", text: "not emoji :nope: :bg_notreal: time 10:30:45 ok", mine: true),
                        Msg(id: "6", text: "escapes: &quot;hi&quot; &amp; don&#039;t &lt;3 &gt;_&lt;", mine: true),
                        Msg(id: "5", text: "a longer message that wraps across lines :bg_attention: with emoji in the middle :bg_hype: and more words after it\nnew line :haha:", mine: false),
                    ]) }
                } else if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-videoPreview"),
                          i + 1 < ProcessInfo.processInfo.arguments.count {
                    // Video bubble + playback check: a local file as a received message, played after 2s.
                    let url = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[i + 1])
                    NavigationStack { ChatView(friend: "video test", seed: [
                        Msg(id: "1", text: "here's a clip", mine: false),
                        Msg(id: "2", text: "", mine: false, video: .local(url)),
                    ]) }
                } else if session.auth == nil {
                    LoginView()
                } else {
                    FriendsView()
                }
                #else
                if session.auth == nil {
                    LoginView()
                } else {
                    FriendsView()
                }
                #endif
            }
            .environmentObject(session)
            .sheet(item: $captcha.url) { CaptchaSheet(url: $0) }
            // y99://chat/<user> from a Y99 Alerts notification; y99://pushsub?d=… from its setup.
            .onOpenURL { url in
                switch url.host {
                case "chat":
                    if let who = url.pathComponents.dropFirst().first, !who.isEmpty { Notifier.shared.openChat = who }
                case "pushsub":
                    guard PushRelay.save(from: url), let auth = session.auth else { return }
                    Task {
                        await PushRelay.register(auth: auth, username: session.username)
                        pushConnected = true
                    }
                default:
                    break
                }
            }
            .alert("Notifications connected", isPresented: $pushConnected) {
                Button("OK") {}
            } message: {
                Text("You'll get a notification from Y99 Alerts when someone messages you while Y99 is closed.")
            }
            .onAppear {
                Connectivity.shared.start()
                if let auth = session.auth {
                    SocketManager.shared.start(auth: auth)
                    Whatsup.shared.start(auth: auth, username: session.username)
                    Notifier.shared.setUp()
                    Task { await EmojiStore.shared.prefetchAll() }
                    Task { await PushRelay.register(auth: auth, username: session.username) }
                }
            }
            .onChange(of: session.auth) {
                guard let auth = session.auth else { return }
                Whatsup.shared.start(auth: auth, username: session.username)
                Notifier.shared.setUp()
                Task { await EmojiStore.shared.prefetchAll() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .y99Message)) { note in
                if let o = note.userInfo as? [String: Any] { Notifier.shared.notify(message: o, me: session.username) }
            }
            .onChange(of: phase) {
                // Ping only while the app is on screen.
                if phase == .active { Connectivity.shared.start() } else if phase == .background { Connectivity.shared.stop() }
                guard let auth = session.auth else { return }
                switch phase {
                case .background:
                    Whatsup.shared.stop()
                    Notifier.markCaughtUp()
                    Notifier.scheduleRefresh()
                case .active:
                    // Resume the heartbeat; reconnect the socket if it dropped (or was told to log out).
                    SocketManager.shared.start(auth: auth)
                    Whatsup.shared.start(auth: auth, username: session.username)
                default:
                    break
                }
            }
        }
    }
}

#if DEBUG
/// Fails every web request (see Y99App.init): seeded harness runs must not contact y99's servers.
final class NoNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        // The transcription service (Azure, not y99) stays reachable for dictation checks.
        guard request.url?.host != DictationSettings.realtimeURL?.host else { return false }
        return ["http", "https", "ws", "wss"].contains(request.url?.scheme ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
#endif
