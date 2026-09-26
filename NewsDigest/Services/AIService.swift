import Foundation
import Supabase

/// ✨ Summarize and follow-up chat. Calls the `summarize` Supabase Edge Function, which holds the
/// Gemini/Groq keys, so no API key lives on the phone. See supabase/functions/summarize.
enum AI {
    static let modelKey = "aiModel"
    static let languageKey = "digestLanguage"

    /// Choices for the Settings drop-down. "auto" lets the server pick the best available model.
    static let models: [(id: String, label: String)] = [
        ("auto", "Auto (best available)"),
        ("gemini-3.8-flash", "Gemini 3.8 Flash"),
        ("gemini-3.7-flash", "Gemini 3.7 Flash"),
        ("gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite (fastest)"),
    ]

    /// "auto" = each paper in its own language (Daily Star English, Prothom Alo Bangla).
    static func language(for paper: Paper) -> String {
        let setting = UserDefaults.standard.string(forKey: languageKey) ?? "auto"
        return setting == "auto" ? (paper == .prothomalo ? "bn" : "en") : setting
    }

    struct SummaryResult {
        var sections: [DigestSection] = []
        var mcqs: [Mcq] = []
        /// Set when no AI model was available; the view then shows the paper's own stories.
        var unavailable: String?
    }

    private struct SummarizeRequest: Encodable {
        let action = "summarize"
        let paper: String
        let pageName: String
        let pageNo: Int
        let lang: String
        let model: String
        let stories: [PaperStory]
        let image: Image?
        struct Image: Encodable { let mime: String; let data: String }
    }

    private struct SummarizeResponse: Decodable {
        let ok: Bool
        let sections: [DigestSection]?
        let mcqs: [Mcq]?
        let reason: String?
        let message: String?
    }

    static func summarize(_ capture: PageCapture.Captured, paper: Paper, store: DigestStore) async throws -> SummaryResult {
        let request = SummarizeRequest(
            paper: paper.name,
            pageName: capture.pageName ?? "",
            pageNo: capture.pageNo ?? 0,
            lang: language(for: paper),
            model: UserDefaults.standard.string(forKey: modelKey) ?? "auto",
            stories: capture.stories,
            // Only send the image when there's no article text; it's much larger.
            image: capture.stories.isEmpty ? .init(mime: capture.mime, data: capture.data.base64EncodedString()) : nil
        )
        let res: SummarizeResponse = try await store.invokeFunction("summarize", body: request)
        guard res.ok else { return SummaryResult(unavailable: res.message ?? "AI is unavailable right now.") }
        return SummaryResult(sections: res.sections ?? [], mcqs: res.mcqs ?? [])
    }

    struct ChatMessage: Encodable { let role: String; let text: String }
    private struct ChatRequest: Encodable {
        let action = "chat"
        let context: String
        let messages: [ChatMessage]
    }
    private struct ChatResponse: Decodable { let ok: Bool; let text: String?; let message: String? }

    static func chat(context: String, messages: [ChatMessage], store: DigestStore) async throws -> String {
        let res: ChatResponse = try await store.invokeFunction("summarize", body: ChatRequest(context: context, messages: messages))
        if res.ok, let text = res.text { return text }
        return "⚠️ " + (res.message ?? "AI is unavailable right now. Try again later.")
    }
}

enum Prompts {
    /// Prompt copied to the clipboard for the "Send page to ChatGPT / Gemini" hand-off.
    static func share(paper: Paper) -> String {
        """
        I'm preparing for the Bangladesh Civil Service (BCS) exam. This is a page from today's \(paper.name).
        Pick out only the news that matters for BCS (Bangladesh and international affairs, economy, science & tech, environment, \
        records, rankings, appointments), and for each give 2–3 bullet points and the exact key facts (names, numbers, dates). \
        Then write 3 MCQs with answers.\(paper == .prothomalo ? " Answer in Bangla." : "")
        """
    }
}
