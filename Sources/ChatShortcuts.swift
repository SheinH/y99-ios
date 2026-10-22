import AppIntents

// "Open Chat with <friend>" for the Shortcuts app, Spotlight and Siri. For an app-icon-sized Home Screen
// shortcut: Shortcuts > + > Open Chat (Y99) > pick a friend > Share > Add to Home Screen, and choose their
// profile picture (saved from the photo viewer's share button) as the icon. Logged out, it opens the
// login screen and then the chat (FriendsView picks up Notifier.openChat once it appears).
// The friend picker is the widget's shared list (WidgetShared), so it works before the app has loaded.
struct OpenChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Opens your chat with a friend in Y99.")
    static let openAppWhenRun = true

    @Parameter(title: "Friend") var friend: FriendEntity

    static var parameterSummary: some ParameterSummary { Summary("Open chat with \(\.$friend)") }

    @MainActor func perform() async throws -> some IntentResult {
        Notifier.shared.openChat = friend.id
        return .result()
    }
}

struct Y99Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenChatIntent(),
                    phrases: ["Open chat with \(\.$friend) in \(.applicationName)",
                              "Message \(\.$friend) in \(.applicationName)"],
                    shortTitle: "Open Chat",
                    systemImageName: "message.fill")
    }
}
