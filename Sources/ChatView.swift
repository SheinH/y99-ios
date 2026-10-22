import SwiftUI
import PhotosUI

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
    var focusOnAppear = false
    var seed: [Msg] = []   // DEBUG harness only
    @State private var draft = ""
    @State private var typing = false   // composer has the keyboard (or the emoji panel in its place)
    @State private var lastId = 0
    @State private var deliveredId = 0   // whatsup last_seen[0]: partner's client has everything <= this
    @State private var readId = 0        // whatsup last_seen[1]: partner has seen everything <= this
    @State private var markedSeen = 0   // newest of their messages we've told the server we read
    @State private var photo: PhotosPickerItem?
    @ObservedObject private var connectivity = Connectivity.shared
    @State private var typingMs: Double = 0      // web's lkSpent: time between edits, gaps under 5s only
    @State private var lastEdit: Date?
    @State private var pickingPhoto = false
    @State private var takingPhoto = false
    @State private var showingEmoji = false          // emoji panel in the keyboard's place
    @State private var keyboardHeight: CGFloat = 336  // last seen keyboard height (incl. home-indicator area)
    @State private var loadingOlder = false
    @State private var reachedStart = false
    @State private var userScrolling = false
    // Tracks the message at the bottom edge; SwiftUI keeps that message in place when rows are
    // inserted above it or change height (older pages, images finishing loading).
    @State private var position = ScrollPosition(idType: String.self)
    @State private var pinnedToBottom = true   // only the user's own scrolling changes this

    var body: some View {
        ScrollView {
                LazyVStack(spacing: 0) {
                    if loadingOlder {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    let lastMine = messages.lastIndex(where: \.mine)
                    // Identify rows by message id, not position: history inserts shift positions, which
                    // would hand a row (and its in-flight image load) to a different message.
                    ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                        // Group runs from the same sender: tight spacing inside a run, tail on its last bubble.
                        let startsRun = i == 0 || messages[i - 1].mine != m.mine
                        let endsRun = i == messages.count - 1 || messages[i + 1].mine != m.mine
                        bubble(m, tail: endsRun, showStatus: i == lastMine)
                            .padding(.top, startsRun ? 10 : 2)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollPosition($position, anchor: .bottom)
            // Bottom-anchored so the thread rides up with the keyboard and opens at the newest message.
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // Page in older history when *the user* drags near the top. (A sentinel row's onAppear fires
            // on open because the lazy stack builds the top row before anchoring to the bottom.)
            .onScrollPhaseChange { _, phase in
                userScrolling = [.tracking, .interacting, .decelerating].contains(phase)
            }
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top < 300
            } action: { _, nearTop in
                if nearTop && userScrolling { Task { await loadOlder() } }
            }
            // Stick to the bottom like a chat app: while the user is at the end, content growing there
            // (an image swapping its 200x150 placeholder for the real size) keeps the end in view.
            .onScrollGeometryChange(for: Bool.self) { g in
                g.visibleRect.maxY >= g.contentSize.height - 60
            } action: { _, atBottom in
                if userScrolling { pinnedToBottom = atBottom }
            }
            // Also when the viewport changes (keyboard/emoji panel): the custom input view shrinks the
            // container and grows the bottom inset at once, overshooting ~270pt past the end, and unlike
            // the system keyboard nothing corrects it afterwards.
            .onScrollGeometryChange(for: [CGFloat].self) { g in
                [g.contentSize.height, g.containerSize.height, g.contentInsets.bottom]
            } action: { _, _ in
                if pinnedToBottom && !userScrolling { position.scrollTo(edge: .bottom) }
            }
            // Follow new messages at the bottom; older pages inserted at the top don't move the view.
            // No animation: an animated scroll racing the size-change re-pin below can blank lazy rows.
            .onChange(of: messages.last?.id) {
                if pinnedToBottom || messages.last?.mine == true {
                    pinnedToBottom = true
                    position.scrollTo(edge: .bottom)
                }
            }
            // A safe-area inset (not a VStack sibling) is what keeps the bar above the keyboard.
            .safeAreaInset(edge: .bottom) {
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
        .onReceive(NotificationCenter.default.publisher(for: .y99Message)) { note in
            guard let o = note.userInfo as? [String: Any],
                  (o["hunter"] as? String) == friend else { return }
            append([o])
        }
        .task {
            if focusOnAppear { typing = true }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-swapTest") {
                Task {
                    try? await Task.sleep(for: .seconds(2)); typing = true
                    try? await Task.sleep(for: .seconds(2)); showingEmoji = true
                    try? await Task.sleep(for: .seconds(2)); showingEmoji = false
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-focusLater") {
                Task { try? await Task.sleep(for: .seconds(2)); typing = true }
            }
            if ProcessInfo.processInfo.arguments.contains("-showEmojiPanel") {
                Task { try? await Task.sleep(for: .seconds(2)); showingEmoji = true; typing = true }
            }
            #endif
            if !seed.isEmpty {
                messages = seed
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-longSeed") {
                    messages = (1...40).map { Msg(id: "\($0)", text: "filler message \($0) :bg_hype:", mine: $0 % 3 == 0, serverId: $0) }
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
        .onAppear { Notifier.shared.activeChat = friend }
        .onDisappear {
            if Notifier.shared.activeChat == friend { Notifier.shared.activeChat = nil }
            if Whatsup.shared.chat?.target == friend { Whatsup.shared.chat = nil }
        }
        .onChange(of: draft) {
            let now = Date()
            if let lastEdit, now.timeIntervalSince(lastEdit) < 5 { typingMs += now.timeIntervalSince(lastEdit) * 1000 }
            lastEdit = draft.isEmpty ? nil : now
        }
        .onChange(of: [readId, deliveredId, markedSeen]) { saveState() }
        .onReceive(NotificationCenter.default.publisher(for: .y99Outbox)) { note in
            if let info = note.userInfo { outboxChanged(info) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard seed.isEmpty else { return }
            Task { await refreshLatest() }
        }
        .onChange(of: draft) { saveState() }
        .onChange(of: lastId) { if Whatsup.shared.chat?.target == friend { Whatsup.shared.chat?.privateLast = lastId } }
        .onReceive(NotificationCenter.default.publisher(for: .y99Seen)) { note in
            guard let info = note.userInfo, info["target"] as? String == friend else { return }
            if let d = info["delivered"] as? Int { deliveredId = max(deliveredId, d) }
            if let s = info["seen"] as? Int { readId = max(readId, s) }
        }
    }

    var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // Floating pill with the send arrow inside it, shown only once there's text.
    var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button { takingPhoto = true } label: { Label("Camera", systemImage: "camera") }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                Button { pickingPhoto = true } label: { Label("Photos & Videos", systemImage: "photo.on.rectangle") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color(.systemBackground)))
                    .overlay(Circle().strokeBorder(Color(.systemGray4)))
            }
            // .current keeps the original bytes (e.g. HEIC) so ImagePrep does the conversion, not Photos.
            .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .any(of: [.images, .videos]),
                          preferredItemEncoding: .current)
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
            .padding(.trailing, canSend ? 0 : 6)
            .accessibilityLabel(showingEmoji ? "Keyboard" : "Emoji")
            if canSend {
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
        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color(.systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(Color(.systemGray4)))
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
            try? await Task.sleep(for: .seconds(10))
            guard let mine = messages.last(where: { $0.mine })?.serverId, mine > readId else { continue }
            let r = await API.post("private/fetch", [
                "target": friend, "private_last": String(mine + 1), "pageUp": "1", "mode": "private",
            ], auth: session.auth, username: session.username)
            for o in (r as? [String: Any])?["private"] as? [[String: Any]] ?? [] where (o["hunter"] as? String) == session.username {
                guard let n = Int("\(o["id"] ?? "")") else { continue }
                if "\(o["seen"] ?? 0)" == "1" { readId = max(readId, n) }
                if "\(o["delivered"] ?? 0)" == "1" { deliveredId = max(deliveredId, n) }
            }
        }
    }

    // Like the web, tell the sender we've read their newest message while this chat is on screen.
    func markSeenIfVisible() {
        guard UIApplication.shared.applicationState == .active,
              let newest = messages.filter({ !$0.mine }).compactMap(\.serverId).max(), newest > markedSeen else { return }
        markedSeen = newest
        SocketManager.shared.markSeen(target: friend, msgId: newest)
    }

    // private/fetch {target, private_last, pageUp, mode:"private"} -> {private: [...]} with the 20 messages
    // older than private_last, newest-first; empty (or 203) at the start of the thread. The server pages
    // by private_last alone (pageUp is ignored), so pass the oldest id held. Checked against live threads.
    func loadOlder() async {
        guard !loadingOlder, !reachedStart,
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

    /// Adds server messages to the thread; `persist` also stores them (off when they came from the store).
    func append(_ arr: [[String: Any]], persist: Bool = true) {
        if persist && seed.isEmpty { Store.current?.save(chat: friend, arr) }
        for o in arr {
            let id = String(describing: o["id"] ?? UUID().uuidString)
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
            let mine = (o["hunter"] as? String) == session.username
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
            let n = Int(id)
            // History arrives newest-first, so insert by server id rather than appending.
            // Local messages still waiting on the server (serverId nil) stay at the end.
            let at = n.flatMap { n in messages.firstIndex { ($0.serverId ?? .max) > n } } ?? messages.endIndex
            messages.insert(Msg(id: id, text: shown, mine: mine, image: image, video: video, serverId: n), at: at)
            if let n {
                if n > lastId { lastId = n }
                // The first load has no last_seen, but each of my messages carries its own flags.
                if mine && "\(o["seen"] ?? 0)" == "1" { readId = max(readId, n) }
                if mine && "\(o["delivered"] ?? 0)" == "1" { deliveredId = max(deliveredId, n) }
            }
        }
        markSeenIfVisible()
    }

    // Every send goes through the outbox (Outbox.swift): stored first, then sent in order, retried
    // when the connection returns, and never sent twice. The bubble shows at once from the local copy.
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let seconds = typingMs / 1000
        typingMs = 0; lastEdit = nil
        let e = Outbox.shared.addText(chat: friend, text: text, typingSeconds: seconds)
        messages.append(Msg(id: e.id, text: text, mine: true, pending: e.state))
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
        } else if let raw = info["state"] as? String {
            messages[i].pending = OutboxEntry.State(rawValue: raw)
            messages[i].detail = info["detail"] as? String
        }
    }

    /// Unsent messages for this chat (also after a relaunch), shown after the history.
    func showOutbox() {
        for e in Outbox.shared.entries(chat: friend) where !messages.contains(where: { $0.id == e.id }) {
            var m = Msg(id: e.id, text: e.text ?? "", mine: true, pending: e.state)
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
