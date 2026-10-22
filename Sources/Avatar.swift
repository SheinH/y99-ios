import SwiftUI

// Profile pictures. Every message carries its sender's avatar as `thumb` ("<id>_thumb.jpeg", relative to
// avatarPath). The full size comes from system/users/profile {target} -> `avatar`, an encrypted
// "../../yimv?big=…" link (also relative to avatarPath). Both are filed in the shared DiskCache under the
// thumb's filename, which only changes when the person changes their picture, so every account on the
// phone shares them and the profile is asked for once per picture.
enum Avatar {
    // whatsup sends this (e.g. https://j4.crocfolder.com/uploads/avatar/). Remembered across launches.
    nonisolated(unsafe) static var path = UserDefaults.standard.string(forKey: "avatarPath") ?? "https://yesichat.com/uploads/avatar/" {
        didSet { if path != oldValue { UserDefaults.standard.set(path, forKey: "avatarPath") } }
    }

    static func url(_ relative: String) -> URL? {
        URL(string: relative, relativeTo: URL(string: path))?.absoluteURL.standardized
    }

    private static func thumbKey(_ thumb: String) -> String { "avatar:\(thumb)" }
    private static func fullKey(_ thumb: String) -> String { "avatar:\(thumb):full" }

    static func thumbData(_ thumb: String) async -> Data? {
        await DiskCache.image(key: thumbKey(thumb), url: url(thumb))
    }

    /// The full-size picture if it's already on disk (no network).
    static func cachedFull(_ thumb: String) async -> UIImage? {
        await decode(DiskCache.image(key: fullKey(thumb), url: nil))
    }

    static func thumbImage(_ thumb: String) async -> UIImage? { await decode(thumbData(thumb)) }

    /// Full size, from disk or else via the profile (one API call per picture).
    @MainActor static func full(user: String, thumb: String, auth: String?, me: String) async -> UIImage? {
        if let hit = await cachedFull(thumb) { return hit }
        let r = await API.post("system/users/profile", ["target": user], auth: auth, username: me)
        guard let big = (r as? [String: Any])?["avatar"] as? String, !big.isEmpty else { return nil }
        return await decode(DiskCache.image(key: fullKey(thumb), url: url(big)))
    }

    private static func decode(_ data: Data?) async -> UIImage? {
        guard let data else { return nil }
        return await Task.detached { ImagePrep.decode(data) }.value
    }
}

// Rounded-square avatar for the chat header: the cached full size if we have it (sharper), else the thumb.
struct AvatarView: View {
    let thumb: String?
    var full: UIImage?   // set once the full size has been fetched
    var size: CGFloat = 30
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = full ?? image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(.systemGray4).overlay {
                    Image(systemName: "person.fill").resizable().scaledToFit().padding(size * 0.22).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .task(id: thumb) {
            guard let thumb else { image = nil; return }
            if let full = await Avatar.cachedFull(thumb) { image = full; return }
            image = await Avatar.thumbImage(thumb)
        }
    }
}
