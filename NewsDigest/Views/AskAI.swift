import SafariServices
import SwiftUI

/// AI chat apps the user can open with a question already written.
/// Most accept a `?q=` prompt link; the rest get the prompt on the clipboard to paste.
/// Runs on the user's own accounts in an in-app Safari sheet. No API keys.
enum AIApp: String, CaseIterable, Identifiable {
    case chatgpt, gemini, claude, grok, perplexity, copilot, deepseek

    var id: String { rawValue }

    /// Shown directly in menus; the rest go under "More".
    static let main: [AIApp] = [.chatgpt, .gemini, .claude, .grok]
    static let more: [AIApp] = [.perplexity, .copilot, .deepseek]

    var name: String {
        switch self {
        case .chatgpt: "ChatGPT"
        case .gemini: "Gemini"
        case .claude: "Claude"
        case .grok: "Grok"
        case .perplexity: "Perplexity"
        case .copilot: "Copilot"
        case .deepseek: "DeepSeek"
        }
    }

    var icon: String {
        switch self {
        case .chatgpt: "bubble.left.and.text.bubble.right"
        case .gemini: "sparkle"
        case .claude: "asterisk"
        case .grok: "bolt"
        case .perplexity: "magnifyingglass"
        case .copilot: "paperplane"
        case .deepseek: "water.waves"
        }
    }

    /// nil when the site can't take a pre-filled prompt (the prompt is copied instead).
    private var promptBase: String? {
        switch self {
        case .chatgpt: "https://chatgpt.com/"
        case .claude: "https://claude.ai/new"
        case .grok: "https://grok.com/"
        case .perplexity: "https://www.perplexity.ai/search"
        case .copilot: "https://copilot.microsoft.com/"
        case .gemini, .deepseek: nil
        }
    }

    private var homeURL: URL {
        switch self {
        case .gemini: URL(string: "https://gemini.google.com/app")!
        case .deepseek: URL(string: "https://chat.deepseek.com/")!
        default: URL(string: promptBase!)!
        }
    }

    var takesPrompt: Bool { promptBase != nil }

    /// Very long links get rejected, so the link carries a shortened prompt.
    /// The full prompt is always on the clipboard too.
    private static let maxLinkPrompt = 3000

    func open(_ prompt: String) -> AIChatSheet {
        UIPasteboard.general.string = prompt
        guard let base = promptBase, var c = URLComponents(string: base) else {
            return AIChatSheet(url: homeURL, app: self, note: "Question copied. Tap the message box and paste it.")
        }
        let short = prompt.count > Self.maxLinkPrompt
            ? String(prompt.prefix(Self.maxLinkPrompt)) + "\n…(the full text is on my clipboard)"
            : prompt
        c.queryItems = [URLQueryItem(name: "q", value: short)]
        return AIChatSheet(url: c.url ?? homeURL, app: self, note: nil)
    }
}

/// What the in-app Safari sheet should show.
struct AIChatSheet: Identifiable {
    let id = UUID()
    let url: URL
    let app: AIApp
    /// Shown briefly on top when the user needs to paste the prompt.
    let note: String?
}

enum AskPrompts {
    static func story(_ saved: SavedItem) -> String {
        let item = saved.item
        var parts = [
            "I'm preparing for the Bangladesh Civil Service (BCS) exam. Explain this news simply: the background, why it matters, and 3 likely exam questions with answers.",
            "",
            "Source: \(saved.paper.name), \(DigestDate.pretty(saved.date))",
            "Headline: \(item.sourceHeadline ?? item.headline)",
        ]
        if !item.keyFacts.isEmpty { parts.append("Key facts: " + item.keyFacts.joined(separator: "; ")) }
        if let excerpt = item.excerpt, !excerpt.isEmpty { parts.append("From the paper: " + excerpt) }
        else { parts.append("Summary: " + item.bullets.joined(separator: " ")) }
        if saved.paper == .prothomalo { parts += ["", "Please answer in Bangla."] }
        return parts.joined(separator: "\n")
    }

    static func mcq(_ mcq: Mcq, paper: Paper?) -> String {
        var parts = [
            "I'm preparing for the BCS exam. Explain why the answer to this MCQ is correct, why the other options are wrong, and give the background I should remember.",
            "",
            "Q: \(mcq.question)",
            "Options: " + mcq.options.enumerated().map { "\(["A", "B", "C", "D"][min($0.offset, 3)]). \($0.element)" }.joined(separator: "  "),
            "Answer: \(mcq.answer)",
        ]
        if paper == .prothomalo { parts += ["", "Please answer in Bangla."] }
        return parts.joined(separator: "\n")
    }

    /// A whole e-paper page: its article text, story by story.
    static func page(_ capture: PageCapture.Captured, paper: Paper) -> String {
        var parts = [
            "I'm preparing for the Bangladesh Civil Service (BCS) exam. Below is the text of \(capture.pageNo.map { "page \($0)" } ?? "a page") of today's \(paper.name).",
            "Pick out only the BCS-relevant news. For each: 2–3 bullets and the exact key facts (names, numbers, dates). Then write 3 MCQs with answers.",
        ]
        if paper == .prothomalo { parts.append("Please answer in Bangla.") }
        if capture.stories.isEmpty {
            parts.append("(I couldn't get the page text; the page image is on my clipboard, so I'll paste it.)")
        } else {
            for s in capture.stories {
                let body = s.body.count > 1200 ? String(s.body.prefix(1200)) + " …" : s.body
                parts.append("\n## \(s.headline)\n\(body)")
            }
        }
        return parts.joined(separator: "\n")
    }
}

/// Menu of AI apps. Pass `onSummarize` to add the in-app ✨ BCS summary at the top.
struct AskAIMenu<Label: View>: View {
    var onSummarize: (() -> Void)?
    let onPick: (AIApp) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            if let onSummarize {
                Button(action: onSummarize) { SwiftUI.Label("BCS summary (in app)", systemImage: "sparkles") }
                Divider()
            }
            ForEach(AIApp.main) { app in
                Button { onPick(app) } label: { SwiftUI.Label("Ask \(app.name)", systemImage: app.icon) }
            }
            Menu {
                ForEach(AIApp.more) { app in
                    Button { onPick(app) } label: { SwiftUI.Label(app.name, systemImage: app.icon) }
                }
            } label: {
                SwiftUI.Label("More", systemImage: "ellipsis.circle")
            }
        } label: {
            label()
        }
    }
}

/// In-app Safari showing the AI app, with an optional "paste" hint on top.
struct AIChatSheetView: View {
    let sheet: AIChatSheet
    @State private var showNote = true

    var body: some View {
        SafariSheet(url: sheet.url)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                if let note = sheet.note, showNote {
                    Label(note, systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.8), in: Capsule())
                        .padding(.bottom, 90)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .seconds(4))
                            withAnimation { showNote = false }
                        }
                }
            }
    }
}

struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.barCollapsingEnabled = true
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.dismissButtonStyle = .close
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
