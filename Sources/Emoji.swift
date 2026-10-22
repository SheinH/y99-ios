import SwiftUI
import UIKit
import SDWebImage

// y99 custom emoji, mirroring the web client's message renderer (deob/app.deob.js ~51590):
// messages carry plain ":code:" text and only render it when they contain at least two ':'.
//   :name:      in EmojiData.png / dmoji / gif   -> /png/name.png, /dmoji/name.png, /gif/name.gif (checked in that order)
//   :tp_<hex>:  Twemoji                           -> shown as the native iOS emoji instead of downloading
//   :bp_<name>: blob PNG                          -> /blobs2/png_32/<name>.png, or the animated GIF when one exists
//   :bg_<name>: blob GIF                          -> /blobs2/resized/<name>.gif
// The web only animates bp_ blobs when its "Load Animated Emojis" setting is on; we always do. Both CDN
// variants are 32x32 (no larger originals exist), and only the animatedBlobs names have a GIF: checked all
// 354 png blobs, 84 have /resized/ GIFs and those are exactly the ones in animatedBlobs.
// Blob names drop the first "agoogle"/"google"/"ablob"/"blob" ("" -> "blank") and must be in either
// blob list; anything that doesn't resolve stays as text.
// Blobs are baked into the app (Blobs/<site name>.webp, 128px originals, animated version where one
// exists) and used instead of the CDN files; only the two without an original fall back to the CDN.
enum Emoji {
    static let base = "https://cdn.y99.in/emojis"

    enum Piece: Equatable {
        case text(String)
        case image(code: String, url: URL)
    }

    private static let pngSet = Set(EmojiData.png)
    private static let dmojiSet = Set(EmojiData.dmoji)
    private static let gifSet = Set(EmojiData.gif)
    private static let blobSet = Set(EmojiData.animatedBlobs + EmojiData.blobs)
    private static let animatedSet = Set(EmojiData.animatedBlobs)
    private static let pattern = try! NSRegularExpression(pattern: ":([a-z0-9_-]+):", options: .caseInsensitive)

    /// Image URL for a code (without colons), or nil if it isn't an image emoji.
    static func url(for code: String) -> URL? {
        let path: String
        if pngSet.contains(code) { path = "png/\(code).png" }
        else if dmojiSet.contains(code) { path = "dmoji/\(code).png" }
        else if gifSet.contains(code) { path = "gif/\(code).gif" }
        else if code.hasPrefix("bp_") || code.hasPrefix("bg_"), let n = blobName(code) {
            if let baked = Bundle.main.url(forResource: n, withExtension: "webp", subdirectory: "Blobs") { return baked }
            path = code.hasPrefix("bg_") || animatedSet.contains(n) ? "blobs2/resized/\(n).gif" : "blobs2/png_32/\(n).png"
        }
        else { return nil }
        return URL(string: "\(base)/\(path)")
    }

    private static func blobName(_ code: String) -> String? {
        var n = String(code.dropFirst(3))
        for junk in ["agoogle", "google", "ablob", "blob"] {   // same sequence of first-occurrence removals as the web
            if let r = n.range(of: junk) { n.removeSubrange(r) }
        }
        if n.isEmpty { n = "blank" }
        return blobSet.contains(n) ? n : nil
    }

    /// ":tp_1f600:" -> "😀". The web strips FE0F and ZWJ (200D) when building these codes
    /// (emojiToTwString), so put a ZWJ back between base emoji and FE0F after a lone BMP symbol.
    static func native(_ code: String) -> String? {
        guard code.hasPrefix("tp_") else { return nil }
        let scalars = code.dropFirst(3).split(separator: "-").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
        guard !scalars.isEmpty, scalars.count == code.dropFirst(3).split(separator: "-").count else { return nil }
        func joinsDirectly(_ s: Unicode.Scalar) -> Bool {
            (0x1F3FB...0x1F3FF).contains(s.value) ||   // skin tones
            (0x1F1E6...0x1F1FF).contains(s.value) ||   // regional indicators (flags)
            (0xE0020...0xE007F).contains(s.value) ||   // tag sequences (subdivision flags)
            s.value == 0x20E3                          // keycap
        }
        var out = String.UnicodeScalarView()
        for (i, s) in scalars.enumerated() {
            if i > 0 && !joinsDirectly(s) && !joinsDirectly(scalars[i - 1]) { out.append("\u{200D}") }
            out.append(s)
        }
        if scalars.count == 1 && scalars[0].value < 0x1F000 { out.append("\u{FE0F}") }
        return String(out)
    }

    /// Splits a message into text and image pieces; Twemoji codes become native emoji text.
    static func pieces(_ text: String) -> [Piece] {
        guard text.filter({ $0 == ":" }).count >= 2 else { return [.text(text)] }
        var out: [Piece] = []
        var buffer = ""
        var cursor = text.startIndex
        let ns = text as NSString
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let whole = Range(m.range, in: text), let codeRange = Range(m.range(at: 1), in: text) else { continue }
            let code = String(text[codeRange])
            buffer += text[cursor..<whole.lowerBound]
            if let url = url(for: code) {
                if !buffer.isEmpty { out.append(.text(buffer)); buffer = "" }
                out.append(.image(code: code, url: url))
            } else if let native = native(code) {
                buffer += native
            } else {
                buffer += text[whole]
            }
            cursor = whole.upperBound
        }
        buffer += text[cursor...]
        if !buffer.isEmpty { out.append(.text(buffer)) }
        return out
    }

    /// Every image emoji the picker offers / the renderer accepts (for prefetching).
    static var allImageURLs: [URL] {
        let codes = EmojiData.png + EmojiData.dmoji + EmojiData.gif
            + EmojiData.animatedBlobs.map { "bg_" + $0 } + EmojiData.blobs.map { "bp_" + $0 }
        return Array(Set(codes.compactMap(url(for:)).filter { !$0.isFileURL }))   // baked blobs need no download
    }
}

// Disk cache under Caches/emoji, mirroring the CDN path. Emoji play straight from files (baked or cached).
actor EmojiStore {
    static let shared = EmojiStore()
    private let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("emoji")
    private var prefetching = false

    private func file(for url: URL) -> URL {
        dir.appendingPathComponent(url.path.replacingOccurrences(of: "/emojis/", with: ""))
    }

    /// A local file for the emoji: the baked file itself, or the CDN file once it's on disk.
    func localFile(for url: URL) async -> URL? {
        if url.isFileURL { return url }
        let f = file(for: url)
        if FileManager.default.fileExists(atPath: f.path) { return f }
        return await data(for: url) != nil ? f : nil
    }

    private func data(for url: URL) async -> Data? {
        let f = file(for: url)
        if let d = try? Data(contentsOf: f) { return d }
        guard let (d, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: f)
        return d
    }

    /// Downloads every image emoji not already on disk (~4.4 MB the first time), 8 at a time.
    func prefetchAll() async {
        guard !prefetching else { return }
        prefetching = true
        defer { prefetching = false }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("blobs2"))   // superseded by baked blobs
        let missing = Emoji.allImageURLs.filter { !FileManager.default.fileExists(atPath: file(for: $0).path) }
        await withTaskGroup(of: Void.self) { group in
            for (i, url) in missing.enumerated() {
                if i >= 8 { await group.next() }
                group.addTask { _ = await self.data(for: url) }
            }
        }
    }
}

// One emoji at text size, played by SDWebImage's SDAnimatedImageView: frames are decoded on background
// threads at the on-screen pixel size into a small buffer, and only while the view is on screen.
// (Pre-decoding every frame took 10.8 s / 146 MB for the 40 tiles visible when the Animated tab opens;
// ImageIO's CGAnimateImageAtURLWithBlock fixed the wait but decoded full-size frames on the main thread.)
struct EmojiImage: View {
    let url: URL
    var size: CGFloat = 22
    @State private var file: URL?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let file { EmojiPlayer(file: file, pixels: size * scale) } else { Color.clear }
        }
        .frame(width: size, height: size)
        .task(id: url) { file = await EmojiStore.shared.localFile(for: url) }
    }
}

struct EmojiPlayer: UIViewRepresentable {
    let file: URL
    let pixels: CGFloat

    // One decoded-at-size image per (file, size), shared by every view showing that emoji.
    private static let images = NSCache<NSString, SDAnimatedImage>()

    static func image(_ file: URL, pixels: CGFloat) -> SDAnimatedImage? {
        let key = "\(file.path)@\(Int(pixels))" as NSString
        if let hit = images.object(forKey: key) { return hit }
        guard let data = try? Data(contentsOf: file),
              let img = SDAnimatedImage(data: data, scale: 1, options: [
                  .decodeThumbnailPixelSize: NSValue(cgSize: CGSize(width: pixels, height: pixels)),
              ]) else { return nil }
        images.setObject(img, forKey: key)
        return img
    }

    func makeUIView(context: Context) -> SDAnimatedImageView {
        let v = SDAnimatedImageView()
        v.contentMode = .scaleAspectFit
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            v.setContentCompressionResistancePriority(.defaultLow, for: axis)
            v.setContentHuggingPriority(.defaultLow, for: axis)
        }
        v.image = Self.image(file, pixels: pixels)
        return v
    }

    func updateUIView(_ v: SDAnimatedImageView, context: Context) {
        let img = Self.image(file, pixels: pixels)
        if v.image !== img { v.image = img }
    }
}

// y99's message text is HTML-escaped by the server (the web sends it raw, just trimmed: deob/modules/CMHb.js).
// Messages here are kept in that escaped form, including our own copies, and decoded only for display.
enum HTMLText {
    /// What the web undoes before showing a message, in this order (deob/app.deob.js ~51572).
    static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
    }

    /// The server's escaping, for our own copy of a message we sent (`&` first so nothing is escaped twice).
    static func encode(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#039;")
    }
}

// Message text with inline emoji. Plain messages stay a single Text (normal wrapping/selection);
// messages with image emoji are laid out word by word so the images flow inside the line.
struct MessageText: View {
    let text: String

    var body: some View {
        let pieces = Emoji.pieces(HTMLText.decode(text))
        if pieces.allSatisfy({ if case .text = $0 { true } else { false } }) {
            Text(pieces.map { if case .text(let s) = $0 { s } else { "" } }.joined())
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines(pieces).enumerated()), id: \.offset) { _, line in
                    FlowLayout {
                        ForEach(Array(line.enumerated()), id: \.offset) { _, token in
                            switch token {
                            case .text(let s): Text(s)
                            case .image(_, let url): EmojiImage(url: url)
                            }
                        }
                    }
                }
            }
        }
    }

    // Split into lines (explicit newlines), then into words keeping their trailing space.
    private func lines(_ pieces: [Emoji.Piece]) -> [[Emoji.Piece]] {
        var lines: [[Emoji.Piece]] = [[]]
        for p in pieces {
            guard case .text(let s) = p else { lines[lines.count - 1].append(p); continue }
            for (i, part) in s.components(separatedBy: "\n").enumerated() {
                if i > 0 { lines.append([]) }
                var word = ""
                for ch in part {
                    word.append(ch)
                    if ch == " " { lines[lines.count - 1].append(.text(word)); word = "" }
                }
                if !word.isEmpty { lines[lines.count - 1].append(.text(word)) }
            }
        }
        return lines
    }
}

// Left-aligned wrapping row, items vertically centred on each line.
struct FlowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, maxWidth: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - s.height) / 2), proposal: ProposedViewSize(s))
                x += s.width
            }
            y += row.height
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + s.width > maxWidth && !rows[rows.count - 1].items.isEmpty { rows.append(Row()) }
            rows[rows.count - 1].items.append(i)
            rows[rows.count - 1].width += s.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, s.height)
        }
        return rows
    }
}

// Emoji panel that takes the keyboard's place under the composer (ChatView swaps between the two).
// Tabs follow the web (minus Twemoji: the iOS keyboard covers that). Tapping inserts " :code: " like
// the web's addEmoji.
/// Recently used emoji: ranked by how often each was tapped among the last 50 taps, ties going to the
/// most recent. The panel shows a snapshot taken when it opens, so the row doesn't reshuffle while
/// you're tapping.
@MainActor final class RecentEmoji: ObservableObject {
    static let shared = RecentEmoji()
    private static let key = "recentEmojiTaps", window = 50

    @Published private(set) var snapshot: [String] = []

    func record(_ code: String) {
        var taps = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        taps.append(code)
        UserDefaults.standard.set(Array(taps.suffix(Self.window)), forKey: Self.key)
    }

    /// Call when the panel opens.
    func refresh() {
        let taps = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        var count: [String: Int] = [:], last: [String: Int] = [:]
        for (i, c) in taps.enumerated() { count[c, default: 0] += 1; last[c] = i }
        snapshot = count.keys
            .filter { Emoji.url(for: $0) != nil }
            .sorted { (count[$0]!, last[$0]!) > (count[$1]!, last[$1]!) }
    }
}

struct EmojiPanel: View {
    let onPick: (String) -> Void
    @State private var tab = 0
    @ObservedObject private var recent = RecentEmoji.shared
    private static let cell: CGFloat = 44, gap: CGFloat = 6, side: CGFloat = 12

    private let tabs: [(title: String, codes: [String])] = [
        ("Animated", EmojiData.animatedBlobs.map { "bg_" + $0 }),
        ("Blobs", EmojiData.blobs.map { "bp_" + $0 }),
        ("GIF", EmojiData.gif),
        ("Classic", EmojiData.png + EmojiData.dmoji),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // One row of recents, as many as fit across; nothing at all until something has been used.
            if !recent.snapshot.isEmpty {
                GeometryReader { g in
                    let fit = max(1, Int((g.size.width - 2 * Self.side + Self.gap) / (Self.cell + Self.gap)))
                    HStack(spacing: Self.gap) {
                        ForEach(recent.snapshot.prefix(fit), id: \.self) { code in button(code) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Self.side)
                }
                .frame(height: Self.cell)
                .padding(.top, 8)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Recently used")
            }
            Picker("Category", selection: $tab) {
                ForEach(tabs.indices, id: \.self) { Text(tabs[$0].title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
                    ForEach(tabs[tab].codes, id: \.self) { code in button(code) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .id(tab)   // each tab starts at the top
        }
    }

    @ViewBuilder private func button(_ code: String) -> some View {
        if let url = Emoji.url(for: code) {
            Button {
                RecentEmoji.shared.record(code)
                onPick(code)
            } label: { EmojiImage(url: url, size: 36).frame(width: Self.cell, height: Self.cell) }
            .accessibilityLabel(code)
        }
    }
}
