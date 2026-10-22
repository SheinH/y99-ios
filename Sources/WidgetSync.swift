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
        for name in await configuredFriends() {
            guard let thumb = people.first(where: { $0.name == name })?.thumb,
                  let file = WidgetShared.photoFile(name), let source = WidgetShared.photoSourceFile(name) else { continue }
            if (try? String(contentsOf: source, encoding: .utf8)) == thumb, FileManager.default.fileExists(atPath: file.path) { continue }
            let hadFull = await Avatar.cachedFull(thumb) != nil
            guard let img = await Avatar.full(user: name, thumb: thumb, auth: auth, me: me) else { continue }
            let box = CGSize(width: 500, height: 500)   // plenty for the largest small widget at 3x
            let small = await Lanczos.shrink(img, toPoints: Lanczos.fill(img.size, covering: box), scale: 1)
            guard let jpeg = small.jpegData(compressionQuality: 0.9) else { continue }
            try? jpeg.write(to: file, options: .atomic)
            try? thumb.write(to: source, atomically: true, encoding: .utf8)
            changed = true
            if !hadFull { try? await Task.sleep(for: .seconds(1)) }   // space out profile requests
        }
        if changed { WidgetCenter.shared.reloadTimelines(ofKind: WidgetShared.kind) }
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
