import UIKit
import WidgetKit

// Keeps the Home Screen widget's data current: the friends list for its picker, and a high-res profile
// picture for each friend that actually has a widget (one profile request per picture, spaced out).
@MainActor enum WidgetSync {
    private static var running = false

    static func sync(friends: [String], favorites: Set<String>, thumbs: [String: String], auth: String?, me: String) async {
        guard !running, !friends.isEmpty else { return }
        running = true
        defer { running = false }

        let ordered = friends.filter(favorites.contains) + friends.filter { !favorites.contains($0) }
        var people: [WidgetShared.Person] = []
        for name in ordered {
            let thumb = thumbs[name] ?? newestThumb(of: name)
            people.append(.init(name: name, thumbURL: thumb.flatMap { Avatar.url($0)?.absoluteString }, thumb: thumb))
        }
        WidgetShared.save(people)

        var changed = false
        // Any high-res picture already in the app's cache goes over now (no network), so a widget added
        // later starts sharp instead of on the thumb.
        for p in people {
            guard let thumb = p.thumb, !upToDate(p.name, thumb), let img = await Avatar.cachedFull(thumb) else { continue }
            if await savePhoto(img, name: p.name, thumb: thumb) { changed = true }
        }
        // Friends with a widget get theirs fetched if it isn't cached (one profile request each, spaced out).
        for name in await configuredFriends() {
            guard let thumb = people.first(where: { $0.name == name })?.thumb, !upToDate(name, thumb),
                  let img = await Avatar.full(user: name, thumb: thumb, auth: auth, me: me) else { continue }
            if await savePhoto(img, name: name, thumb: thumb) { changed = true }
            try? await Task.sleep(for: .seconds(1))
        }
        if changed { WidgetCenter.shared.reloadTimelines(ofKind: WidgetShared.kind) }
    }

    private static func upToDate(_ name: String, _ thumb: String) -> Bool {
        guard let file = WidgetShared.photoFile(name), let source = WidgetShared.photoSourceFile(name) else { return true }
        return (try? String(contentsOf: source, encoding: .utf8)) == thumb && FileManager.default.fileExists(atPath: file.path)
    }

    private static func savePhoto(_ img: UIImage, name: String, thumb: String) async -> Bool {
        guard let file = WidgetShared.photoFile(name), let source = WidgetShared.photoSourceFile(name) else { return false }
        let box = CGSize(width: 500, height: 500)   // plenty for the largest small widget at 3x
        let small = await Lanczos.shrink(img, toPoints: Lanczos.fill(img.size, covering: box), scale: 1)
        guard let jpeg = small.jpegData(compressionQuality: 0.9) else { return false }
        try? jpeg.write(to: file, options: .atomic)
        try? thumb.write(to: source, atomically: true, encoding: .utf8)
        return true
    }

    private static func configuredFriends() async -> [String] {
        let infos = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        return Array(Set(infos.compactMap { $0.widgetConfigurationIntent(of: ChatWidgetIntent.self)?.friend?.id }))
    }

    /// Their avatar as of their newest stored message (every message carries the sender's `thumb`).
    private static func newestThumb(of name: String) -> String? {
        let msgs = Store.current?.messages(chat: name, limit: 50) ?? []
        return msgs.filter { ($0["hunter"] as? String) == name }
            .max { Int("\($0["id"] ?? 0)") ?? 0 < Int("\($1["id"] ?? 0)") ?? 0 }?["thumb"] as? String
    }
}
