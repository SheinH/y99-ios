import WidgetKit
import SwiftUI

// Home Screen widget for one friend: their profile picture filling the widget, their name, and a message
// bubble in a glass circle; tapping opens the chat (y99://chat/<name>).

@main
struct Y99Widgets: WidgetBundle {
    var body: some Widget { ChatWidget() }
}

struct ChatWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetShared.kind, intent: ChatWidgetIntent.self, provider: Provider()) {
            ChatWidgetView(entry: $0)
        }
        .configurationDisplayName("Chat")
        .description("Message a friend in one tap.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct ChatEntry: TimelineEntry {
    let date = Date()
    let name: String?
    let photo: UIImage?
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ChatEntry { ChatEntry(name: "Friend", photo: nil) }

    func snapshot(for configuration: ChatWidgetIntent, in context: Context) async -> ChatEntry {
        await entry(configuration)
    }

    func timeline(for configuration: ChatWidgetIntent, in context: Context) async -> Timeline<ChatEntry> {
        // The app reloads the widget when it saves a better picture; nothing changes on its own.
        Timeline(entries: [await entry(configuration)], policy: .never)
    }

    private func entry(_ configuration: ChatWidgetIntent) async -> ChatEntry {
        guard let name = configuration.friend?.id else { return ChatEntry(name: nil, photo: nil) }
        return ChatEntry(name: name, photo: await photo(name))
    }

    /// The app's high-res picture, else the thumb (fetched here once if the app hasn't saved anything).
    private func photo(_ name: String) async -> UIImage? {
        for file in [WidgetShared.photoFile(name), WidgetShared.thumbFile(name)] {
            if let file, let data = try? Data(contentsOf: file), let img = UIImage(data: data) { return img }
        }
        guard let raw = WidgetShared.people().first(where: { $0.name == name })?.thumbURL,
              let url = URL(string: raw), let file = WidgetShared.thumbFile(name) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("https://meetyou.me/", forHTTPHeaderField: "Referer")   // the image host 403s without it
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: data) else { return nil }
        try? data.write(to: file, options: .atomic)
        return img
    }
}

struct ChatWidgetView: View {
    let entry: ChatEntry

    var body: some View {
        Group {
            if let name = entry.name {
                ZStack(alignment: .bottomLeading) {
                    Color.clear
                    Text(name)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .padding(14)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .glassCircle()
                        .padding(10)
                        .accessibilityHidden(true)
                }
                .widgetURL(WidgetShared.chatURL(name))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Message \(name)")
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "message.fill").font(.title2)
                    Text("Hold, then Edit Widget to pick a friend")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding()
            }
        }
        .containerBackground(for: .widget) { background }
    }

    @ViewBuilder var background: some View {
        if entry.name == nil {
            Color(.secondarySystemBackground)
        } else {
            ZStack {
                if let photo = entry.photo {
                    Image(uiImage: photo)
                        .resizable()
                        .widgetAccentedRenderingMode(.accentedDesaturated)   // tinted Home Screen: keep it a photo
                        .scaledToFill()
                } else {
                    // No picture yet: the app's purple with their initial.
                    LinearGradient(colors: [Color(red: 0.83, green: 0.28, blue: 0.68), Color(red: 0.45, green: 0.16, blue: 0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(entry.name?.prefix(1).uppercased() ?? "")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
                // Keeps the name readable on any picture.
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            }
        }
    }
}

private extension View {
    @ViewBuilder func glassCircle() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: Circle())
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
    }
}
