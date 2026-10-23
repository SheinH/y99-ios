#if DEBUG
import Foundation
import UIKit

// -outboxTest: runs the real Outbox against a fake y99 (FakeY99 below) that misbehaves the ways a bad
// connection does, and counts how many copies of each message reach it. Prints "OT ..." lines, then quits.
// Every web request in the run goes to the fake; nothing reaches y99.

/// What the fake does with one private/send.
enum FakeSend {
    case ok                                  // saves it, answers {delivery: delivered}
    case saveThenFail(URLError.Code)         // saves it, then the reply is lost with this error
    case failBeforeSave(URLError.Code)       // never reaches y99
    case saveThenErrorPage                   // saves it, then Cloudflare-style HTML (502)
    case alert                               // rejected: {alert}
    case saveLaterThenFail(Double, URLError.Code)   // fails now; y99 saves it this many seconds later
}

enum FakeFetch { case ok, fail(URLError.Code) }

final class FakeY99: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var me = "outboxtester"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var messages: [[String: Any]] = []
    nonisolated(unsafe) private static var nextId = 5000
    nonisolated(unsafe) static var sendPlan: [FakeSend] = []
    nonisolated(unsafe) static var fetchPlan: [FakeFetch] = []
    nonisolated(unsafe) static var floodAfterSave = 0   // the partner sends this many right after a save
    nonisolated(unsafe) static var sendsReceived = 0

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        messages = []; sendPlan = []; fetchPlan = []; floodAfterSave = 0; sendsReceived = 0
    }

    static func copies(of text: String, chat: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return messages.filter { ($0["target"] as? String) == chat && ($0["hunter"] as? String) == me
            && HTMLText.decode($0["message"] as? String ?? "") == text }.count
    }

    /// As y99 would hold it: HTML-escaped, with the server's clock.
    @discardableResult
    static func save(chat: String, text: String, from: String? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextId += 1
        messages.append(["id": nextId, "hunter": from ?? me, "target": chat, "message": HTMLText.encode(text),
                         "date": Int(Date().timeIntervalSince1970), "seen": 0, "delivered": 0])
        return nextId
    }

    private static func take<T>(_ plan: inout [T], _ fallback: T) -> T {
        lock.lock(); defer { lock.unlock() }
        return plan.isEmpty ? fallback : plan.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }   // every request, so none get out
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let fields = Self.fields(of: request)
        if path.hasSuffix("private/send") {
            let chat = fields["target"] ?? "", text = fields["message"] ?? ""
            Self.lock.lock(); Self.sendsReceived += 1; Self.lock.unlock()
            switch Self.take(&Self.sendPlan, .ok) {
            case .ok:
                let id = saved(chat, text)
                reply(["delivery": "delivered", "msg_id": id])
            case .saveThenFail(let code):
                saved(chat, text); fail(code)
            case .failBeforeSave(let code):
                fail(code)
            case .saveThenErrorPage:
                saved(chat, text); replyHTML()
            case .alert:
                reply(["alert": ["text": "Slow down"]])
            case .saveLaterThenFail(let delay, let code):
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { self.saved(chat, text) }
                fail(code)
            }
        } else if path.hasSuffix("private/fetch") {
            switch Self.take(&Self.fetchPlan, .ok) {
            case .fail(let code): fail(code)
            case .ok:
                let chat = fields["target"] ?? "", below = Int(fields["private_last"] ?? "") ?? .max
                Self.lock.lock()
                let page = Array(Self.messages.filter { ($0["target"] as? String) == chat || ($0["hunter"] as? String) == chat }
                    .filter { ($0["id"] as? Int ?? 0) < below }
                    .sorted { ($0["id"] as? Int ?? 0) > ($1["id"] as? Int ?? 0) }
                    .prefix(20))
                Self.lock.unlock()
                reply(["private": page])
            }
        } else {
            fail(.cannotConnectToHost)
        }
    }

    override func stopLoading() {}

    @discardableResult
    private func saved(_ chat: String, _ text: String) -> Int {
        let id = Self.save(chat: chat, text: text)
        for n in 0..<Self.floodAfterSave { Self.save(chat: chat, text: "partner \(n)", from: chat) }
        return id
    }

    private func reply(_ obj: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func replyHTML() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html>502 Bad gateway</html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ code: URLError.Code) { client?.urlProtocol(self, didFailWithError: URLError(code)) }

    /// The multipart form fields of a request.
    private static func fields(of req: URLRequest) -> [String: String] {
        var body = req.httpBody ?? Data()
        if body.isEmpty, let stream = req.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            stream.close()
        }
        var out: [String: String] = [:]
        for part in String(decoding: body, as: UTF8.self).components(separatedBy: "\r\n--") {
            guard let r = part.range(of: "name=\""), let end = part[r.upperBound...].firstIndex(of: "\""),
                  let split = part.range(of: "\r\n\r\n") else { continue }
            var value = String(part[split.upperBound...])
            if value.hasSuffix("\r\n") { value.removeLast(2) }
            out[String(part[r.upperBound..<end])] = value
        }
        return out
    }
}

@MainActor enum OutboxTest {
    struct Scenario {
        let name: String
        var text = "hello there"
        var send: [FakeSend]
        var fetch: [FakeFetch] = []
        var flood = 0
        var expectFailedThenRetry = false   // gives up first; then the user taps retry
        var killedMidSend = false            // a stored "sending" entry from a previous launch
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "plain send", send: [.ok]),
        Scenario(name: "reply lost (connection dropped)", send: [.saveThenFail(.networkConnectionLost)]),
        Scenario(name: "reply lost (timed out)", send: [.saveThenFail(.timedOut)]),
        Scenario(name: "saved, then 'not connected' (radio died mid-request)", send: [.saveThenFail(.notConnectedToInternet)]),
        Scenario(name: "saved, then Cloudflare 502 page", send: [.saveThenErrorPage]),
        Scenario(name: "never reached y99 (cannot connect)", send: [.failBeforeSave(.cannotConnectToHost)]),
        Scenario(name: "never reached y99 (not connected)", send: [.failBeforeSave(.notConnectedToInternet)]),
        Scenario(name: "rejected with alert, then ok", send: [.alert]),
        Scenario(name: "y99 saves it 3 s after the timeout", send: [.saveLaterThenFail(3, .timedOut)]),
        Scenario(name: "reply lost, partner sends 25 meanwhile", send: [.saveThenFail(.networkConnectionLost)], flood: 25),
        Scenario(name: "reply lost, checks fail until it gives up, user retries",
                 send: [.saveThenFail(.networkConnectionLost)], fetch: [.fail(.timedOut), .fail(.timedOut), .fail(.timedOut)],
                 expectFailedThenRetry: true),
        Scenario(name: "app killed mid-send (it had arrived)", send: [], killedMidSend: true),
        Scenario(name: "special characters, reply lost", text: "He's \"epic\" & <3  :bg_hype:  ok",
                 send: [.saveThenFail(.networkConnectionLost)]),
    ]

    static func run() async {
        // The simulator's own login is kept under a backup key until the end, so a cut-short run can't lose it.
        let d = UserDefaults.standard
        if d.string(forKey: "self.outboxTestBackup") == nil, let real = d.string(forKey: "self") {
            d.set(real, forKey: "self.outboxTestBackup")
        }
        d.set(#"{"auth":"fake-auth","username":"outboxtester"}"#, forKey: "self")
        Store.close()   // before its files go
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent("y99-outboxtester.sqlite" + ext)) }
        Store.open(username: FakeY99.me)
        Outbox.maxFailures = 3

        var passed = 0
        for (n, s) in scenarios.enumerated() {
            let chat = "chat\(n)"
            FakeY99.reset()
            FakeY99.sendPlan = s.send
            FakeY99.fetchPlan = s.fetch
            FakeY99.floodAfterSave = s.flood
            let start = Date()
            if s.killedMidSend {
                FakeY99.save(chat: chat, text: s.text)   // the send got through before the app died
                var e = OutboxEntry(id: UUID().uuidString, chat: chat, kind: .text, text: s.text, typingSeconds: 0)
                e.state = .sending
                e.lastTried = Date()
                Store.current?.addOutbox(id: e.id, json: String(decoding: try! JSONEncoder().encode(e), as: UTF8.self))
                Outbox.shared.kick()
            } else {
                Outbox.shared.addText(chat: chat, text: s.text, typingSeconds: 0)
            }
            var gaveUp = false
            var retried = false
            while Date().timeIntervalSince(start) < 90 {
                try? await Task.sleep(for: .milliseconds(250))
                let left = Outbox.shared.entries(chat: chat)
                if left.isEmpty { break }
                if let f = left.first(where: { $0.state == .failed }) {
                    gaveUp = true
                    if s.expectFailedThenRetry && !retried { retried = true; Outbox.shared.retry(f.id) } else { break }
                }
            }
            try? await Task.sleep(for: .seconds(4))   // anything saved late lands
            let copies = FakeY99.copies(of: s.text, chat: chat)
            let left = Outbox.shared.entries(chat: chat).count
            let ok = copies == 1 && left == 0
            if ok { passed += 1 }
            print(String(format: "OT %@ %-58@ copies=%d sends=%d queued=%d%@ (%.0f s)", ok ? "PASS" : "FAIL", s.name, copies,
                         FakeY99.sendsReceived, left, gaveUp ? " gaveUp" : "", Date().timeIntervalSince(start)))
        }
        print("OT done: \(passed)/\(scenarios.count) passed")
        if let real = d.string(forKey: "self.outboxTestBackup") { d.set(real, forKey: "self") } else { d.removeObject(forKey: "self") }
        d.removeObject(forKey: "self.outboxTestBackup")
        exit(0)
    }
}
#endif
