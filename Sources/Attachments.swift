import SwiftUI
import AVKit
import WebKit
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Send telemetry

// The web adds typing stats to every private/send (deob/app.deob.js ~8264): each value is
// base64(utf8) with "=" -> "_" and "/" -> "__", reversed. Sending without them looks scripted.
enum SendTelemetry {
    static func encode(_ v: String) -> String {
        String(Data(v.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "_")
            .replacingOccurrences(of: "/", with: "__")
            .reversed())
    }

    /// JS number formatting: integers without a decimal point, others as the shortest round-trip form.
    static func js(_ x: Double) -> String {
        x.rounded() == x && abs(x) < 1e15 ? String(Int(x)) : String(x)
    }

    /// sa: send time (ms), qn: message length (UTF-16 units, like JS), el: seconds spent typing,
    /// pt: percent typed rather than pasted, ap: JSON list of pasted strings. `se` (screen.availHeight -
    /// outerHeight) is only sent when the browser reports both; it's left out here.
    static func fields(message: String, typingSeconds: Double, pasted: [String] = []) -> [(String, String)] {
        let len = message.utf16.count
        let pastedLen = pasted.joined().utf16.count
        let typed = len > 0 ? 100 - Double(pastedLen) / Double(len) * 100 : 100
        let ap = (try? JSONSerialization.data(withJSONObject: pasted)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return [
            ("sa", encode(String(Int(Date().timeIntervalSince1970 * 1000)))),
            ("qn", encode(String(len))),
            ("el", encode(js(typingSeconds))),
            ("pt", encode(js(typed))),
            ("ap", encode(ap)),
        ]
    }
}

// MARK: - Storage server

// Attachments live on y99's storage server, not in the chat API (deob ~3098 upload, ~16120 Attached):
// POST {file, expiry} -> {attachment: "<id>"} or {error}; GET ?attachment=<id> returns the file.
// The id ends in the original filename, so its extension says what it is.
enum Attachments {
    static let endpoint = URL(string: "https://u1.chatrooms.link/kepler/storage.php")!   // app.storageEndpoint
    static let expiry = "1 day"   // what the web's chat attach button sends

    static func url(for id: String) -> URL? {
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "attachment", value: id)]
        return c?.url
    }

    static func ext(_ id: String) -> String {
        (id.components(separatedBy: "__").last ?? id).components(separatedBy: ".").last?.lowercased() ?? ""
    }
    static func isImage(_ id: String) -> Bool {
        ["jpg", "jpeg", "png", "apng", "gif", "bmp", "tiff", "tif", "webp", "svg", "heif", "avif"].contains(ext(id))
    }
    static func isVideo(_ id: String) -> Bool {
        ["mp4", "webm", "mov", "avi", "mkv", "flv", "wmv", "mpeg", "qt"].contains(ext(id))
    }

    private static func browserHeaders(_ req: inout URLRequest) {
        req.setValue("https://meetyou.me", forHTTPHeaderField: "Origin")
        req.setValue("https://meetyou.me/", forHTTPHeaderField: "Referer")
        req.setValue(API.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    }

    /// Uploads a file and returns its attachment id. The body is written to a temp file so large
    /// videos stream from disk instead of sitting in memory.
    static func upload(file: URL, filename: String, mime: String,
                       progress: (@Sendable (Double) -> Void)? = nil) async -> String? {
        let boundary = API.webKitBoundary()
        let body = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: body) }
        guard FileManager.default.createFile(atPath: body.path, contents: nil),
              let out = try? FileHandle(forWritingTo: body), let input = try? FileHandle(forReadingFrom: file) else { return nil }
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        while let chunk = try? input.read(upToCount: 1 << 20), !chunk.isEmpty { out.write(chunk) }
        out.write(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"expiry\"\r\n\r\n\(expiry)\r\n--\(boundary)--\r\n".utf8))
        try? out.close(); try? input.close()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 300   // big videos on a slow connection
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        browserHeaders(&req)
        guard let (data, _) = try? await URLSession.shared.upload(for: req, fromFile: body,
                                                                  delegate: progress.map { API.UploadProgress($0) }),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["attachment"] as? String
    }

    // Downloads are cached on disk by id; concurrent requests for one id share a single download.
    @MainActor private static var inFlight: [String: Task<URL?, Never>] = [:]

    /// Where an attachment's file lives in the cache.
    static func cacheFile(for id: String) -> URL {
        DiskCache.attachments.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_"))
    }

    /// Files a video we just sent under its attachment id, so it plays offline without a download.
    static func cacheSent(_ file: URL, as id: String) {
        let dest = cacheFile(for: id)
        try? FileManager.default.createDirectory(at: DiskCache.attachments, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.copyItem(at: file, to: dest)) != nil { DiskCache.didWrite() }
    }

    @MainActor static func download(_ id: String) async -> URL? {
        let dir = DiskCache.attachments   // shares the 500 MB limit with images
        let dest = cacheFile(for: id)
        if FileManager.default.fileExists(atPath: dest.path) { DiskCache.touch(dest); return dest }
        if let t = inFlight[id] { return await t.value }
        let t = Task<URL?, Never> {
            guard let url = url(for: id) else { return nil }
            var req = URLRequest(url: url)
            browserHeaders(&req)
            guard let (tmp, resp) = try? await URLSession.shared.download(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            guard (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { return nil }
            DiskCache.didWrite()
            return dest
        }
        inFlight[id] = t
        let result = await t.value
        inFlight[id] = nil
        return result
    }
}

// MARK: - Video prep

/// A picked video as a file (PhotosPicker hands videos over as files, not data).
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

enum VideoPrep {
    /// What goes up: QuickTime (.mov) is rewrapped as MP4, since browsers play .mov badly; anything
    /// else (mp4, webm, …) is sent as it is. Returns the file, its upload name and MIME type.
    static func forUpload(_ picked: URL) async -> (file: URL, name: String, mime: String)? {
        let stamp = Int(Date().timeIntervalSince1970)
        let type = UTType(filenameExtension: picked.pathExtension.lowercased())
        if type?.conforms(to: .quickTimeMovie) ?? true {
            guard let mp4 = await mp4(from: picked) else { return nil }
            try? FileManager.default.removeItem(at: picked)
            return (mp4, "video-\(stamp).mp4", "video/mp4")
        }
        let ext = picked.pathExtension.lowercased()
        return (picked, "video-\(stamp).\(ext)", type?.preferredMIMEType ?? "application/octet-stream")
    }

    /// Rewraps the video in an MP4 container without re-encoding (HEVC stays HEVC). Falls back to a
    /// re-encode only if the tracks can't go into MP4 as they are.
    static func mp4(from source: URL) async -> URL? {
        let asset = AVURLAsset(url: source)
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.shouldOptimizeForNetworkUse = true   // index at the front so playback can start early
            do {
                try await session.export(to: out, as: .mp4)
                return out
            } catch {
                try? FileManager.default.removeItem(at: out)
            }
        }
        return nil
    }

    /// First frame for the bubble, upright.
    static func poster(_ file: URL) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)
        guard let (cg, _) = try? await gen.image(at: .zero) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func duration(_ file: URL) async -> Double? {
        guard let d = try? await AVURLAsset(url: file).load(.duration), d.isNumeric else { return nil }
        return d.seconds
    }
}

// MARK: - Bubble and player

enum VideoSource {
    case local(URL)          // being sent from this phone
    case remote(id: String)  // attachment id on the storage server
}

// Poster frame with a play button; tap plays full screen.
struct ChatVideo: View {
    let id: String
    let source: VideoSource
    @State private var file: URL?
    @State private var poster: UIImage?
    @State private var duration: Double?
    @State private var failed = false

    private static let maxSize = CGSize(width: 240, height: 320)

    var body: some View {
        ZStack {
            if let poster {
                Image(uiImage: poster).resizable().scaledToFill()
            } else {
                Color(.systemGray5)
            }
            if failed {
                Image(systemName: "video.slash").font(.title2).foregroundStyle(.secondary)
            } else if file == nil {
                ProgressView()
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottomTrailing) {
            if let duration {
                Text(Self.clock(duration))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if let file { VideoPlayback.present(file) } }
        .accessibilityLabel("Video")
        .accessibilityAddTraits(.isButton)
        .task(id: id) { await load() }
    }

    private var size: CGSize {
        guard let s = poster?.size, s.width > 0, s.height > 0 else { return CGSize(width: 200, height: 150) }
        let k = min(Self.maxSize.width / s.width, Self.maxSize.height / s.height)
        return CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
    }

    private func load() async {
        switch source {
        case .local(let url): file = url
        case .remote(let id): file = await Attachments.download(id)
        }
        guard let file, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            failed = true   // download failed, or an empty file
            return
        }
        // No poster or length for formats iOS's video framework can't read (WebM); they still play.
        poster = await VideoPrep.poster(file)
        duration = await VideoPrep.duration(file)
    }

    private static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// Full-screen playback, presented the UIKit way so the player's own close button works. iOS's video
// framework (AVPlayer, also what Files uses) can't read WebM, but Safari's engine can (VP8/VP9 + Opus),
// so those play in a web view instead.
enum VideoPlayback {
    @MainActor static func present(_ url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback)   // play sound even in silent mode
        Task { @MainActor in
            let native = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
            let vc: UIViewController
            if native {
                let p = AVPlayerViewController()
                p.player = AVPlayer(url: url)
                vc = p
            } else {
                vc = WebVideoController(file: url)
            }
            vc.modalPresentationStyle = .fullScreen
            guard var top = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController else { return }
            while let next = top.presentedViewController { top = next }
            top.present(vc, animated: true) { (vc as? AVPlayerViewController)?.player?.play() }
        }
    }
}

/// Plays a local video file with WebKit's own player (for WebM), with a close button.
final class WebVideoController: UIViewController {
    private let file: URL
    private var web: WKWebView!

    init(file: URL) { self.file = file; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: view.bounds, configuration: config)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        view.addSubview(web)

        // The page sits next to the video so the web view may read both.
        let dir = file.deletingLastPathComponent()
        let page = dir.appendingPathComponent("player-\(UUID().uuidString).html")
        let src = file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.lastPathComponent
        let html = """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}video{position:absolute;top:56px;left:0;width:100%;height:calc(100% - 56px);object-fit:contain}</style>
        <video src="\(src)" controls autoplay playsinline></video>
        """
        try? html.write(to: page, atomically: true, encoding: .utf8)
        web.loadFileURL(page, allowingReadAccessTo: dir)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { try? FileManager.default.removeItem(at: page) }

        let close = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        close.tintColor = .white
        close.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        close.layer.cornerRadius = 20
        close.accessibilityLabel = "Close"
        close.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(close)
        NSLayoutConstraint.activate([
            close.widthAnchor.constraint(equalToConstant: 40), close.heightAnchor.constraint(equalToConstant: 40),
            close.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        web.evaluateJavaScript("document.querySelector('video')?.pause()")
    }
}
