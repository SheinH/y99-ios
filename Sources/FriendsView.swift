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
    @ObservedObject private var notifier = Notifier.shared

    var body: some View {
        NavigationStack(path: $path) {
            List(friends) { friend in
                NavigationLink(value: friend.username) {
                    HStack(spacing: 12) {
                        Circle().fill(friend.statusColor).frame(width: 10, height: 10)
                        Text(friend.username)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(friend.statusText)
                }
            }
            .navigationTitle("Friends")
            .navigationDestination(for: String.self) { ChatView(friend: $0) }
            // Tapped notification: open that person's chat.
            .onChange(of: notifier.openChat, initial: true) {
                guard let who = notifier.openChat else { return }
                notifier.openChat = nil
                path = [who]
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Link(destination: PushRelay.setupURL) {
                        Image(systemName: PushRelay.isSetUp ? "bell.fill" : "bell")
                    }
                    .accessibilityLabel("Set up notifications")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log out") { Task { await session.signOut() } }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .y99CaptchaDone)) { _ in
                Task { await load() }
            }
        }
    }

    // user/friends -> {friends: [{username, status, ...}]} or {friends: 203} when empty (deob/modules/bKls.js setUserData)
    func load() async {
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
    }
}
