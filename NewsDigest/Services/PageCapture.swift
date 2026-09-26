import UIKit
@preconcurrency import WebKit

/// One article's real text from the e-paper reader.
struct PaperStory: Codable, Hashable {
    let headline: String
    let body: String
    let captions: [String]
}

/// Grabs the e-paper page the user is looking at:
/// - the article TEXT of that page (preferred; exact numbers and names), fetched through the
///   reader's own endpoints with the in-app login
/// - the page IMAGE as a fallback (most visible page image, else a WebView snapshot)
enum PageCapture {
    struct Captured {
        let data: Data
        let mime: String
        var stories: [PaperStory] = []
        var pageNo: Int?
        var pageName: String?
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

    /// Both e-papers run the same reader: getingRectangleObject lists a page's stories,
    /// ShowArticleView returns each story's headline, body and captions (same as the server).
    private static let storiesJS = """
    const vh = window.innerHeight, vw = window.innerWidth;
    let best = null, bestArea = 0;
    for (const e of document.querySelectorAll('img[pageid], img[page_id]')) {
      if (e.naturalWidth < 400) continue;
      const r = e.getBoundingClientRect();
      const a = Math.max(0, Math.min(r.right, vw) - Math.max(r.left, 0)) * Math.max(0, Math.min(r.bottom, vh) - Math.max(r.top, 0));
      if (a > bestArea) { bestArea = a; best = e; }
    }
    const pageId = (best && (best.getAttribute('pageid') || best.getAttribute('page_id'))) || new URLSearchParams(location.search).get('pgid');
    if (!pageId) return null;
    const pageNo = best && best.getAttribute('pageno');
    const pageName = best && best.getAttribute('pgname');
    const getJSON = (u) => fetch(u, { headers: { 'X-Requested-With': 'XMLHttpRequest' }, credentials: 'include' }).then(r => r.ok ? r.json() : null).catch(() => null);
    const rects = await getJSON('/Home/getingRectangleObject?pageid=' + pageId);
    if (!Array.isArray(rects)) return JSON.stringify({ pageNo, pageName, stories: [] });
    const orgIds = [...new Set(rects.filter(r => r.ObjectType === 2 && r.OrgId).map(r => r.OrgId))].slice(0, 25);
    const toText = (html) => {
      const doc = new DOMParser().parseFromString(String(html || '').replace(/<\\/p>|<br\\s*\\/?>/gi, '\\n'), 'text/html');
      return (doc.body.textContent || '').replace(/[ \\t]+/g, ' ').replace(/\\n\\s*\\n+/g, '\\n').trim();
    };
    const stories = [];
    for (const org of orgIds) {
      const a = await getJSON('/User/ShowArticleView?OrgId=' + org);
      if (!a) continue;
      const c = Array.isArray(a.StoryContent) ? a.StoryContent : [];
      const headline = toText(c.flatMap(x => x.Headlines || []).join(' '));
      const body = toText(c.map(x => x.Body || '').join('\\n'));
      const captions = (a.LinkPicture || []).map(p => String(p.caption || '').trim()).filter(Boolean);
      if (headline || body.length > 80) stories.push({ headline, body: body.slice(0, 6000), captions });
    }
    return JSON.stringify({ pageNo, pageName, stories });
    """

    @MainActor
    static func capture(_ webView: WKWebView) async throws -> Captured {
        var captured: Captured
        if let urlString = try? await webView.evaluateJavaScript(findImageJS) as? String,
           let url = URL(string: urlString),
           let image = await download(url, webView: webView) {
            captured = image
        } else {
            captured = try await snapshot(webView)
        }
        if let text = await pageText(webView) {
            captured.stories = text.stories
            captured.pageNo = text.pageNo.flatMap(Int.init)
            captured.pageName = text.pageName
        }
        return captured
    }

    private struct PageText: Decodable {
        let pageNo: String?
        let pageName: String?
        let stories: [PaperStory]
    }

    @MainActor
    private static func pageText(_ webView: WKWebView) async -> PageText? {
        guard let json = try? await webView.callAsyncJavaScript(storiesJS, contentWorld: .defaultClient) as? String,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PageText.self, from: data)
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
