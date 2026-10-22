import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// Pre-upload conversion, mirroring the web client (deob/app.deob.js ~38450):
// jpeg/png/gif go up untouched; webp -> png; heic/heif/avif (and anything else ImageIO reads) -> jpeg.
// Converted images get their EXIF orientation baked into the pixels, so no orientation tag is needed.
struct PreparedImage {
    let data: Data
    let filename: String
    let mime: String
    let savedKb: Double   // the web sends (original - uploaded) / 1000 as `x`
}

enum ImagePrep {
    static func prepare(_ original: Data) -> PreparedImage? {
        guard let src = CGImageSourceCreateWithData(original as CFData, nil),
              let typeId = CGImageSourceGetType(src),
              let type = UTType(typeId as String) else { return nil }
        let name = "IMG_\(Int(Date().timeIntervalSince1970))"

        for (passthrough, ext) in [(UTType.jpeg, "jpg"), (.png, "png"), (.gif, "gif")] where type.conforms(to: passthrough) {
            return PreparedImage(data: original, filename: "\(name).\(ext)",
                                 mime: passthrough.preferredMIMEType!, savedKb: 0)
        }

        let out: UTType = type.conforms(to: .webP) ? .png : .jpeg
        guard let cg = upright(src),
              let data = encode(cg, as: out) else { return nil }
        return PreparedImage(data: data, filename: "\(name).\(out.preferredFilenameExtension!)",
                             mime: out.preferredMIMEType!,
                             savedKb: Double(original.count - data.count) / 1000)
    }

    // Camera shots arrive as a UIImage with an orientation flag; redraw upright at full pixel size,
    // then encode like the HEIC path (ImageIO default JPEG, no orientation tag).
    static func prepare(photo: UIImage) -> PreparedImage? {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let size = CGSize(width: photo.size.width * photo.scale, height: photo.size.height * photo.scale)
        let upright = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            photo.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cg = upright.cgImage, let data = encode(cg, as: .jpeg) else { return nil }
        return PreparedImage(data: data, filename: "IMG_\(Int(Date().timeIntervalSince1970)).jpeg",
                             mime: "image/jpeg", savedKb: 0)
    }

    // Full-resolution decode with the EXIF orientation applied to the pixels.
    private static func upright(_ src: CGImageSource) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // ImageIO's default encoder settings (no quality override). Only pixels + colour profile
    // are written: no orientation tag, and no EXIF/GPS carried over.
    private static func encode(_ cg: CGImage, as type: UTType) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // Decodes still or animated (GIF) data for display.
    // Animated GIF or WebP (ImageIO composites WebP sub-frames to full canvas). `maxPixel` downsamples
    // each frame, e.g. for emoji: a 133-frame 128px blob is ~8.7 MB decoded at full size.
    static func decode(_ data: Data, maxPixel: Int? = nil) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        func frame(_ i: Int) -> CGImage? {
            guard let maxPixel else { return CGImageSourceCreateImageAtIndex(src, i, nil) }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary)
        }
        guard count > 1 else {
            if maxPixel == nil { return UIImage(data: data) }
            return frame(0).map { UIImage(cgImage: $0) }
        }
        var frames: [UIImage] = []
        var duration = 0.0
        for i in 0..<count {
            guard let cg = frame(i) else { continue }
            frames.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let anim = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                ?? props?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let delay = anim?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? anim?[kCGImagePropertyWebPUnclampedDelayTime] as? Double
                ?? anim?[kCGImagePropertyGIFDelayTime] as? Double
                ?? anim?[kCGImagePropertyWebPDelayTime] as? Double ?? 0.1
            duration += delay < 0.011 ? 0.1 : delay   // browsers treat ~0 delays as 100ms
        }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
}

enum ImageSource {
    case local(Data)
    case remote(path: String)

    var key: String {
        switch self { case .local: "local"; case .remote(let p): p }
    }

    // whatsup overrides this (e.g. https://j4.crocfolder.com/uploads/); paths are resolved at load time.
    // Remembered across launches, so paths resolve the same way before (or without) a server reply.
    nonisolated(unsafe) static var imagePath = UserDefaults.standard.string(forKey: "imagePath") ?? "https://yesichat.com/uploads/" {
        didSet { if imagePath != oldValue { UserDefaults.standard.set(imagePath, forKey: "imagePath") } }
    }

    // uploadize(): paths are relative to imagePath unless already absolute (deob/app.deob.js:15586).
    // They can climb out of it ("../../yimv2.php?ja=…"), so resolve like a browser would.
    static func url(for path: String) -> URL? {
        URL(string: path, relativeTo: URL(string: imagePath))?.absoluteURL.standardized
    }

    /// Disk-cache keys for a chat photo, by message id (its address isn't stable: see DiskCache.imageFile).
    static func fullKey(_ messageId: String) -> String { "msg:\(messageId):full" }
    static func thumbKey(_ messageId: String) -> String { "msg:\(messageId):thumb" }

    /// Files a photo we just sent as that message's full-size image, so it shows offline without a download.
    /// y99 stores the upload as sent (minus metadata), so our copy is the same picture.
    static func cacheSent(_ data: Data, messageId: Int) {
        let file = DiskCache.imageFile(key: fullKey(String(messageId)))
        Task.detached(priority: .utility) { DiskCache.write(data, to: file) }
    }
}

// Rounded image for the thread; animates GIFs. Remote images show the server thumbnail first,
// then swap in the full-size file. Tap opens the full-screen viewer.
struct ChatImage: View {
    let id: String
    let source: ImageSource
    @State private var image: UIImage?
    @State private var failed = false
    @State private var expired = false   // y99 deleted it and there's no copy here
    @State private var viewing = false
    @Namespace private var zoom

    private static let cache = NSCache<NSString, UIImage>()
    // photo.slash is newer than iOS 18; older systems get the closest older symbol.
    private static let expiredSymbol = UIImage(systemName: "photo.slash") != nil ? "photo.slash" : "photo.badge.exclamationmark"
    private static let maxSize = CGSize(width: 240, height: 320)

    var body: some View {
        Group {
            if let image {
                // Explicit size (not a max frame) so the image hugs its side of the thread instead of centring in 240pt.
                AnimatedImageView(image: image)
                    .frame(width: fitted(image.size).width, height: fitted(image.size).height)
                    .contentShape(Rectangle())
                    .onTapGesture { viewing = true }
            } else if expired {
                // Gone for good: a quiet note, not a placeholder box for a picture that will never come.
                Label("Photo expired", systemImage: Self.expiredSymbol)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                Color(.systemGray5)
                    .frame(width: 200, height: 150)
                    .overlay {
                        if failed {
                            Image(systemName: "photo.badge.exclamationmark").font(.title2).foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .zoomSource(id, zoom)
        .fullScreenCover(isPresented: $viewing) {
            if let image { ImageViewer(image: image).zoomTransition(id, zoom) }
        }
        .task(id: "\(id)|\(source.key)") { await load() }   // reload when the address arrives
    }

    private func fitted(_ s: CGSize) -> CGSize {
        guard s.width > 0, s.height > 0 else { return CGSize(width: 200, height: 150) }
        let k = min(Self.maxSize.width / s.width, Self.maxSize.height / s.height)
        return CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
    }

    private func load() async {
        if let hit = Self.cache.object(forKey: id as NSString) { image = hit; failed = false; return }
        switch source {
        case .local(let d):
            image = await Self.decode(d)
            if let image { Self.cache.setObject(image, forKey: id as NSString) }
        case .remote(let path):
            // Same rule as the web viewer: full size = the path with its first "_thumb" removed
            // ("…&_thumb_k=1" -> "…&_k=1"; e.g. 46x100 thumb vs 1179x2556 full).
            var full = path
            if let r = path.range(of: "_thumb") {
                full.removeSubrange(r)
                // Skip the thumb when the full size is already on disk.
                if image == nil, !DiskCache.has(ImageSource.fullKey(id)),
                   let thumb = await Self.fetch(path, key: ImageSource.thumbKey(id)).image { image = thumb }
            }
            // Only the full-size image goes in the memory cache: if this load is cancelled (row scrolled
            // away) or fails, the next appearance tries again instead of keeping the blurry thumb.
            let big = await Self.fetch(full, key: ImageSource.fullKey(id))
            if let img = big.image {
                image = img
                Self.cache.setObject(img, forKey: id as NSString)
            }
            expired = image == nil && big.gone
        }
        failed = image == nil
    }

    // Disk first (by message-id key), then the network; downloads are saved under that key.
    // A photo we just sent is on disk without an address until y99 echoes it, so the path may be empty.
    private static func fetch(_ path: String, key: String) async -> (image: UIImage?, gone: Bool) {
        let url = path.isEmpty ? nil : ImageSource.url(for: path)
        switch await DiskCache.fetch(key: key, url: url) {
        case .image(let data): return (await decode(data), false)
        case .gone: return (nil, true)
        case .failed: return (nil, false)
        }
    }

    private static func decode(_ data: Data) async -> UIImage? {
        await Task.detached { ImagePrep.decode(data) }.value
    }
}

// Full-screen viewer: pinch / double-tap to zoom, share, and (iOS 18+) drag down to dismiss.
struct ImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZoomableImage(image: image)
                .ignoresSafeArea()
                .background(Color.black)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Photo", image: Image(uiImage: image)))
                    }
                }
        }
        .environment(\.colorScheme, .dark)
    }
}

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomView {
        let v = ZoomView()
        v.imageView.image = image
        return v
    }

    func updateUIView(_ v: ZoomView, context: Context) { v.imageView.image = image }

    final class ZoomView: UIScrollView, UIScrollViewDelegate {
        let imageView = UIImageView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            maximumZoomScale = 4
            showsVerticalScrollIndicator = false
            showsHorizontalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            if zoomScale == 1 { imageView.frame = bounds; contentSize = bounds.size }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc private func toggleZoom(_ g: UITapGestureRecognizer) {
            if zoomScale > 1 { setZoomScale(1, animated: true); return }
            let p = g.location(in: imageView), k: CGFloat = 2.5
            let size = CGSize(width: bounds.width / k, height: bounds.height / k)
            zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

extension View {
    // The Photos-style zoom from thumbnail to viewer needs iOS 18; earlier versions get the plain cover.
    @ViewBuilder func zoomSource(_ id: String, _ ns: Namespace.ID) -> some View {
        if #available(iOS 18, *) { matchedTransitionSource(id: id, in: ns) } else { self }
    }
    @ViewBuilder func zoomTransition(_ id: String, _ ns: Namespace.ID) -> some View {
        if #available(iOS 18, *) { navigationTransition(.zoom(sourceID: id, in: ns)) } else { self }
    }
}

// SwiftUI's Image doesn't play animated UIImages; UIImageView does.
struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage
    var contentMode: UIView.ContentMode = .scaleAspectFill

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = contentMode
        v.clipsToBounds = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) { v.image = image }
}
