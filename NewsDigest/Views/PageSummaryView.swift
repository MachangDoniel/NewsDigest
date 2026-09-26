import SwiftUI

/// BCS summary of the page being viewed (via the `summarize` Edge Function), plus follow-up chat.
/// When no AI model is available, it shows the paper's own stories for the page instead.
struct PageSummaryView: View {
    let paper: Paper
    let capture: PageCapture.Captured

    @EnvironmentObject private var store: DigestStore
    @Environment(\.dismiss) private var dismiss
    @State private var sections: [DigestSection] = []
    @State private var mcqs: [Mcq] = []
    @State private var loading = true
    @State private var error: String?
    /// Set when AI was unavailable and we're showing the paper's stories instead.
    @State private var unavailable: String?
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
                        } else if let unavailable {
                            paperFallback(unavailable)
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
                                ForEach(Array(mcqs.enumerated()), id: \.offset) { McqCard(index: $0 + 1, mcq: $1, paper: paper) }
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
            .safeAreaInset(edge: .bottom) { if !loading && error == nil && unavailable == nil { askBar } }
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

    /// The paper's own headlines and text, shown when every AI key is busy or out of quota.
    @ViewBuilder
    private func paperFallback(_ message: String) -> some View {
        Label(message + " Here's what the paper says on this page.", systemImage: "text.quote")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        if capture.stories.isEmpty {
            ContentUnavailableView(
                "No text for this page",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Sign in to the e-paper in the Papers tab, then try again.")
            )
        }
        ForEach(capture.stories, id: \.self) { story in
            VStack(alignment: .leading, spacing: 8) {
                Text(story.headline).font(.headline)
                Text(story.body.count > 700 ? String(story.body.prefix(700)) + " …" : story.body)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
                ForEach(story.captions, id: \.self) { caption in
                    Label(caption, systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        Button("Try AI again") { Task { await summarize() } }.frame(maxWidth: .infinity)
    }

    private func summarize() async {
        loading = true
        error = nil
        unavailable = nil
        defer { loading = false }
        do {
            let out = try await AI.summarize(capture, paper: paper, store: store)
            if let reason = out.unavailable {
                unavailable = reason
            } else {
                sections = out.sections.filter { !$0.items.isEmpty }
                mcqs = out.mcqs.filter { $0.options.contains($0.answer) }
            }
        } catch {
            // Network or server trouble: still show the paper's text if we have it.
            if capture.stories.isEmpty { self.error = error.localizedDescription } else { unavailable = "AI couldn't be reached." }
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

        // The page's own text (or the summary) as context, then the running conversation.
        let context: String = capture.stories.isEmpty
            ? sections.flatMap { s in s.items.map { "- \($0.headline): \($0.bullets.joined(separator: " ")) \($0.keyFacts.joined(separator: "; "))" } }.joined(separator: "\n")
            : capture.stories.map { "## \($0.headline)\n\($0.body)" }.joined(separator: "\n\n")
        let messages = chat.map { AI.ChatMessage(role: $0.role, text: $0.text) }
        do {
            chat.append(("model", try await AI.chat(context: "\(paper.name), page \(capture.pageNo.map(String.init) ?? "?")\n\(context)", messages: messages, store: store)))
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
