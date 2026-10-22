import SwiftUI

struct Friend: Identifiable {
    let username: String
    let status: Int   // 1 online, 2 recently online, 3 offline (inferred from responses)
    var id: String { username }

    var statusText: String {
        switch status {
        case 1: "Online"
        case 2: "Recently online"
        default: "Offline"
        }
    }

    var statusColor: Color {
        switch status {
        case 1: .green
        case 2: .orange
        default: Color(.systemGray3)
        }
    }
}

struct FriendsView: View {
    @EnvironmentObject var session: Session
    @State private var friends: [Friend] = []
    @State private var path: [String] = []
    @State private var favorites: Set<String> = []
    @ObservedObject private var notifier = Notifier.shared
    @ObservedObject private var connectivity = Connectivity.shared   // the toolbar's status badge

    var body: some View {
        NavigationStack(path: $path) {
            // Favorites (kept on this phone, per account) on top whatever their status, everyone else below.
            List {
                let favs = friends.filter { favorites.contains($0.username) }
                let others = friends.filter { !favorites.contains($0.username) }
                if !favs.isEmpty {
                    Section { ForEach(favs) { row($0) } } header: { header("Favorites", "star.fill") }
                    Section { ForEach(others) { row($0) } } header: { header("Others", "person.2.fill") }
                } else {
                    ForEach(others) { row($0) }
                }
            }
            .navigationTitle("Friends")   // still names the screen (back button, accessibility)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .navigationDestination(for: String.self) { ChatView(friend: $0) }
            // Tapped notification: open that person's chat.
            .onChange(of: notifier.openChat, initial: true) {
                guard let who = notifier.openChat else { return }
                notifier.openChat = nil
                path = [who]
            }
            .toolbar {
                // The title shares the toolbar's row with the buttons (a large title gets a row of its own).
                if #available(iOS 26, *) {
                    ToolbarItem(placement: .topBarLeading) { title }.sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) { title }
                }
                // Until notifications are set up, a visible nudge; afterwards it lives in the account menu.
                if !PushRelay.isSetUp {
                    ToolbarItem(placement: .topBarTrailing) {
                        Link(destination: PushRelay.setupURL) { Image(systemName: "bell.badge") }
                            .accessibilityLabel("Set Up Notifications")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { ConnectionBadge() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section(session.username) {
                            // Opens the Y99 Alerts web app, which (re)connects push notifications.
                            Link(destination: PushRelay.setupURL) {
                                Label(PushRelay.isSetUp ? "Reconnect Notifications" : "Set Up Notifications", systemImage: "bell")
                            }
                            Button(role: .destructive) { Task { await session.signOut() } } label: {
                                Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Account")
                }
            }
            .onAppear { favorites = Store.current?.favorites() ?? [] }
            .refreshable { await load() }
            .task { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .y99CaptchaDone)) { _ in
                Task { await load() }
            }
        }
    }

    var title: some View {
        Text("Friends").font(.largeTitle.bold()).fixedSize().accessibilityAddTraits(.isHeader)
    }

    func header(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title)
        }
    }

    // user/friends -> {friends: [{username, status, ...}]} or {friends: 203} when empty (deob/modules/bKls.js setUserData)
    // Tap opens the chat, long press toggles the favorite. Both are handled on the row itself (not a
    // NavigationLink plus an extra gesture, where the list's own touch handling won only some of the time).
    func row(_ friend: Friend) -> some View {
        HStack(spacing: 12) {
            Circle().fill(friend.statusColor).frame(width: 10, height: 10)
            Text(friend.username)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { path = [friend.username] }
        .onLongPressGesture(minimumDuration: 0.4) { toggleFavorite(friend.username) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(friend.statusText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { path = [friend.username] }
        .accessibilityAction(named: favorites.contains(friend.username) ? "Remove from Favorites" : "Add to Favorites") {
            toggleFavorite(friend.username)
        }
    }

    func toggleFavorite(_ name: String) {
        Store.current?.setFavorite(name, !favorites.contains(name))
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation { favorites = Store.current?.favorites() ?? [] }
    }

    // Shows the stored list right away (works offline), then refreshes from the server.
    func load() async {
        if friends.isEmpty, let stored = Store.current?.friends(), !stored.isEmpty {
            friends = stored.map { Friend(username: $0.username, status: $0.status) }
        }
        let r = await API.post("user/friends", [:], auth: session.auth, username: session.username)
        // Anything without a `friends` key (e.g. a captcha challenge) leaves the current list alone.
        guard let value = (r as? [String: Any])?["friends"] else { return }
        if let arr = value as? [[String: Any]] {
            friends = arr.compactMap { o in
                guard let name = o["username"] as? String else { return nil }
                let status = (o["status"] as? Int) ?? Int(o["status"] as? String ?? "") ?? 3
                return Friend(username: name, status: status)
            }
        } else {
            friends = []
        }
        Store.current?.saveFriends(friends.map { ($0.username, $0.status) })
    }
}
