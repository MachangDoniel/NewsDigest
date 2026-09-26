import SwiftUI

/// On-device Gemini summary of the captured page, plus follow-up chat.
struct PageSummaryView: View {
    let paper: Paper
    let capture: PageCapture.Captured

    @Environment(\.dismiss) private var dismiss
    @State private var sections: [DigestSection] = []
    @State private var mcqs: [Mcq] = []
    @State private var loading = true
    @State private var error: String?
    @State private var chat: [(role: String, text: String)] = []
    @State private var question = ""
    @State private var asking = false
    @FocusState private var focused: Bool

    private var today: String { DigestDate.string(.now) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let image = capture.image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                        }

                        if loading {
                            ForEach(0..<2, id: \.self) { _ in SkeletonCard() }
                        } else if let error {
                            ContentUnavailableView("Summary failed", systemImage: "exclamationmark.triangle", description: Text(error))
                            Button("Try again") { Task { await summarize() } }.frame(maxWidth: .infinity)
                        } else if sections.isEmpty {
                            ContentUnavailableView("Nothing exam-relevant on this page", systemImage: "checkmark.seal")
                        } else {
                            ForEach(sections, id: \.category) { section in
                                Label(section.category, systemImage: Category.icon(section.category))
                                    .font(.headline)
                                    .padding(.top, 6)
                                ForEach(section.items, id: \.self) {
                                    ItemCard(saved: SavedItem(date: today, paper: paper, category: section.category, item: $0))
                                }
                            }
                            if !mcqs.isEmpty {
                                Label("Practice MCQs", systemImage: "checklist").font(.headline).padding(.top, 6)
                                ForEach(Array(mcqs.enumerated()), id: \.offset) { McqCard(index: $0 + 1, mcq: $1) }
                            }
                        }

                        ForEach(Array(chat.enumerated()), id: \.offset) { _, msg in
                            ChatBubble(role: msg.role, text: msg.text)
                        }
                        if asking { ProgressView().padding(.leading, 8) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: chat.count) { withAnimation { proxy.scrollTo("bottom") } }
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { if !loading && error == nil { askBar } }
            .navigationTitle("BCS summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task { await summarize() }
            .sensoryFeedback(.success, trigger: loading) { old, new in old && !new && error == nil }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var askBar: some View {
        HStack(spacing: 10) {
            TextField("Ask: explain in Bangla, background…", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            Button { Task { await ask() } } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func summarize() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let out = try await GeminiClient.summarize(image: capture.data, mime: capture.mime, paper: paper)
            sections = out.sections.filter { !$0.items.isEmpty }
            mcqs = out.mcqs.filter { $0.options.contains($0.answer) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func ask() async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        question = ""
        focused = false
        chat.append(("user", q))
        asking = true
        defer { asking = false }

        // Page image + summary as context, then the running conversation.
        let summaryText = sections.flatMap { s in s.items.map { "- \($0.headline): \($0.bullets.joined(separator: " "))" } }.joined(separator: "\n")
        var contents: [GeminiClient.Content] = [
            .init(role: "user", parts: [
                .image(capture.data, mime: capture.mime),
                .text("This is a page from today's \(paper.name). You are helping a BCS exam candidate. Your summary so far:\n\(summaryText)\n\nAnswer follow-up questions concisely. Use Bangla if asked."),
            ]),
            .init(role: "model", parts: [.text("Understood. Ask me anything about this page.")]),
        ]
        contents += chat.map { .init(role: $0.role == "user" ? "user" : "model", parts: [.text($0.text)]) }
        do {
            chat.append(("model", try await GeminiClient.generate(contents)))
        } catch {
            chat.append(("model", "⚠️ \(error.localizedDescription)"))
        }
    }
}

private struct ChatBubble: View {
    let role: String
    let text: String
    var body: some View {
        HStack {
            if role == "user" { Spacer(minLength: 40) }
            Text(LocalizedStringKey(text))
                .font(.subheadline)
                .textSelection(.enabled)
                .padding(12)
                .foregroundStyle(role == "user" ? .white : .primary)
                .background(role == "user" ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if role != "user" { Spacer(minLength: 40) }
        }
    }
}
