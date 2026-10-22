import Foundation

// Thin HTTP layer. Every call is POST <base><path> multipart/form-data with
// `auth` and `r` appended, matching deob/modules/Vwy0.js getFormData.
enum API {
    static let base = "https://api2.y99.in/api.vf.random/api.php/"

    struct File { let field: String; let filename: String; let mime: String; let data: Data }

    static let deviceCookieKey = "deviceCookie", userAgentKey = "webUserAgent"

    /// The web client's persistent device id (localStorage "cookie", getAdCookie in deob/app.deob.js),
    /// sent as `cookie` with every whatsup. Captured at login; generated the web's way if missing.
    static var deviceCookie: String {
        if let c = UserDefaults.standard.string(forKey: deviceCookieKey) { return c }
        let c = (0..<4).map { _ in String(Double.random(in: 0..<1)) }.joined().replacingOccurrences(of: ".", with: "")
        UserDefaults.standard.set(c, forKey: deviceCookieKey)
        return c
    }

    /// Requests identify as the login WKWebView (mobile Safari) instead of "Y99/1 CFNetwork/…".
    static var userAgent: String {
        UserDefaults.standard.string(forKey: userAgentKey) ?? {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return "Mozilla/5.0 (iPhone; CPU iPhone OS \(v.majorVersion)_\(v.minorVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        }()
    }

    /// Safari's multipart boundary format: "----WebKitFormBoundary" + 16 random letters/digits.
    static func webKitBoundary() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return "----WebKitFormBoundary" + String((0..<16).map { _ in chars.randomElement()! })
    }

    static func post(_ path: String, _ fields: [String: String], auth: String?, username: String,
                     file: File? = nil) async -> Any? {
        var body = fields.map { ($0.key, $0.value) }
        if let auth { body.append(("auth", auth)) }
        return await post(path, ordered: body, username: username, file: file)
    }

    /// Fields go out in exactly this order (the web's FormData order), then `r`. Include `auth` where the
    /// web puts it, e.g. private/send is message, target, auth, then the telemetry fields.
    static func request(_ path: String, ordered fields: [(String, String)], username: String,
                        file: File? = nil) -> URLRequest {
        let body = fields + [("r", Saira.encrypt(value: username))]
        let boundary = webKitBoundary()
        var data = Data()
        for (k, v) in body {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".data(using: .utf8)!)
            data.append(v.data(using: .utf8)!)
            data.append("\r\n".data(using: .utf8)!)
        }
        if let file {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.filename)\"\r\n".data(using: .utf8)!)
            data.append("Content-Type: \(file.mime)\r\n\r\n".data(using: .utf8)!)
            data.append(file.data)
            data.append("\r\n".data(using: .utf8)!)
        }
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("https://meetyou.me", forHTTPHeaderField: "Origin")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")   // axios default
        req.setValue("https://meetyou.me/", forHTTPHeaderField: "Referer")
        req.httpBody = data
        return req
    }

    static func post(_ path: String, ordered fields: [(String, String)], username: String,
                     file: File? = nil) async -> Any? {
        if case .reply(let json) = await send(request(path, ordered: fields, username: username, file: file)) { return json }
        return nil
    }

    /// How a request ended, for callers that must not send twice (the outbox).
    enum Outcome {
        case reply(Any?)   // the server answered (parsed JSON, or nil for a non-JSON body like "ok")
        case notSent       // failed before reaching the server (offline, DNS, connect): safe to resend
        case unknown       // failed after it may have reached the server (timeout, dropped connection)
    }

    /// Like post(ordered:), but says whether a failed request could have reached the server.
    /// `progress` gets the fraction of the body sent (0...1), for uploads.
    static func postOutcome(_ path: String, ordered fields: [(String, String)], username: String,
                            file: File? = nil, timeout: TimeInterval = 15,
                            progress: (@Sendable (Double) -> Void)? = nil) async -> Outcome {
        var req = request(path, ordered: fields, username: username, file: file)
        req.timeoutInterval = timeout
        return await send(req, progress: progress)
    }

    static func send(_ req: URLRequest, progress: (@Sendable (Double) -> Void)? = nil) async -> Outcome {
        do {
            let respData: Data
            if let progress, let body = req.httpBody {
                var r = req
                r.httpBody = nil
                (respData, _) = try await URLSession.shared.upload(for: r, from: body, delegate: UploadProgress(progress))
            } else {
                (respData, _) = try await URLSession.shared.data(for: req)
            }
            let json = try? JSONSerialization.jsonObject(with: respData, options: .allowFragments)
            Captcha.handle(json)
            if let dict = json as? [String: Any] {
                if let p = dict["imagePath"] as? String { ImageSource.imagePath = p }
                if let p = dict["avatarPath"] as? String { Notifier.avatarPath = p }
            }
            return .reply(json)
        } catch let e as URLError {
            return neverSent.contains(e.code) ? .notSent : .unknown
        } catch {
            return .unknown
        }
    }

    /// Reports how much of a request body has been sent.
    final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
        let report: @Sendable (Double) -> Void
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        }
    }

    /// URLError codes that mean the request never got to the server.
    static let neverSent: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed,
        .serverCertificateUntrusted, .appTransportSecurityRequiresSecureConnection,
    ]
}
