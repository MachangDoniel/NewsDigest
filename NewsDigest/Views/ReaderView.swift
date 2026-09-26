import SwiftUI
@preconcurrency import WebKit

/// Owns the WKWebView so SwiftUI toolbars and the capture code can reach it.
@MainActor
final class WebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    /// Sign-in popups (window.open), e.g. "Sign in with Google".
    @Published var popup: WKWebView?
    private var observers: [NSKeyValueObservation] = []

    static let configuration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // persistent: logins survive relaunches
        config.applicationNameForUserAgent = "Version/17.0 Mobile/15E148 Safari/604.1"
        // Pages (ads especially) may not open windows by themselves; only after a user tap.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        return config
    }()

    override init() {
        webView = WKWebView(frame: .zero, configuration: Self.configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observers = [
            webView.observe(\.estimatedProgress) { [weak self] w, _ in Task { @MainActor in self?.progress = w.estimatedProgress } },
            webView.observe(\.isLoading) { [weak self] w, _ in Task { @MainActor in self?.isLoading = w.isLoading } },
            webView.observe(\.canGoBack) { [weak self] w, _ in Task { @MainActor in self?.canGoBack = w.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] w, _ in Task { @MainActor in self?.canGoForward = w.canGoForward } },
        ]
    }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, ["tel", "mailto", "sms"].contains(url.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// Only sign-in pages may open as a pop-up sheet. Ads opening windows were knocking the
    /// ✨ Summarize sheet off screen; other links open in the same page instead.
    private static let signInHosts = ["accounts.google.com", "facebook.com", "appleid.apple.com", "auth.prothomalo.com", "profile.thedailystar.net"]

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let host = navigationAction.request.url?.host?.lowercased() ?? ""
        let isSignIn = Self.signInHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        guard isSignIn, navigationAction.navigationType == .linkActivated || navigationAction.navigationType == .other else {
            // Not a sign-in window: open user-tapped links in place; drop everything else (ads).
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
               Paper.allCases.contains(where: { p in p.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }) {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
        // Must use the passed-in configuration so the popup can talk back to its opener.
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        self.popup = popup
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView == popup { popup = nil }
    }
}

struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ReaderView: View {
    let paper: Paper
    let date: Date
    var pageId: String? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var web = WebController()
    @State private var summary: PageCapture.Captured?
    @State private var capturing = false
    @State private var error: String?
    @State private var shareItems: ShareItems?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                WebViewHost(webView: web.webView)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .top) {
                        if web.isLoading {
                            ProgressView(value: web.progress).tint(paper.color).progressViewStyle(.linear)
                        }
                    }

                summarizeButton
            }
            .navigationTitle(paper.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { web.webView.goBack() } label: { Image(systemName: "chevron.backward") }.disabled(!web.canGoBack)
                    Button { web.webView.goForward() } label: { Image(systemName: "chevron.forward") }.disabled(!web.canGoForward)
                    Menu {
                        Button { web.webView.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        Button { web.load(paper.editionURL(for: date)) } label: { Label("Go to edition", systemImage: "newspaper") }
                        Divider()
                        Button { Task { await shareToAI() } } label: { Label("Send page to ChatGPT / Gemini", systemImage: "square.and.arrow.up") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .onAppear { if web.webView.url == nil { web.load(paper.editionURL(for: date, pageId: pageId)) } }
            .sheet(item: $summary) { PageSummaryView(paper: paper, capture: $0) }
            .sheet(item: $shareItems) { ActivityView(items: $0.items) }
            .sheet(isPresented: Binding(get: { web.popup != nil }, set: { if !$0 { web.popup = nil } })) {
                if let popup = web.popup {
                    NavigationStack {
                        WebViewHost(webView: popup)
                            .ignoresSafeArea(edges: .bottom)
                            .navigationTitle("Sign in")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { Button("Close") { web.popup = nil } }
                    }
                }
            }
            .alert("Couldn't capture page", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private var summarizeButton: some View {
        Button {
            Task { await capture() }
        } label: {
            HStack(spacing: 8) {
                if capturing { ProgressView().tint(.white) } else { Image(systemName: "sparkles") }
                Text("Summarize").fontWeight(.semibold)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .foregroundStyle(.white)
            .background(paper.color.gradient, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
        .disabled(capturing)
        .padding(20)
    }

    private func capture() async {
        NSLog("DBG reader capture tapped")
        capturing = true
        defer { capturing = false }
        do { summary = try await PageCapture.capture(web.webView) } catch { self.error = error.localizedDescription }
    }

    private func shareToAI() async {
        do {
            let page = try await PageCapture.capture(web.webView)
            let prompt = Prompts.share(paper: paper)
            UIPasteboard.general.string = prompt
            var items: [Any] = [prompt]
            if let image = page.image { items.insert(image, at: 0) }
            shareItems = ShareItems(items: items)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension PageCapture.Captured: Identifiable {
    var id: Int { data.hashValue }
}

struct ShareItems: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
