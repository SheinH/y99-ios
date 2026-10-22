import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks

// Local notifications (real pushes come via Y99 Alerts, see PushRelay): one per socket DM while the app is
// running, plus a periodic background refresh that checks the conversation list.
// Each shows the sender's username, the message, and their avatar thumbnail.
@MainActor final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    nonisolated static let refreshTask = "com.sanhtike.y99mvp.refresh"

    @Published var openChat: String?   // set when a notification is tapped; FriendsView pushes it
    var activeChat: String?            // chat on screen; its messages don't notify

    func setUp() {
        UNUserNotificationCenter.current().delegate = self
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    // Socket cmd:"message" payloads are message objects: {id, hunter, message, type, thumb, ...}.
    func notify(message o: [String: Any], me: String) {
        guard let from = o["hunter"] as? String, from != me else { return }
        if from == activeChat && UIApplication.shared.applicationState == .active { return }
        let type = o["type"] as? String
        let aid = o["attachmentId"] as? String ?? ""
        let body = type == "image" ? "Photo"
            : type == "attachment" ? (Attachments.isVideo(aid) ? "Video" : Attachments.isImage(aid) ? "Photo" : "Attachment")
            : (o["message"] as? String ?? "")
        let id = "msg-\(o["id"] ?? UUID().uuidString)"
        Task { await Self.post(from: from, body: body, thumb: o["thumb"] as? String, id: id) }
    }

    // The avatar goes in as an attachment (thumbnail on the right). Showing it in place of the app icon
    // needs Communication Notifications, which free (personal) teams can't sign: Xcode refuses with
    // "Personal development teams ... do not support the Communication Notifications capability".
    nonisolated static func post(from: String, body: String, thumb: String?, id: String) async {
        let content = UNMutableNotificationContent()
        content.title = from
        content.body = body
        content.sound = .default
        content.threadIdentifier = from
        content.userInfo = ["hunter": from]
        if let thumb, let avatar = await avatarAttachment(thumb) { content.attachments = [avatar] }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // Attachments must be local files with a real image extension; the image comes from the shared avatar cache.
    private nonisolated static func avatarAttachment(_ thumb: String) async -> UNNotificationAttachment? {
        guard let data = await Avatar.thumbData(thumb) else { return nil }
        let ext = Avatar.url(thumb)?.pathExtension ?? ""
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "jpg" : ext)
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "avatar", url: file)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let from = notification.request.content.userInfo["hunter"] as? String
        let onScreen = await MainActor.run { from == activeChat }
        return onScreen ? [] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let from = response.notification.request.content.userInfo["hunter"] as? String else { return }
        await MainActor.run { openChat = from }
    }
}

// MARK: - Background refresh

extension Notifier {
    private nonisolated static let lastKey = "lastNotifiedTime"

    // iOS decides when this actually runs (often well after the earliest date).
    nonisolated static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTask)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    // Called when the app goes to the background, so the next check only reports newer messages.
    nonisolated static func markCaughtUp() {
        let now = Date().timeIntervalSince1970
        if now > UserDefaults.standard.double(forKey: lastKey) { UserDefaults.standard.set(now, forKey: lastKey) }
    }

    // whatsup panel=messages -> messages: [{hunter, message, time, seen, thumb, roomId?}, ...].
    // Notify DMs (rooms carry roomId) that are unseen and newer than the last check.
    nonisolated static func checkInBackground() async {
        guard !PushRelay.isSetUp else { return }   // Y99 Alerts delivers these as real pushes
        guard let s = UserDefaults.standard.string(forKey: "self"),
              let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              let auth = d["auth"] as? String else { return }
        let me = d["username"] as? String ?? ""
        // Through the shared builder so it carries gnt/hashes like every other whatsup.
        let r = await Whatsup.shared.pollOnce(focused: false, extra: ["panel": "messages"], auth: auth, username: me)
        // Full list (`messages`) when the hash changed, or just the changed entries (`new_messages`)
        // since our `new_messages_t` (processMessageNodes takes either, deob/modules/H45J.js).
        let list = (r?["messages"] as? [[String: Any]] ?? []) + (r?["new_messages"] as? [[String: Any]] ?? [])
        guard !list.isEmpty else { return }
        let last = UserDefaults.standard.double(forKey: lastKey)
        var newest = last
        for c in list where c["roomId"] == nil && "\(c["seen"] ?? "1")" == "0" {
            guard let from = c["hunter"] as? String, let t = Double("\(c["time"] ?? "")"), t > last else { continue }
            newest = max(newest, t)
            await post(from: from, body: c["message"] as? String ?? "", thumb: c["thumb"] as? String,
                       id: "bg-\(from)-\(Int(t))")
        }
        UserDefaults.standard.set(newest, forKey: lastKey)
    }
}
