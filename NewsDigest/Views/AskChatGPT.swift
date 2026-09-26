import SafariServices
import SwiftUI

/// Opens ChatGPT in an in-app Safari sheet with a question already filled in.
/// Uses chatgpt.com's `?q=` prompt link and Safari's sign-in, so it runs on the user's own
/// ChatGPT account. No API key needed.
enum AskChatGPT {
    /// Long URLs get rejected, so the prompt is kept compact.
    private static let maxPromptLength = 1800

    static func url(_ prompt: String) -> URL {
        var c = URLComponents(string: "https://chatgpt.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: String(prompt.prefix(maxPromptLength)))]
        return c.url!
    }

    static func prompt(for saved: SavedItem) -> String {
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

    static func prompt(for mcq: Mcq, paper: Paper?) -> String {
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

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
