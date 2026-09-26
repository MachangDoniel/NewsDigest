import Foundation

/// On-device Gemini calls for "✨ Summarize this page" and follow-up chat.
/// Uses the user's own API key from the Keychain.
struct GeminiClient {
    static let keyName = "geminiAPIKey"
    static let modelDefaultsKey = "geminiModel"
    static let defaultModel = "gemini-3.8-flash"

    struct Part: Encodable {
        var text: String?
        var inlineData: InlineData?

        struct InlineData: Encodable {
            let mimeType: String
            let data: String
            enum CodingKeys: String, CodingKey { case mimeType = "mime_type", data }
        }

        enum CodingKeys: String, CodingKey { case text, inlineData = "inline_data" }

        static func text(_ s: String) -> Part { Part(text: s) }
        static func image(_ data: Data, mime: String) -> Part {
            Part(inlineData: .init(mimeType: mime, data: data.base64EncodedString()))
        }
    }

    struct Content: Encodable {
        let role: String  // "user" | "model"
        let parts: [Part]
    }

    enum GeminiError: LocalizedError {
        case missingKey, http(Int, String), empty
        var errorDescription: String? {
            switch self {
            case .missingKey: "Add your Gemini API key in Settings."
            case let .http(code, body): "Gemini error \(code): \(body)"
            case .empty: "Gemini returned an empty answer."
            }
        }
    }

    static var hasKey: Bool { !(Keychain.get(keyName) ?? "").isEmpty }

    static func generate(_ contents: [Content], json: Bool = false) async throws -> String {
        guard let key = Keychain.get(keyName), !key.isEmpty else { throw GeminiError.missingKey }
        let model = UserDefaults.standard.string(forKey: modelDefaultsKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        struct Body: Encodable {
            let contents: [Content]
            let generationConfig: [String: AnyEncodable]
        }
        var config: [String: AnyEncodable] = ["temperature": AnyEncodable(0.2)]
        if json { config["responseMimeType"] = AnyEncodable("application/json") }
        req.httpBody = try JSONEncoder().encode(Body(contents: contents, generationConfig: config))

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw GeminiError.http(status, String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "")
        }
        struct Reply: Decodable {
            struct Candidate: Decodable { let content: C? }
            struct C: Decodable { let parts: [P]? }
            struct P: Decodable { let text: String? }
            let candidates: [Candidate]?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let text = reply.candidates?.first?.content?.parts?.compactMap(\.text).joined() ?? ""
        guard !text.isEmpty else { throw GeminiError.empty }
        return text
    }

    /// Summarizes one captured page into the same shape the server produces.
    static func summarize(image: Data, mime: String, paper: Paper) async throws -> (sections: [DigestSection], mcqs: [Mcq]) {
        let prompt = Prompts.page(paper: paper.name) + "\n\n" + Prompts.jsonShape
        let text = try await generate([Content(role: "user", parts: [.image(image, mime: mime), .text(prompt)])], json: true)
        struct Out: Decodable { let sections: [DigestSection]; let mcqs: [Mcq] }
        let out = try JSONDecoder().decode(Out.self, from: Data(text.utf8))
        return (out.sections, out.mcqs)
    }
}

struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeFn = value.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}

enum Prompts {
    static let languageKey = "digestLanguage"

    static var languageRule: String {
        switch UserDefaults.standard.string(forKey: languageKey) ?? "en" {
        case "bn": "Write everything in Bangla (বাংলা)."
        case "both": "Write the headline in English followed by the Bangla headline in brackets; write bullets and facts in English."
        default: "Write everything in clear, simple English, even when the page is in Bangla."
        }
    }

    /// Keep in sync with server/src/prompt.ts.
    static func page(paper: String) -> String {
        """
        You are a study assistant for a candidate preparing for the Bangladesh Civil Service (BCS) exam.
        The image is a page from today's \(paper) e-paper.

        Extract ONLY news that could matter for BCS preliminary/written/viva: Bangladesh affairs (government decisions, laws, \
        constitution, appointments, projects with cost/length/location, policies, statistics), international affairs (treaties, \
        summits, organizations, conflicts, elections, heads of state), economy (budget, GDP, inflation, remittance, reserves, trade), \
        science & tech, environment/climate, notable sports records, rankings/indices, firsts, awards, and deaths of notable people.
        Skip ads, gossip, entertainment, and crime without policy significance. Do not invent facts that are not on the page.

        Categories: \(Category.all.joined(separator: ", ")).
        Write up to 3 MCQs with 4 options each. The answer must exactly equal one of the options.
        \(languageRule)
        """
    }

    static let jsonShape = """
    Reply with JSON only, in this shape:
    {"sections":[{"category":"...","items":[{"headline":"...","bullets":["..."],"keyFacts":["..."],"bcsRelevance":"high|medium","page":0}]}],
     "mcqs":[{"question":"...","options":["a","b","c","d"],"answer":"a"}]}
    """

    /// Prompt copied to the clipboard for the "Share to ChatGPT / Gemini" hand-off.
    static func share(paper: String) -> String {
        page(paper: paper) + "\n\nFormat the answer as short sections by category, with bullets and key facts, then the MCQs."
    }
}
