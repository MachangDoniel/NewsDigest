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

    /// The specific page the user asked for. If the site detours through its login page
    /// (Daily Star does, then lands on page 1), we go back to this page afterwards.
    private var target: URL?

    func open(_ url: URL) {
        target = url
        load(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let target, let current = webView.url else { return }
        let page = URLComponents(url: target, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "pgid" }?.value
        guard let page else { self.target = nil; return }
        if current.absoluteString.contains("pgid=\(page)") {
            self.target = nil  // arrived
        } else if current.host == target.host, !current.path.lowercased().contains("login") {
            // Back on the reader after signing in, but on the wrong page.
            self.target = nil
            load(target)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, ["tel", "mailto", "sms"].contains(url.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// Only sign-in pages open as a pop-up sheet; the paper's own windows open in place.
    /// Ads opening windows from other sites were knocking the summary sheet off screen,
    /// so those are dropped.
    private static let signInHosts = ["accounts.google.com", "facebook.com", "appleid.apple.com", "auth.prothomalo.com", "profile.thedailystar.net"]

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let host = navigationAction.request.url?.host?.lowercased() ?? ""
        let matches = { (h: String) in host == h || host.hasSuffix("." + h) }
        let isSignIn = Self.signInHosts.contains(where: matches)
        let isPaper = Paper.allCases.contains { $0.hosts.contains(where: matches) }
        // The paper's own windows (an article opened from a story box) open right here, like a
        // normal link; the ◀ button returns to the page. Daily Star's article window closes
        // itself when opened as a separate window.
        if isPaper, !isSignIn {
            webView.load(navigationAction.request)
            return nil
        }
        guard isSignIn else { return nil }
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
    @State private var aiSheet: AIChatSheet?
    @StateObject private var speech = SpeechReader()
    @State private var listenLoading = false
    @State private var listenExpanded = false

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

                bottomBar
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
                        Button { Task { await shareToAI() } } label: { Label("Share page…", systemImage: "square.and.arrow.up") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .onAppear { if web.webView.url == nil { web.open(paper.editionURL(for: date, pageId: pageId)) } }
            .onDisappear { speech.stop() }
            .sheet(item: $summary) { PageSummaryView(paper: paper, capture: $0) }
            .sheet(item: $shareItems) { ActivityView(items: $0.items) }
            .sheet(item: $aiSheet) { AIChatSheetView(sheet: $0) }
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
            .alert("Couldn't use this page", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    /// Read aloud on the left, Ask on the right. The open read-aloud panel takes the full width.
    private var bottomBar: some View {
        HStack(alignment: .bottom) {
            ListenControls(reader: speech, tint: paper.color, loading: listenLoading, onStart: { Task { await listen() } }, expanded: $listenExpanded)
            if !listenExpanded {
                Spacer()
                summarizeButton
            }
        }
        .padding(20)
    }

    /// Reads the stories on the page (or the open article) aloud.
    private func listen() async {
        listenLoading = true
        defer { listenLoading = false }
        do {
            let page = try await PageCapture.capture(web.webView)
            guard !page.stories.isEmpty else {
                error = "There's no text on this page to read. Open a page with articles, or tap a story to open it."
                return
            }
            speech.start(page.stories, title: [paper.name, page.pageName].compactMap { $0 }.joined(separator: " · "))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// "Ask" menu: the in-app BCS summary, or open ChatGPT / Gemini / Claude / … with this page's text.
    private var summarizeButton: some View {
        AskAIMenu(
            onSummarize: { Task { await capture() } },
            onPick: { app in Task { await ask(app) } }
        ) {
            HStack(spacing: 8) {
                if capturing { ProgressView().tint(.white) } else { Image(systemName: "sparkles") }
                Text("Ask").fontWeight(.semibold)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .foregroundStyle(.white)
            .background(paper.color.gradient, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
        .disabled(capturing)
    }

    /// Opens an AI app with the page's article text (or copies the page image when there's no text).
    private func ask(_ app: AIApp) async {
        capturing = true
        defer { capturing = false }
        do {
            let page = try await PageCapture.capture(web.webView)
            let sheet = app.open(AskPrompts.page(page, paper: paper))
            // No text: put the page image on the clipboard to paste into the chat.
            if page.stories.isEmpty, let image = page.image { UIPasteboard.general.image = image }
            aiSheet = sheet
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func capture() async {
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
