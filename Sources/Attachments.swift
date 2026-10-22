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
    @State private var playing: Playing?
    private struct Playing: Identifiable { let id = UUID(); let file: URL }

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
        .onTapGesture { if let file { playing = Playing(file: file) } }
        .fullScreenCover(item: $playing) { VideoViewer(file: $0.file) }
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
        #if DEBUG
        // -autoplay: open the player once loaded; -autoclose: close it 3 s later.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-autoplay"), !Self.autoplayed {
            Self.autoplayed = true
            playing = Playing(file: file)
            if args.contains("-autoclose") { try? await Task.sleep(for: .seconds(3)); playing = nil }
        }
        #endif
    }

    #if DEBUG
    private static var autoplayed = false
    #endif

    private static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// Full-screen video: a plain SwiftUI cover (ChatVideo presents it) with the system player and a close
// button above the picture. iOS's video framework can't read WebM, but Safari's engine can (VP8/VP9 +
// Opus), so those play in a web view in the same place.
struct VideoViewer: View {
    let file: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var useWeb = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.glassIfAvailable)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            if let player {
                VideoPlayer(player: player)
            } else if useWeb {
                WebVideo(file: file)
            } else {
                Color.black
            }
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .task {
            if (try? await AVURLAsset(url: file).load(.isPlayable)) == true {
                try? AVAudioSession.sharedInstance().setCategory(.playback)   // sound even in silent mode
                let p = AVPlayer(url: file)
                player = p
                p.play()
            } else {
                useWeb = true
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// WebKit's own player for a local file (WebM).
struct WebVideo: UIViewRepresentable {
    let file: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        // The page sits next to the video so the web view may read both.
        let dir = file.deletingLastPathComponent()
        let page = dir.appendingPathComponent("player-\(UUID().uuidString).html")
        let src = file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.lastPathComponent
        let html = """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}video{width:100%;height:100%;object-fit:contain}</style>
        <video src="\(src)" controls autoplay playsinline></video>
        """
        try? html.write(to: page, atomically: true, encoding: .utf8)
        web.loadFileURL(page, allowingReadAccessTo: dir)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { try? FileManager.default.removeItem(at: page) }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: ()) {
        web.evaluateJavaScript("document.querySelector('video')?.pause()")
    }
}
