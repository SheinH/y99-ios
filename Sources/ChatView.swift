import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct Msg: Identifiable {
    let id: String
    let text: String
    let mine: Bool
    var image: ImageSource? = nil
    var video: VideoSource? = nil
    var failed = false
    var pending: OutboxEntry.State? = nil   // still in the outbox
    var detail: String? = nil               // photo/video stage from the outbox, e.g. "Uploading 42%"
    var serverId: Int?   // set once the server accepts it; nil while sending
}

struct ChatView: View {
    let friend: String
    @EnvironmentObject var session: Session

    @State private var messages: [Msg] = []
    @State private var seen: Set<String> = []
    var seed: [Msg] = []   // DEBUG harness only
    @State private var draft = ""
    @State private var typing = false   // composer has the keyboard (or the emoji panel in its place)
    @State private var lastId = 0
    @State private var deliveredId = 0   // whatsup last_seen[0]: partner's client has everything <= this
    @State private var readId = 0        // whatsup last_seen[1]: partner has seen everything <= this
    @State private var markedSeen = 0   // newest of their messages we've told the server we read
    @State private var photo: PhotosPickerItem?
    @State private var pickingFile = false
    @StateObject private var dictation = Dictation()
    @State private var canDictate = false   // set up in the account menu > Dictation
    @ObservedObject private var connectivity = Connectivity.shared
    @State private var typingMs: Double = 0      // web's lkSpent: time between edits, gaps under 5s only
    @State private var lastEdit: Date?
    @State private var pickingPhoto = false
    @State private var takingPhoto = false
    @State private var showingEmoji = false          // emoji panel in the keyboard's place
    @State private var keyboardHeight: CGFloat = 336  // last seen keyboard height (incl. home-indicator area)
    @State private var loadingOlder = false
    @State private var reachedStart = false
    @State private var position = ScrollPosition(idType: String.self)
    @State private var friendThumb: String?      // their avatar, from their newest message
    @State private var friendThumbId = 0
    @State private var avatarImage: UIImage?     // full size, once fetched
    @State private var viewingAvatar = false
    @State private var reporter: TypingReporter?   // our typing -> partner
    @State private var partnerTyping = false
    @State private var partnerTypingEnds: Task<Void, Never>?

    @Namespace private var zoom

    var body: some View { observers(chat) }

    // The thread is drawn upside down (and each row flipped back), like most chat apps: its start is the
    // newest message at the bottom, so it opens there, new messages appear without scrolling, history pages
    // in at the far end, and the keyboard or emoji panel shrinking the view leaves the newest in place.
    var chat: some View {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if partnerTyping { TypingBubble().padding(.top, 10).flipped() }
                    let lastMine = messages.lastIndex(where: \.mine)
                    // Identify rows by message id, not position: history inserts shift positions, which
                    // would hand a row (and its in-flight image load) to a different message.
                    ForEach(Array(messages.enumerated()).reversed(), id: \.element.id) { i, m in
                        // Group runs from the same sender: tight spacing inside a run, tail on its last bubble.
                        let startsRun = i == 0 || messages[i - 1].mine != m.mine
                        let endsRun = i == messages.count - 1 || messages[i + 1].mine != m.mine
                        bubble(m, tail: endsRun, showStatus: i == lastMine)
                            .padding(.top, startsRun ? 10 : 2)
                            .flipped()
                    }
                    // Reaching the far end (oldest loaded) pages in older history.
                    Group {
                        if loadingOlder { ProgressView().padding(.vertical, 8) } else { Color.clear.frame(height: 1) }
                    }
                    .frame(maxWidth: .infinity)
                    .onAppear { Task { await loadOlder() } }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollPosition($position)
            .noScrollEdgeEffect()
            .flipped()
            // Rows fade out under the top bar, like Messages (stands in for the edge blur the flip loses).
            .overlay(alignment: .top) { TopFade() }
            .scrollDismissesKeyboard(.interactively)
            // My own new message brings the thread back to the newest, even when scrolled up.
            .onChange(of: messages.last?.id) {
                if messages.last?.mine == true { withAnimation { position.scrollTo(edge: .top) } }
            }
            // An inset (rather than a stacked view) so rows pass behind the glass composer.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
                    // Remember the real keyboard's height so the emoji panel matches it.
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                        if !showingEmoji, let f = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, f.height > 100 {
                            keyboardHeight = f.height
                        }
                    }
            }
        .navigationTitle(friend)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    avatarButton
                    Text(friend)
                        .font(.headline)
                        .lineLimit(1)
                }
                // Same gap left of the avatar as above and below, so it follows the pill's round end.
                .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
                .glass(in: Capsule())
            }
            ToolbarItem(placement: .topBarTrailing) { ConnectionBadge() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .y99Message)) { note in
            guard let o = note.userInfo as? [String: Any],
                  (o["hunter"] as? String) == friend else { return }
            append([o])
        }
        .task {
            if reporter == nil { reporter = TypingReporter(target: friend) }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-focusLater") {
                Task { try? await Task.sleep(for: .seconds(2)); typing = true }
            }
            debugScripts()
            if ProcessInfo.processInfo.arguments.contains("-showEmojiPanel") {
                Task { try? await Task.sleep(for: .seconds(2)); showingEmoji = true; typing = true }
            }
            #endif
            if !seed.isEmpty {
                guard messages.isEmpty else { return }   // .task runs again when the chat reappears
                messages = seed
                #if DEBUG
                loadRawSeed()
                #endif
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-longSeed") {
                    messages = (1...40).map { Msg(id: "\($0)", text: "filler message \($0) :bg_hype:", mine: $0 % 3 == 0, serverId: $0) }
                        + (ProcessInfo.processInfo.arguments.firstIndex(of: "-imageSeed").flatMap { i in
                            (try? Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[i + 1])))
                                .map { [Msg(id: "img", text: "", mine: false, image: .local($0), serverId: 42)] } } ?? [])
                        + [Msg(id: "41", text: "look https://example.com/averyveryverylongpathwithoutanyspacesatall/more/stuff/here?x=12345 :bg_hype:", mine: false, serverId: 41)]
                }
                #endif
                return
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-appendTest") {
                Task {
                    for n in 1...3 {
                        try? await Task.sleep(for: .seconds(4))
                        append([["id": 900_000_000 + n, "hunter": friend, "message": "incoming \(n) this is a much longer message with :bg_hype: several emoji :bg_pats: spread through it so it has to wrap :bg_thinkingfast: across lines"]])
                    }
                }
            }
            #endif
            // Stored history first (instant, works offline); polling then asks only for newer messages.
            if let store = Store.current {
                let st = store.state(chat: friend)
                readId = max(readId, st.readId); deliveredId = max(deliveredId, st.deliveredId)
                markedSeen = max(markedSeen, st.markedSeen)
                if draft.isEmpty { draft = st.draft }
                append(store.messages(chat: friend, limit: 100), persist: false)
            }
            showOutbox()
            Whatsup.shared.chat = .init(target: friend, privateLast: lastId) { dict in handle(dict) }
            Task { await refreshLatest() }
            Whatsup.shared.pollNow()
            await watchReadReceipts()
        }
        .onAppear {
            Notifier.shared.activeChat = friend
            canDictate = DictationSettings.isSetUp
        }
        .onDisappear {
            dictation.cancel()
            if Notifier.shared.activeChat == friend { Notifier.shared.activeChat = nil }
            reporter?.stop()
            if Whatsup.shared.chat?.target == friend { Whatsup.shared.chat = nil }
        }
    }

    /// State saving and app/socket/outbox events (split from `chat` to keep the type checker fast).
    func observers(_ v: some View) -> some View {
        v
            .onChange(of: draft) {
                let now = Date()
                if let lastEdit, now.timeIntervalSince(lastEdit) < 5 { typingMs += now.timeIntervalSince(lastEdit) * 1000 }
                lastEdit = draft.isEmpty ? nil : now
                reporter?.edited(draft)
                saveState()
            }
            .onChange(of: [readId, deliveredId, markedSeen]) { saveState() }
            .onReceive(NotificationCenter.default.publisher(for: .y99SocketReady)) { _ in markSeenIfVisible() }
            .onReceive(NotificationCenter.default.publisher(for: .y99Outbox)) { note in
                if let info = note.userInfo { outboxChanged(info) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                guard seed.isEmpty else { return }
                Task { await refreshLatest() }
            }
            // Back online: catch up on what arrived meanwhile, a beat after the whatsup poll (no bursts).
            .onReceive(NotificationCenter.default.publisher(for: .y99Online)) { _ in
                guard seed.isEmpty else { return }
                Task { try? await Task.sleep(for: .seconds(1.5)); await refreshLatest() }
            }
            .onChange(of: lastId) { if Whatsup.shared.chat?.target == friend { Whatsup.shared.chat?.privateLast = lastId } }
            .onReceive(NotificationCenter.default.publisher(for: .y99Seen)) { note in
                guard let info = note.userInfo, info["target"] as? String == friend else { return }
                if let d = info["delivered"] as? Int { deliveredId = max(deliveredId, d) }
                if let s = info["seen"] as? Int { readId = max(readId, s) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .y99Typing)) { note in
                guard let info = note.userInfo, (info["hunter"] as? String) == friend else { return }
                let on = (info["typing"] as? Bool) == true
                setPartnerTyping(on)
                if on { partnerSawMine(before: .max) }   // typing here means they have the chat open
            }
    }

    /// They've read every message of mine older than `limit`: replying (or typing) implies they saw them,
    /// even when y99's own seen flag hasn't come through.
    func partnerSawMine(before limit: Int) {
        guard let n = messages.filter(\.mine).compactMap(\.serverId).filter({ $0 < limit }).max() else { return }
        readId = max(readId, n)
        deliveredId = max(deliveredId, n)
    }

    /// Like the web, a "typing" shows for at most 10 s unless it's repeated; "stopped" or a message ends it.
    func setPartnerTyping(_ on: Bool) {
        partnerTypingEnds?.cancel()
        partnerTyping = on
        guard on else { return }
        partnerTypingEnds = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { partnerTyping = false }
        }
    }

    // Tap opens the full-size picture (fetched once per picture, then cached).
    var avatarButton: some View {
        Button {
            guard let thumb = friendThumb else { return }
            Task {
                if avatarImage == nil {
                    avatarImage = await Avatar.full(user: friend, thumb: thumb, auth: session.auth, me: session.username)
                }
                if avatarImage == nil { avatarImage = await Avatar.thumbImage(thumb) }
                if avatarImage != nil { viewingAvatar = true }
            }
        } label: {
            AvatarView(thumb: friendThumb, full: avatarImage)
        }
        .buttonStyle(.plain)
        // Grows out of the avatar, like photos in the thread.
        .zoomSource("avatar", zoom)
        .fullScreenCover(isPresented: $viewingAvatar) {
            if let avatarImage { ImageViewer(image: avatarImage).zoomTransition("avatar", zoom) }
        }
        .accessibilityLabel("\(friend)'s profile picture")
        .onChange(of: friendThumb) { avatarImage = nil }   // they changed it
    }

    var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // Floating pill with the send arrow inside it, shown only once there's text.
    var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button { takingPhoto = true } label: { Label("Camera", systemImage: "camera") }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                Button { pickingPhoto = true } label: { Label("Photos & Videos", systemImage: "photo.on.rectangle") }
                // Downloads (Safari, other apps) land in Files, not the photo library.
                Button { pickingFile = true } label: { Label("Files", systemImage: "folder") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .glass(in: Circle())
            }
            // .current keeps the original bytes (e.g. HEIC) so ImagePrep does the conversion, not Photos.
            .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .any(of: [.images, .videos]),
                          preferredItemEncoding: .current)
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.movie, .image]) { result in
                guard case .success(let url) = result else { return }
                Task { await sendFile(url) }
            }
            .fullScreenCover(isPresented: $takingPhoto) {
                CameraPicker { shot in Task { await sendCameraPhoto(shot) } }
                    .ignoresSafeArea()
            }
            .onChange(of: photo) {
                guard let item = photo else { return }
                photo = nil
                Task {
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        if let movie = try? await item.loadTransferable(type: PickedMovie.self) { await sendVideo(movie.url) }
                    } else if let data = try? await item.loadTransferable(type: Data.self) {
                        await sendImage(data)
                    }
                }
            }
            field
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // Dictation: tap to talk, tap again to stop. The words land in the message as they form.
    func micTapped() {
        switch dictation.state {
        case .idle:
            dictation.onText = { draft = $0 }
            Task { await dictation.start(after: draft) }
        case .listening: dictation.stop()
        case .finishing: break
        }
    }

    var showsMic: Bool { dictation.state != .idle || (canDictate && !canSend) }

    // Tap: start / stop dictating. Hold while dictating: stop, and send once the last words are in.
    var micButton: some View {
        Group {
            switch dictation.state {
            case .idle:
                Image(systemName: "mic").font(.system(size: 18)).foregroundStyle(.secondary)
            case .listening:
                Image(systemName: "waveform").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.red))
            case .finishing:
                ProgressView()
            }
        }
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
        .onTapGesture { micTapped() }
        .onLongPressGesture(minimumDuration: 0.4) {
            guard dictation.state == .listening else { micTapped(); return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            dictation.stop(then: { send() })
        }
        .padding(4)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(dictation.state == .listening ? "Stop Dictation" : "Dictate")
        .accessibilityAction { micTapped() }
        .accessibilityAction(named: "Stop and Send") { if dictation.state == .listening { dictation.stop(then: { send() }) } }
        .alert("Dictation", isPresented: Binding(get: { dictation.error != nil }, set: { if !$0 { dictation.error = nil } })) {
            Button("OK") {}
        } message: { Text(dictation.error ?? "") }
    }

    var field: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ComposerTextView(text: $draft, focused: $typing, showEmoji: $showingEmoji,
                             panelHeight: max(260, keyboardHeight)) { code in
                draft += " :\(code): "   // same spacing as the web's addEmoji
            }
            .overlay(alignment: .leading) {
                if draft.isEmpty {
                    Text("Message").foregroundStyle(.tertiary).padding(.leading, 14).allowsHitTesting(false)
                }
            }
            // Drafts stay plain ":code:" text; bubbles render them. Swaps keyboard <-> emoji panel.
            Button {
                showingEmoji.toggle()   // swaps the text view's inputView; it stays first responder
                typing = true
            } label: {
                Image(systemName: showingEmoji ? "keyboard" : "face.smiling")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .padding(.vertical, 4)
            .padding(.trailing, showsMic || canSend ? 0 : 6)
            .accessibilityLabel(showingEmoji ? "Keyboard" : "Emoji")
            // One trailing slot, like iMessage: the mic while empty (or dictating), the send arrow once there's text.
            if showsMic {
                micButton
            } else if canSend {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.accentColor))
                }
                .padding(4)
            }
        }
        .frame(minHeight: 38)
        .glass(in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    @ViewBuilder
    func bubble(_ m: Msg, tail: Bool, showStatus: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                if m.mine { Spacer(minLength: 60) }
                if let video = m.video {
                    ChatVideo(id: m.id, source: video)
                } else if let image = m.image {
                    ChatImage(id: m.id, source: image)
                } else {
                    MessageText(text: m.text)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .foregroundStyle(m.mine ? .white : .primary)
                        .background(BubbleShape(mine: m.mine, tail: tail).fill(m.mine ? Color.accentColor : Color(.systemGray5)))
                }
                if !m.mine { Spacer(minLength: 60) }
            }
            if m.pending == .failed {
                Button { Outbox.shared.retry(m.id) } label: {
                    Text("Not Delivered · Tap to retry").font(.caption).foregroundStyle(.red)
                }
            } else if m.failed {
                Text("Not Delivered").font(.caption).foregroundStyle(.red)
            } else if m.pending != nil, m.image != nil || m.video != nil {
                // Every unsent photo/video shows its own stage, not just the newest message.
                Text(m.detail ?? status(m)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else if showStatus {
                Text(status(m)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // Same rule as the web's updateMessagesDelivery/updateMessagesSeen (deob/modules/XBnl.js):
    // a message is delivered/seen once its id <= the partner's last delivered/seen id.
    func status(_ m: Msg) -> String {
        switch m.pending {
        case .waiting?: return connectivity.isOnline ? "Sending…" : "Waiting for connection"
        case .sending?: return "Sending…"
        case .unconfirmed?: return connectivity.isOnline ? "Checking…" : "Waiting for connection"
        default: break
        }
        guard let id = m.serverId else { return "Sending…" }
        if id <= readId { return "Read" }
        if id <= deliveredId { return "Delivered" }
        return "Sent"
    }

    // The shared whatsup loop (Whatsup.swift) returns this thread's new messages in `private`.
    func handle(_ dict: [String: Any]) {
        if let arr = dict["private"] as? [[String: Any]] {
            let stored = Store.current?.newestId(chat: friend)
            append(arr)
            // A big batch after time offline may skip messages between it and the stored history:
            // page backwards until the two meet.
            let ids = arr.compactMap { Int("\($0["id"] ?? "")") }
            if let stored, ids.count >= 10, let oldest = ids.min(), oldest > stored {
                Task { await fillGap(below: oldest, down: stored) }
            }
        }
        if let ls = dict["last_seen"] as? [Any], ls.count == 2 {
            deliveredId = max(deliveredId, Int("\(ls[0])") ?? 0)
            readId = max(readId, Int("\(ls[1])") ?? 0)
        }
    }

    // Backup for read receipts: whatsup never included last_seen in testing and the socket pushes
    // can't be observed alongside the phone (one socket per account), but each message carries
    // seen/delivered flags. While my newest message isn't Read, re-read the latest page's flags.
    func watchReadReceipts() async {
        while !Task.isCancelled {
            let hasUnread = messages.last(where: { $0.mine })?.serverId.map { $0 > readId } ?? false
            try? await Task.sleep(for: .seconds(hasUnread ? 3 : 10))
            guard let mine = messages.last(where: { $0.mine })?.serverId, mine > readId else { continue }
            await refreshLatest()
        }
    }

    var newestTheirs: Int { messages.filter { !$0.mine }.compactMap(\.serverId).max() ?? 0 }

    // Like the web, tell the sender we've read their newest message while this chat is on screen.
    func markSeenIfVisible() {
        guard UIApplication.shared.applicationState == .active, newestTheirs > 0 else { return }
        let newest = newestTheirs
        guard newest > markedSeen else { DebugLog.log("seen \(friend) \(newest) skipped: already marked \(markedSeen)"); return }
        // Only counts as sent if the socket was up; otherwise .y99SocketReady brings us back here.
        if SocketManager.shared.markSeen(target: friend, msgId: newest) { markedSeen = newest }
    }

    // private/fetch {target, private_last, pageUp, mode:"private"} -> {private: [...]} with the 20 messages
    // older than private_last, newest-first; empty (or 203) at the start of the thread. The server pages
    // by private_last alone (pageUp is ignored), so pass the oldest id held. Checked against live threads.
    func loadOlder() async {
        guard seed.isEmpty, !loadingOlder, !reachedStart,
              let oldest = messages.compactMap(\.serverId).min() else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        // Older history from the database first; the server only past what's stored.
        if let stored = Store.current?.messages(chat: friend, before: oldest, limit: 50), !stored.isEmpty {
            append(stored, persist: false)
            return
        }
        let r = await API.post("private/fetch", [
            "target": friend, "private_last": String(oldest), "pageUp": "1", "mode": "private",
        ], auth: session.auth, username: session.username)
        guard let dict = r as? [String: Any], let value = dict["private"] else { return } // failed/captcha: retry on next scroll
        guard let arr = value as? [[String: Any]], !arr.isEmpty else { reachedStart = true; return }
        append(arr)
    }

    /// Re-reads the newest page of the thread (my messages too: whatsup's `private` only brings the other
    /// person's new messages, so my own sends from before an app kill, or from the website, come from here).
    /// `private_last` far above any id returns the latest 20. Pages back further if they're all new.
    func refreshLatest() async {
        let stored = Store.current?.newestId(chat: friend)
        let r = await API.post("private/fetch", [
            "target": friend, "private_last": "2000000000", "pageUp": "1", "mode": "private",
        ], auth: session.auth, username: session.username)
        guard let arr = (r as? [String: Any])?["private"] as? [[String: Any]], !arr.isEmpty else { return }
        append(arr)
        if let stored, let oldest = arr.compactMap({ Int("\($0["id"] ?? "")") }).min(), oldest > stored {
            await fillGap(below: oldest, down: stored)
        }
    }

    /// Pages `private/fetch` backwards from `below` until reaching ids at or under `down` (max 10 pages).
    func fillGap(below: Int, down: Int) async {
        var cursor = below
        for _ in 0..<10 {
            let r = await API.post("private/fetch", [
                "target": friend, "private_last": String(cursor), "pageUp": "1", "mode": "private",
            ], auth: session.auth, username: session.username)
            guard let arr = (r as? [String: Any])?["private"] as? [[String: Any]], !arr.isEmpty else { return }
            append(arr)
            guard let oldest = arr.compactMap({ Int("\($0["id"] ?? "")") }).min(), oldest > down else { return }
            cursor = oldest
        }
    }

    func saveState() {
        guard seed.isEmpty else { return }
        Store.current?.save(chat: friend, state: .init(readId: readId, deliveredId: deliveredId,
                                                      markedSeen: markedSeen, draft: draft))
    }

    #if DEBUG
    /// Scripted input for simulator checks: -fakeDictation, -fakeTyping.
    private static var debugScriptsRan = false
    func debugScripts() {
        guard !Self.debugScriptsRan else { return }   // .task runs again when the chat reappears
        Self.debugScriptsRan = true
            if ProcessInfo.processInfo.arguments.contains("-fakeDictation") {
                // Text arriving like dictation: whole words at a time, the in-progress tail rewritten.
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    let args = ProcessInfo.processInfo.arguments
                    if args.contains("-autoclose") { try? await Task.sleep(for: .seconds(5)) }   // a video opens and closes first
                    if args.contains("-realMic") { dictation.debugListen() }
                    let words = "so I was thinking that we could maybe go out to get some food later tonight if you are not too tired from work and then we can watch a movie or something and honestly I would really love that because it has been such a long week and I miss you a lot so please let me know what you think about all of this okay".split(separator: " ")
                    var done = ""
                    for w in words {
                        draft = done + String(w.prefix(2)); try? await Task.sleep(for: .seconds(0.12))
                        done += w + " "; draft = done; try? await Task.sleep(for: .seconds(0.12))
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-fakeTyping") {
                // Partner typing at 2s, then "my" keystrokes every 0.4s.
                Task {
                    try? await Task.sleep(for: .seconds(2)); setPartnerTyping(true)
                    try? await Task.sleep(for: .seconds(3))
                    for c in "hello there friend" { try? await Task.sleep(for: .seconds(0.4)); draft.append(c) }
                }
            }
    }

    /// -rawSeed <json file>: real stored messages (a JSON array) through the normal parse path.
    func loadRawSeed() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-rawSeed"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        messages = []
        append(raw, persist: false)
    }
    #endif

    /// Adds server messages to the thread; `persist` also stores them (off when they came from the store).
    func append(_ arr: [[String: Any]], persist: Bool = true) {
        if persist && seed.isEmpty { Store.current?.save(chat: friend, arr) }
        for o in arr {
            let id = String(describing: o["id"] ?? UUID().uuidString)
            var mine = (o["hunter"] as? String) == session.username
            #if DEBUG
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-me") { mine = (o["hunter"] as? String) == ProcessInfo.processInfo.arguments[i + 1] }
            #endif
            let n = Int(id)
            // Read/delivered flags on my messages count every time they arrive, also for messages
            // already on screen (a refresh brings updated flags for those).
            if mine, let n {
                if "\(o["seen"] ?? 0)" == "1" { readId = max(readId, n) }
                if "\(o["delivered"] ?? 0)" == "1" { deliveredId = max(deliveredId, n) }
            } else if let n, n > friendThumbId, let t = o["thumb"] as? String, !t.isEmpty {
                friendThumb = t; friendThumbId = n
            }
            if seen.contains(id) {
                // y99's copy of a photo we stored without an address (sent, then offline): fill it in.
                if (o["type"] as? String) == "image", let path = o["message"] as? String, !path.isEmpty,
                   let i = messages.firstIndex(where: { $0.id == id }),
                   case .remote(let old)? = messages[i].image, old.isEmpty {
                    messages[i].image = .remote(path: path)
                }
                continue
            }
            guard let text = o["message"] as? String else { continue }
            seen.insert(id)
            if !mine && partnerTyping { setPartnerTyping(false) }
            // type "image" carries the upload path in `message` (deob/app.deob.js:8427); type "attachment"
            // (message "[ATTACHMENT]") names a file on the storage server in `attachmentId` (deob ~52432).
            var image = (o["type"] as? String) == "image" ? ImageSource.remote(path: text) : nil
            var video: VideoSource?
            var shown = text
            if (o["type"] as? String) == "attachment" || text == "[ATTACHMENT]",
               let aid = (o["attachmentId"] ?? o["attachment_id"]) as? String, !aid.isEmpty {
                if Attachments.isVideo(aid) { video = .remote(id: aid) }
                else if Attachments.isImage(aid), let u = Attachments.url(for: aid) { image = .remote(path: u.absoluteString) }
                else { shown = "Attachment" }
            }
            // History arrives newest-first, so insert by server id rather than appending.
            // Local messages still waiting on the server (serverId nil) stay at the end.
            let at = n.flatMap { n in messages.firstIndex { ($0.serverId ?? .max) > n } } ?? messages.endIndex
            messages.insert(Msg(id: id, text: shown, mine: mine, image: image, video: video, serverId: n), at: at)
            if let n, n > lastId { lastId = n }
        }
        partnerSawMine(before: newestTheirs)
        markSeenIfVisible()
    }

    // Every send goes through the outbox (Outbox.swift): stored first, then sent in order, retried
    // when the connection returns, and never sent twice. The bubble shows at once from the local copy.
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        dictation.cancel()   // nothing more of it may land in the next message
        draft = ""
        let seconds = typingMs / 1000
        typingMs = 0; lastEdit = nil
        let e = Outbox.shared.addText(chat: friend, text: text, typingSeconds: seconds)
        messages.append(Msg(id: e.id, text: HTMLText.encode(text), mine: true, pending: e.state))
    }

    /// Outbox progress for a bubble in this chat; once sent it becomes a normal message with its server id.
    func outboxChanged(_ info: [AnyHashable: Any]) {
        guard info["chat"] as? String == friend, let id = info["id"] as? String,
              let i = messages.firstIndex(where: { $0.id == id }) else { return }
        if let n = info["serverId"] as? Int {
            seen.insert(String(n))   // don't add it again when y99 echoes it back
            messages[i].serverId = n
            messages[i].pending = nil
            if n > lastId { lastId = n }
            partnerSawMine(before: newestTheirs)   // they may have replied before this send was confirmed
        } else if let raw = info["state"] as? String {
            messages[i].pending = OutboxEntry.State(rawValue: raw)
            messages[i].detail = info["detail"] as? String
        }
    }

    /// Unsent messages for this chat (also after a relaunch), shown after the history.
    func showOutbox() {
        for e in Outbox.shared.entries(chat: friend) where !messages.contains(where: { $0.id == e.id }) {
            var m = Msg(id: e.id, text: HTMLText.encode(e.text ?? ""), mine: true, pending: e.state)
            if e.kind == .photo, let url = e.fileURL, let data = try? Data(contentsOf: url) { m.image = .local(data) }
            if e.kind == .video, let url = e.fileURL { m.video = .local(url) }
            messages.append(m)
        }
    }
}

extension ChatView {
    func sendImage(_ original: Data) async {
        guard let img = await Task.detached(operation: { ImagePrep.prepare(original) }).value else {
            messages.append(Msg(id: "local-\(UUID().uuidString)", text: "", mine: true, image: .local(original), failed: true))
            return
        }
        await upload(img)
    }

    // Video: rewrap .mov as MP4 (others go as they are) here, then the outbox uploads it to the storage
    // server and sends "[ATTACHMENT]" pointing at it, the way the web's attach button does (deob ~38606).
    func sendVideo(_ picked: URL) async {
        guard let up = await VideoPrep.forUpload(picked),
              let e = Outbox.shared.addVideo(chat: friend, file: up.file, filename: up.name, mime: up.mime) else {
            messages.append(Msg(id: "local-\(UUID().uuidString)", text: "", mine: true, video: .local(picked), failed: true))
            return
        }
        messages.append(Msg(id: e.id, text: "", mine: true, video: e.fileURL.map { .local($0) }, pending: e.state))
    }

    // From Files: copy it out first (it's only lent to us, and video prep moves/deletes what it's given).
    func sendFile(_ url: URL) async {
        let lent = url.startAccessingSecurityScopedResource()
        defer { if lent { url.stopAccessingSecurityScopedResource() } }
        if UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) == true {
            if let data = try? Data(contentsOf: url) { await sendImage(data) }
            return
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
        await sendVideo(copy)
    }

    // Camera: save the shot to the library, then send it straight away.
    func sendCameraPhoto(_ shot: UIImage) async {
        Task { await CameraPicker.saveToLibrary(shot) } // sending doesn't wait on (or need) library access
        guard let img = await Task.detached(operation: { ImagePrep.prepare(photo: shot) }).value else { return }
        await upload(img)
    }

    // private/upload {target, picture, mm, ta: filename, x: savedKb} -> {delivery, msg_id} (deob/modules/CMHb.js)
    func upload(_ img: PreparedImage) async {
        guard let e = Outbox.shared.addPhoto(chat: friend, image: img) else {
            messages.append(Msg(id: "local-\(UUID().uuidString)", text: "", mine: true, image: .local(img.data), failed: true))
            return
        }
        messages.append(Msg(id: e.id, text: "", mine: true, image: .local(img.data), pending: e.state))
    }
}

extension View {
    /// Upside down; the thread and each of its rows get this, so rows read normally (see ChatView.chat).
    func flipped() -> some View { scaleEffect(x: 1, y: -1) }

    /// iOS 26 blurs scroll content at the bars; on the flipped thread that lands on the wrong edges.
    /// Liquid Glass on iOS 26; a plain outlined shape before it.
    @ViewBuilder func glass(in shape: some Shape) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(shape.fill(Color(.systemBackground))).overlay(shape.stroke(Color(.systemGray4)))
        }
    }

    @ViewBuilder func noScrollEdgeEffect() -> some View {
        if #available(iOS 26, *) { scrollEdgeEffectHidden() } else { self }
    }
}

// Covers the status bar and top bar plus a little below, darkest at the top and clear at the bottom.
struct TopFade: View {
    var body: some View {
        GeometryReader { g in
            Color(.systemBackground)
            // One smooth ramp that never turns opaque, so rows stay faintly readable even behind the status bar.
            .mask(LinearGradient(stops: [.init(color: .black.opacity(0.75), location: 0),
                                         .init(color: .black.opacity(0.5), location: 0.45),
                                         .init(color: .black.opacity(0.2), location: 0.75),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .frame(height: g.safeAreaInsets.top + 24)
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }
}

// Rounded bubble with the curled tail at the bottom corner on the sender's side.
struct BubbleShape: Shape {
    let mine: Bool
    let tail: Bool

    func path(in r: CGRect) -> Path {
        let body = Path(roundedRect: r, cornerRadius: 18, style: .continuous)
        guard tail else { return body }
        // Drawn for the right side, then mirrored for incoming messages.
        var t = Path()
        t.move(to: CGPoint(x: r.maxX - 1, y: r.maxY - 18))
        t.addQuadCurve(to: CGPoint(x: r.maxX + 5, y: r.maxY), control: CGPoint(x: r.maxX - 1, y: r.maxY - 4))
        t.addQuadCurve(to: CGPoint(x: r.maxX - 14, y: r.maxY - 4), control: CGPoint(x: r.maxX - 6, y: r.maxY + 1))
        t.closeSubpath()
        let shape = body.union(t)
        return mine ? shape : shape.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * r.midX, ty: 0))
    }
}
