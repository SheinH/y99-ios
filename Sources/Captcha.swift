import SwiftUI
import WebKit

extension Notification.Name { static let y99CaptchaDone = Notification.Name("y99CaptchaDone") }

// Any API response may carry {miniIframe: {url}}: the server withholds data until a Cloudflare
// Turnstile page is solved. The web app shows it in a persistent dialog and hides it once a
// response arrives without miniIframe (deob/modules/WSTi.js handleGlobalResponse, qDTB.js).
@MainActor final class Captcha: ObservableObject {
    static let shared = Captcha()
    @Published var url: URL?

    nonisolated static func handle(_ response: Any?) {
        guard let dict = response as? [String: Any] else { return }
        let s = (dict["miniIframe"] as? [String: Any])?["url"] as? String
        Task { @MainActor in
            // Keep the page already showing; a polling response must not reload it mid-solve.
            // Only assign on change: every assignment re-renders the whole app (it's an app-level StateObject).
            if let s { if shared.url == nil { shared.url = URL(string: s) } } else if shared.url != nil { shared.url = nil }
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct CaptchaSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CaptchaWeb(url: url) {
                // The page posts its form once solved; let screens refetch. If the server still
                // wants a captcha, the refetch brings this sheet straight back.
                dismiss()
                NotificationCenter.default.post(name: .y99CaptchaDone, object: nil)
            }
            .navigationTitle("Verify")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }
}

struct CaptchaWeb: UIViewRepresentable {
    let url: URL
    let onSubmitted: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSubmitted: onSubmitted) }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        var req = URLRequest(url: url)
        req.setValue("https://meetyou.me/", forHTTPHeaderField: "Referer") // it's normally an iframe on meetyou.me
        web.load(req)
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSubmitted: () -> Void
        private var loads = 0
        init(onSubmitted: @escaping () -> Void) { self.onSubmitted = onSubmitted }

        // First load is the captcha page; the next main-frame load is the form submission result.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loads += 1
            if loads == 2 { onSubmitted() }
        }
    }
}
