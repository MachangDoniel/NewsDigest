import SwiftUI
@preconcurrency import WebKit

/// Hosts of the site that should stay inside the in-app browser.
/// Anything else (Play Store, Facebook, YouTube, tel:/mailto:, ...) is
/// handed off to the system instead of navigating the WebView away from the app.
private let onSiteHosts: Set<String> = ["biddabari.com", "www.biddabari.com"]

private func isOnSite(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return onSiteHosts.contains(host) || onSiteHosts.contains { host.hasSuffix(".\($0)") }
}

struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var progress: Double
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        webView.addObserver(context.coordinator, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl
        context.coordinator.webView = webView
        context.coordinator.refreshControl = refreshControl

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.removeObserver(coordinator, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebView
        weak var webView: WKWebView?
        weak var refreshControl: UIRefreshControl?

        init(_ parent: WebView) {
            self.parent = parent
        }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            guard keyPath == #keyPath(WKWebView.estimatedProgress), let webView = object as? WKWebView else { return }
            DispatchQueue.main.async {
                self.parent.progress = webView.estimatedProgress
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.parent.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.parent.isLoading = false }
            refreshControl?.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.parent.isLoading = false }
            refreshControl?.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.parent.isLoading = false }
            refreshControl?.endRefreshing()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let scheme = url.scheme?.lowercased() ?? ""
            if ["tel", "mailto", "sms", "facetime"].contains(scheme) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame?.isMainFrame == true, ["http", "https"].contains(scheme), !isOnSite(url) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        /// Handles target="_blank" / window.open() calls.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            if isOnSite(url) {
                webView.load(navigationAction.request)
            } else {
                UIApplication.shared.open(url)
            }
            return nil
        }
    }
}
