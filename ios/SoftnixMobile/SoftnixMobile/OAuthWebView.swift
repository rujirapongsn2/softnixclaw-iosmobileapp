import SwiftUI
import WebKit

struct OAuthWebView: UIViewControllerRepresentable {
    let startURL: URL
    let baseURL: URL
    let onAuthenticated: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(baseURL: baseURL, onAuthenticated: onAuthenticated)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        let controller = UIViewController()
        controller.view = webView
        webView.load(URLRequest(url: startURL))
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let baseURL: URL
        private let onAuthenticated: () -> Void
        private var completed = false

        init(baseURL: URL, onAuthenticated: @escaping () -> Void) {
            self.baseURL = baseURL
            self.onAuthenticated = onAuthenticated
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard !completed,
                  let url = webView.url,
                  url.host == baseURL.host,
                  !url.path.contains("/auth/oauth/") else {
                return
            }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                for cookie in cookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                completed = true
                onAuthenticated()
            }
        }
    }
}
