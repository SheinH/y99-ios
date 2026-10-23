import Foundation
import UIKit

extension Notification.Name {
    /// An outbox entry changed. userInfo: id, chat, state (OutboxEntry.State raw value, or "sent"), serverId (Int, when
/// sent), detail (String, optional: the current stage of a photo/video, e.g. "Uploading 42%").
    static let y99Outbox = Notification.Name("y99Outbox")
}

/// A message waiting to go out. Stored as JSON in the account's database (Store), in send order.
struct OutboxEntry: Codable, Identifiable {
    enum Kind: String, Codable { case text, photo, video }
    enum State: String, Codable {
        case waiting      // not tried yet, or will be retried
        case sending      // request in flight
        case unconfirmed  // a request may have reached y99 without us hearing back: check before resending
        case failed       // gave up; the user can tap to retry
    }
    let id: String
    let chat: String
    let kind: Kind
    var text: String?
    var file: String?          // photo/video bytes, a file name in Outbox.dir
    var filename: String?      // name sent with the upload
    var mime: String?
    var savedKb: Double?
    var typingSeconds: Double?
    var attachmentId: String?  // video: set once uploaded, so a retry never uploads it again
    var state: State = .waiting
    var lastTried: Date?
    var failures = 0           // failed attempts while online (offline time doesn't count)
    var maybeSent: Bool?       // an earlier try may have reached y99: always check the chat before sending again
    var checkAfter: Date?      // not before then: y99 can save a message a few seconds after the reply was lost

    var fileURL: URL? { file.map { Outbox.dir.appendingPathComponent($0) } }
}

// Queued, ordered, exactly-once sending. Every message goes through here: it's stored before anything
// is sent, so nothing typed is lost to a dead connection or a closed app. One request at a time, oldest
// first, so messages arrive in the order written. y99's send has no duplicate protection, so a send whose
// outcome is unknown is checked against the chat before it's sent again.
@MainActor final class Outbox {
    static let shared = Outbox()
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("outbox")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Failed attempts (while online) before giving up: with the 2→30 s backoff, about 10 minutes.
    static var maxFailures = 24   // a var only so the DEBUG outbox test can give up sooner

    private var worker: Task<Void, Never>?
    private var woken = false
    private var waitingForCaptcha = false

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .y99Online, object: nil, queue: .main) { _ in Task { @MainActor in Outbox.shared.kick() } }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Outbox.shared.kick() }
        }
        nc.addObserver(forName: .y99CaptchaDone, object: nil, queue: .main) { _ in
            Task { @MainActor in Outbox.shared.waitingForCaptcha = false; Outbox.shared.kick() }
        }
    }

    // MARK: Adding

    func entries(chat: String) -> [OutboxEntry] { all().filter { $0.chat == chat } }

    @discardableResult
    func addText(chat: String, text: String, typingSeconds: Double) -> OutboxEntry {
        add(OutboxEntry(id: UUID().uuidString, chat: chat, kind: .text, text: text, typingSeconds: typingSeconds))
    }

    func addPhoto(chat: String, image: PreparedImage) -> OutboxEntry? {
        let name = UUID().uuidString
        guard (try? image.data.write(to: Self.dir.appendingPathComponent(name))) != nil else { return nil }
        return add(OutboxEntry(id: UUID().uuidString, chat: chat, kind: .photo, file: name,
                               filename: image.filename, mime: image.mime, savedKb: image.savedKb))
    }

    /// Takes ownership of `file` (moved into the outbox folder).
    func addVideo(chat: String, file: URL, filename: String, mime: String) -> OutboxEntry? {
        let name = UUID().uuidString + "." + file.pathExtension
        guard (try? FileManager.default.moveItem(at: file, to: Self.dir.appendingPathComponent(name))) != nil else { return nil }
        return add(OutboxEntry(id: UUID().uuidString, chat: chat, kind: .video, file: name, filename: filename, mime: mime))
    }

    /// A failed message goes back into the queue in its original place.
    func retry(_ id: String) {
        guard var e = all().first(where: { $0.id == id }), e.state == .failed else { return }
        e.state = e.maybeSent == true ? .unconfirmed : .waiting   // never resend blind what may have arrived
        e.failures = 0
        save(e)
        kick()
    }

    private func add(_ e: OutboxEntry) -> OutboxEntry {
        guard let store = Store.current, let json = encode(e) else { return e }
        store.addOutbox(id: e.id, json: json)
        kick()
        return e
    }

    // MARK: Worker

    /// Starts the worker, or wakes it from a wait (new message, back online, app active).
    func kick() {
        woken = true
        guard worker == nil else { return }
        worker = Task { await run(); worker = nil }
    }

    private func run() async {
        var sentOne = false
        while let store = Store.current {
            // Oldest entry not stuck behind a failed message in the same chat.
            var blocked = Set<String>()
            let next = all().first { e in
                if e.state == .failed { blocked.insert(e.chat); return false }
                return !blocked.contains(e.chat)
            }
            guard var e = next else { return }
            guard Connectivity.shared.isOnline, !waitingForCaptcha else {
                await nap(3600)   // until kicked (online again, captcha solved, new message)
                continue
            }
            if sentOne { await nap(0.5) }   // space out a queue flush: bursts draw Cloudflare captchas
            // Only one request is ever in flight, so a stored "sending" means the app died mid-send last
            // time: it may have gone through, so check before sending it again.
            if e.state == .sending { e.state = .unconfirmed; e.maybeSent = true }
            if e.state == .unconfirmed, let at = e.checkAfter, at > Date() {
                await nap(at.timeIntervalSinceNow)
                continue
            }

            let result = await attempt(&e, store: store)
            guard Store.current === store else { return }   // signed out mid-send
            switch result {
            case .sent(let msgId):
                finish(e, msgId: msgId, store: store)
                sentOne = true
            case .captcha:
                e.state = e.maybeSent == true ? .unconfirmed : .waiting
                save(e)
                waitingForCaptcha = true
            case .failed(let unconfirmed):
                if unconfirmed { e.maybeSent = true; e.checkAfter = Date().addingTimeInterval(Self.checkDelay) }
                e.state = e.maybeSent == true ? .unconfirmed : .waiting
                // Lost the connection: not the message's fault. It waits for .y99Online without using up a try.
                if !Connectivity.shared.isOnline { save(e); continue }
                e.failures += 1
                if e.failures >= Self.maxFailures { e.state = .failed }
                save(e)
                if e.state != .failed { await nap(min(30, pow(2, Double(min(e.failures, 5))))) }
            }
        }
    }

    private enum Result { case sent(Int), captcha, failed(unconfirmed: Bool) }

    /// How long after an unclear send to look for it in the chat.
    private static let checkDelay: TimeInterval = 8

    private func attempt(_ e: inout OutboxEntry, store: Store) async -> Result {
        guard let auth = Self.auth() else { return .failed(unconfirmed: false) }
        let me = store.username
        let bg = UIApplication.shared.beginBackgroundTask(withName: "send")
        defer { UIApplication.shared.endBackgroundTask(bg) }

        // It may already have gone through: look before sending again.
        if e.state == .unconfirmed {
            let check = await verify(e, me: me, auth: auth, store: store)
            log(e, "check: \(check)")
            switch check {
            case .found(let id): return .sent(id)
            case .unreachable: return .failed(unconfirmed: true)
            case .absent: e.maybeSent = false   // not there after the wait: this send is the only copy
            }
        }

        e.lastTried = Date()
        e.state = .sending
        save(e)

        let outcome: API.Outcome
        switch e.kind {
        case .text:
            let text = e.text ?? ""
            outcome = await API.postOutcome("private/send", ordered: [("message", text), ("target", e.chat), ("auth", auth)]
                                            + SendTelemetry.fields(message: text, typingSeconds: e.typingSeconds ?? 0), username: me)
        case .photo:
            guard let url = e.fileURL, let data = try? Data(contentsOf: url) else { return .failed(unconfirmed: false) }
            let name = e.filename ?? "IMG.jpeg"
            outcome = await API.postOutcome("private/upload", ordered: [
                ("target", e.chat), ("mm", String(Int(Date().timeIntervalSince1970 * 1000))), ("ta", name),
                ("x", String(e.savedKb ?? 0)), ("auth", auth),
            ], username: me, file: .init(field: "picture", filename: name, mime: e.mime ?? "image/jpeg", data: data),
               timeout: 120, progress: stageReporter(e))
        case .video:
            // Upload once; the id is saved before the message is sent, so a retry only resends the message.
            if e.attachmentId == nil {
                stage(e, "Uploading 0%")
                guard let url = e.fileURL,
                      let aid = await Attachments.upload(file: url, filename: e.filename ?? url.lastPathComponent,
                                                         mime: e.mime ?? "application/octet-stream", progress: stageReporter(e))
                else { return .failed(unconfirmed: false) }
                e.attachmentId = aid
                save(e)
                Attachments.cacheSent(url, as: aid)   // plays offline later without a download
            }
            stage(e, "Sending…")   // uploaded: only the message pointing at it is left
            let text = "[ATTACHMENT]"
            outcome = await API.postOutcome("private/send", ordered: [("message", text), ("target", e.chat), ("auth", auth)]
                                            + SendTelemetry.fields(message: text, typingSeconds: 0)
                                            + [("attachment", "true"), ("attachmentId", e.attachmentId ?? "")], username: me)
        }

        log(e, "send: " + { switch outcome {
            case .reply(let json): return "reply " + ((json as? [String: Any]).map { $0.keys.sorted().joined(separator: ",") } ?? "not JSON")
            case .notSent: return "never reached y99"
            case .unknown: return "unknown (may have arrived)"
        } }())
        switch outcome {
        case .reply(let json):
            let dict = json as? [String: Any]
            if dict?["delivery"] as? String == "delivered", let mid = dict?["msg_id"], let n = Int("\(mid)") { return .sent(n) }
            if dict?["miniIframe"] != nil { return .captcha }
            if dict?["alert"] != nil { return .failed(unconfirmed: false) }   // y99 turned it down
            // Anything else (an error page, a gateway timeout, odd JSON) may have come after y99 saved it.
            return .failed(unconfirmed: true)
        case .notSent:
            return .failed(unconfirmed: false)
        case .unknown:
            return .failed(unconfirmed: true)
        }
    }

    // MARK: Stages shown under photo/video bubbles

    private func stage(_ e: OutboxEntry, _ detail: String) {
        NotificationCenter.default.post(name: .y99Outbox, object: nil,
                                        userInfo: ["id": e.id, "chat": e.chat, "state": OutboxEntry.State.sending.rawValue, "detail": detail])
    }

    /// Upload progress → "Uploading N%" (whole percents only), then "Processing…" once every byte is up
    /// and y99 hasn't answered yet.
    private func stageReporter(_ e: OutboxEntry) -> @Sendable (Double) -> Void {
        let id = e.id, chat = e.chat
        nonisolated(unsafe) var last = -1
        return { fraction in
            let pct = Int(fraction * 100)
            guard pct != last else { return }
            last = pct
            let detail = pct >= 100 ? "Processing…" : "Uploading \(pct)%"
            Task { @MainActor in
                NotificationCenter.default.post(name: .y99Outbox, object: nil,
                    userInfo: ["id": id, "chat": chat, "state": OutboxEntry.State.sending.rawValue, "detail": detail])
            }
        }
    }

    // MARK: Checking an unconfirmed send

    private enum Check { case found(Int), absent, unreachable }

    /// Looks through the newest page of the chat for my message matching this entry, sent since the last
    /// try (with slack for clock differences) and not already matched to an earlier entry. Unclear cases
    /// count as absent: a rare duplicate beats a lost message.
    private func verify(_ e: OutboxEntry, me: String, auth: String, store: Store) async -> Check {
        let since = (e.lastTried ?? .distantPast).timeIntervalSince1970 - 120
        // Newest page first, then further back while pages are still newer than the send (the other
        // person may have written a lot since), up to 5 pages.
        var arr: [[String: Any]] = []
        var cursor = 2_000_000_000
        for _ in 0..<5 {
            let r = await API.postOutcome("private/fetch", ordered: [
                ("target", e.chat), ("private_last", String(cursor)), ("pageUp", "1"), ("mode", "private"), ("auth", auth),
            ], username: me)
            guard case .reply(let json) = r, let page = (json as? [String: Any])?["private"] as? [[String: Any]] else { return .unreachable }
            store.save(chat: e.chat, page)
            arr += page
            let ids = page.compactMap { Int("\($0["id"] ?? "")") }
            let dates = page.compactMap { Double("\($0["date"] ?? "")") }
            guard page.count >= 20, let oldest = ids.min(), let oldestDate = dates.min(), oldestDate >= since else { break }
            cursor = oldest
        }
        let norm = { (s: String) in s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let match = arr.compactMap { o -> Int? in
            guard (o["hunter"] as? String) == me, let id = Int("\(o["id"] ?? "")"), !store.isConfirmed(id),
                  Double("\(o["date"] ?? "")").map({ $0 >= since }) ?? false else { return nil }
            switch e.kind {
            case .text: return (o["message"] as? String).map { norm(HTMLText.decode($0)) } == norm(e.text ?? "") ? id : nil
            case .photo: return (o["type"] as? String) == "image" ? id : nil
            case .video: return (o["attachmentId"] as? String) == e.attachmentId && e.attachmentId != nil ? id : nil
            }
        }.min()
        return match.map { .found($0) } ?? .absent
    }

    // MARK: Done

    private func finish(_ e: OutboxEntry, msgId: Int, store: Store) {
        store.confirm(msgId)
        // Into the chat's history right away, so it survives going offline before y99 echoes it back
        // (the echo or the next refresh replaces this with y99's own copy).
        var obj: [String: Any] = ["id": msgId, "hunter": store.username, "target": e.chat,
                                  "date": Int(Date().timeIntervalSince1970), "delivered": 0, "seen": 0]
        switch e.kind {
        case .text: obj["message"] = HTMLText.encode(e.text ?? "")   // as y99 stores it
        case .photo:
            obj["type"] = "image"; obj["message"] = ""   // the photo shows from the cache by message id
            if let url = e.fileURL, let data = try? Data(contentsOf: url) { ImageSource.cacheSent(data, messageId: msgId) }
        case .video:
            obj["type"] = "attachment"; obj["message"] = "[ATTACHMENT]"; obj["attachmentId"] = e.attachmentId ?? ""
        }
        store.save(chat: e.chat, [obj])
        store.removeOutbox(id: e.id)
        if let url = e.fileURL { try? FileManager.default.removeItem(at: url) }
        NotificationCenter.default.post(name: .y99Outbox, object: nil,
                                        userInfo: ["id": e.id, "chat": e.chat, "state": "sent", "serverId": msgId])
    }

    // MARK: Storage

    private func all() -> [OutboxEntry] {
        (Store.current?.outbox() ?? []).compactMap { try? JSONDecoder().decode(OutboxEntry.self, from: Data($0.utf8)) }
    }

    private func log(_ e: OutboxEntry, _ what: String) {
        DebugLog.log("outbox \(e.id.prefix(8)) \(e.chat): \(what)")
    }

    private func save(_ e: OutboxEntry) {
        guard let json = encode(e) else { return }
        Store.current?.updateOutbox(id: e.id, json: json)
        NotificationCenter.default.post(name: .y99Outbox, object: nil,
                                        userInfo: ["id": e.id, "chat": e.chat, "state": e.state.rawValue])
    }

    private func encode(_ e: OutboxEntry) -> String? {
        (try? JSONEncoder().encode(e)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Sleeps up to `seconds`, ending early when kicked (including a kick that came in during the last attempt).
    private func nap(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while !woken, Date() < end { try? await Task.sleep(for: .milliseconds(250)) }
        woken = false
    }

    private static func auth() -> String? {
        guard let s = UserDefaults.standard.string(forKey: "self"),
              let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return nil }
        return d["auth"] as? String
    }
}
