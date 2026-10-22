import Foundation
import WebKit

// Mirrors the website's localStorage.self: the whole login `details` object,
// whose `auth` field is the only credential.
@MainActor final class Session: ObservableObject {
    @Published var auth: String?
    @Published var username: String = ""

    init() { load() }

    private func apply(_ d: [String: Any]) {
        auth = d["auth"] as? String
        username = (d["username"] as? String) ?? ""
    }

    func load() {
        if let s = UserDefaults.standard.string(forKey: "self"),
           let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
            apply(d)
        }
    }

    // `selfJSON` is exactly what `localStorage.getItem("self")` returns in the web app.
    func signIn(selfJSON: String) {
        UserDefaults.standard.set(selfJSON, forKey: "self")
        if let d = try? JSONSerialization.jsonObject(with: Data(selfJSON.utf8)) as? [String: Any] { apply(d) }
        if let auth { SocketManager.shared.start(auth: auth) }
    }

    // Invalidate the token server-side (reference logout -> auth/logout), then wipe the
    // WKWebView's localStorage/cookies before showing LoginView again; otherwise the
    // login page finds the old localStorage.self and signs straight back in.
    func signOut() async {
        SocketManager.shared.stop()
        Whatsup.shared.reset()
        if let auth { _ = await API.post("auth/logout", [:], auth: auth, username: username) }
        UserDefaults.standard.removeObject(forKey: "self")
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        auth = nil; username = ""
    }
}
