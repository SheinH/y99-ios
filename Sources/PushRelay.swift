import Foundation

// Real push without a paid Apple account: the "Y99 Alerts" Home Screen web app (push-web/, hosted at
// Secrets.alertsURL) holds a Web Push subscription, which y99 already sends DM pushes to (API.md
// "Web push"). It hands the subscription here as y99://pushsub?d=<base64url JSON>, and this app registers
// it to the account under its own session, so the web app never logs in (y99 allows one login per account).
// y99 can drop subscriptions without telling anyone, so it's re-sent once a day when the app opens.
enum PushRelay {
    static let setupURL = URL(string: Secrets.alertsURL)!
    private static let subKey = "pushSub", lastKey = "pushSubRegistered"

    static var isSetUp: Bool { UserDefaults.standard.string(forKey: subKey) != nil }

    /// Stores the subscription from a y99://pushsub link. Returns false if the link is malformed.
    static func save(from url: URL) -> Bool {
        guard var d = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "d" })?.value else { return false }
        d = d.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        d += String(repeating: "=", count: (4 - d.count % 4) % 4)
        guard let data = Data(base64Encoded: d), let json = String(data: data, encoding: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["endpoint"] is String else { return false }
        UserDefaults.standard.set(json, forKey: subKey)
        UserDefaults.standard.removeObject(forKey: lastKey)
        return true
    }

    /// Links the subscription to the account (user/push_sub, deob/app.deob.js ~22397). The other half,
    /// y99's notification service (push_subscription.php), is told by the web app from the browser: when
    /// this app sent it, y99 stored a record it never pushed to. Also turns on the account's notifications
    /// switch (`pref_alert`), without which y99 sends nothing.
    static func register(auth: String, username: String) async {
        guard let sub = UserDefaults.standard.string(forKey: subKey) else { return }
        let last = UserDefaults.standard.double(forKey: lastKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        _ = await API.post("user/push_sub", ["push_sub": sub, "site": "meetyou.me"], auth: auth, username: username)
        if last == 0 {   // first time for this subscription
            _ = await API.post("user/profile/pref_alert", ["pref_alert": "1"], auth: auth, username: username)
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
    }
}
