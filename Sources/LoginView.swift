import SwiftUI
import WebKit

// Loads the real site in a WKWebView. The site does its own Cloudflare /
// fingerprint login; we just wait for localStorage.self to appear, then keep it.
struct LoginView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        WebLogin { json in session.signIn(selfJSON: json) }
            .ignoresSafeArea()
    }
}

struct WebLogin: UIViewRepresentable {
    let onSession: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSession: onSession) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: Self.skipGuestMode, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: URL(string: "https://meetyou.me/app/login")!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // The page opens in guest mode; "Already have an account?" toggles to the login form
    // (toggleGuestMode). It's a toggle and "Forgot login?" shares its class, so match the text
    // and click once. Polls because the Vue app renders it after load; gives up after ~20s.
    static let skipGuestMode = """
    (() => {
      let tries = 0;
      const t = setInterval(() => {
        const el = [...document.querySelectorAll('.login-instead')]
          .find(e => e.textContent.includes('Already have an account'));
        if (el) { el.click(); clearInterval(t); }
        else if (++tries > 100) clearInterval(t);
      }, 200);
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSession: (String) -> Void
        private var timer: Timer?
        private var done = false

        init(onSession: @escaping (String) -> Void) { self.onSession = onSession }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak webView] _ in
                webView?.evaluateJavaScript("window.localStorage.getItem('self')") { value, _ in
                    guard let self, !self.done,
                          let json = value as? String, json.contains("\"auth\"") else { return }
                    self.done = true
                    self.timer?.invalidate()
                    // Keep the web client's device id and browser identity so API calls look like the
                    // same client that just logged in (see API.deviceCookie / API.userAgent).
                    webView?.evaluateJavaScript("JSON.stringify([localStorage.getItem('cookie'), navigator.userAgent])") { v, _ in
                        if let s = v as? String, let a = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [Any] {
                            if let c = a.first as? String { UserDefaults.standard.set(c, forKey: API.deviceCookieKey) }
                            if let ua = a.last as? String { UserDefaults.standard.set(ua, forKey: API.userAgentKey) }
                        }
                        self.onSession(json)
                    }
                }
            }
        }
    }
}
