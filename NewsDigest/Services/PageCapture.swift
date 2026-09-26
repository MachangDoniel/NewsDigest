import UIKit
@preconcurrency import WebKit

/// Grabs the e-paper page the user is looking at.
/// 1. Find the most visible page <img> and download its highest-resolution URL with the WebView's login cookies.
/// 2. Otherwise, snapshot the visible WebView.
enum PageCapture {
    struct Captured {
        let data: Data
        let mime: String
        var image: UIImage? { UIImage(data: data) }
    }

    private static let findImageJS = """
    (() => {
      const vh = window.innerHeight, vw = window.innerWidth;
      let best = null, bestArea = 0;
      for (const img of document.images) {
        const r = img.getBoundingClientRect();
        const w = Math.max(0, Math.min(r.right, vw) - Math.max(r.left, 0));
        const h = Math.max(0, Math.min(r.bottom, vh) - Math.max(r.top, 0));
        const area = w * h;
        if (area > bestArea && img.naturalWidth > 400) { bestArea = area; best = img; }
      }
      if (!best) return null;
      const urls = ['xhighres', 'highres', 'data-src'].map(a => best.getAttribute(a)).concat([best.currentSrc || best.src]);
      return urls.find(u => u && /^https?:/.test(u)) || null;
    })()
    """

    @MainActor
    static func capture(_ webView: WKWebView) async throws -> Captured {
        if let urlString = try? await webView.evaluateJavaScript(findImageJS) as? String,
           let url = URL(string: urlString),
           let captured = await download(url, webView: webView) {
            return captured
        }
        return try await snapshot(webView)
    }

    @MainActor
    private static func download(_ url: URL, webView: WKWebView) async -> Captured? {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        var req = URLRequest(url: url)
        req.setValue(webView.url?.absoluteString, forHTTPHeaderField: "Referer")
        let header = HTTPCookie.requestHeaderFields(with: cookies.filter { cookie in
            let host = url.host ?? ""
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        })
        header.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let type = http.value(forHTTPHeaderField: "Content-Type"), type.hasPrefix("image/"),
              data.count > 20_000 else { return nil }
        return Captured(data: data, mime: String(type.split(separator: ";")[0]))
    }

    @MainActor
    private static func snapshot(_ webView: WKWebView) async throws -> Captured {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(webView.bounds.width * 2))
        let image = try await webView.takeSnapshot(configuration: config)
        guard let data = image.jpegData(compressionQuality: 0.85) else { throw CaptureError.failed }
        return Captured(data: data, mime: "image/jpeg")
    }

    enum CaptureError: LocalizedError {
        case failed
        var errorDescription: String? { "Couldn't capture this page." }
    }
}
