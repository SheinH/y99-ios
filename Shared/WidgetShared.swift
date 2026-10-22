import Foundation
import AppIntents

// Shared by the app and the widget extension through the App Group container. The app writes the friends
// list (favorites first) and, for friends that have a widget, their high-res profile picture; the widget
// only reads, except that it fetches a friend's small thumb itself when the app hasn't saved a picture yet.

enum WidgetShared {
    static let group = "group.com.sanhtike.y99mvp"
    static let kind = "ChatWidget"

    struct Person: Codable {
        let name: String
        var thumbURL: String?   // absolute; the widget's fallback picture
        var thumb: String?      // the app's avatar key; a new one means a new picture
    }

    static var dir: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("widget")
    }

    private static var listFile: URL? { dir?.appendingPathComponent("friends.json") }

    static func people() -> [Person] {
        guard let file = listFile, let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Person].self, from: data)) ?? []
    }

    static func save(_ people: [Person]) {
        guard let dir, let file = listFile, let data = try? JSONEncoder().encode(people) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static func safe(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
    }

    /// High-res picture saved by the app.
    static func photoFile(_ name: String) -> URL? { dir?.appendingPathComponent("photo-\(safe(name)).jpg") }
    /// Which avatar `photoFile` was made from.
    static func photoSourceFile(_ name: String) -> URL? { dir?.appendingPathComponent("photo-\(safe(name)).source") }
    /// Small fallback fetched by the widget.
    static func thumbFile(_ name: String) -> URL? { dir?.appendingPathComponent("thumb-\(safe(name)).jpg") }

    static func chatURL(_ name: String) -> URL? {
        URL(string: "y99://chat/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name))
    }
}

struct FriendEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Friend"
    static let defaultQuery = FriendQuery()
    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct FriendQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [FriendEntity] { identifiers.map(FriendEntity.init) }
    func suggestedEntities() async throws -> [FriendEntity] { WidgetShared.people().map { FriendEntity(id: $0.name) } }
    func entities(matching string: String) async throws -> [FriendEntity] {
        WidgetShared.people().map(\.name).filter { $0.localizedCaseInsensitiveContains(string) }.map(FriendEntity.init)
    }
}

struct ChatWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Chat"
    static let description = IntentDescription("Opens your chat with a friend.")
    @Parameter(title: "Friend") var friend: FriendEntity?
}
