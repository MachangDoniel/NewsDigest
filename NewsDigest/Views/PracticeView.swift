import SwiftUI

enum AppTab: Hashable { case today, practice, archive, papers, settings }

/// Lets one tab send the user to another (e.g. Today → Practice for the same day).
@MainActor
final class Router: ObservableObject {
    @Published var tab: AppTab = .today
    @Published var practiceDate = Calendar.dhaka.startOfDay(for: .now)

    func practice(_ date: String) {
        practiceDate = DigestDate.date(date)
        tab = .practice
    }
}

/// All MCQs for a day in one place, with a running score.
struct PracticeView: View {
    @EnvironmentObject private var store: DigestStore
    @EnvironmentObject private var router: Router

    @State private var digests: [Digest] = []
    @State private var loading = false
    @State private var paperFilter: Paper?
    @State private var answers: [String: String] = [:]
    @State private var showCalendar = false

    private var dateString: String { DigestDate.string(router.practiceDate) }
    private var isToday: Bool { Calendar.dhaka.isDateInToday(router.practiceDate) }

    private struct Question: Identifiable {
        let paper: Paper
        let mcq: Mcq
        var id: String { "\(paper.rawValue)|\(mcq.question)" }
    }

    private var questions: [Question] {
        digests
            .filter { paperFilter == nil || $0.paper == paperFilter }
            .flatMap { d in d.mcqs.map { Question(paper: d.paper, mcq: $0) } }
    }

    private var answered: Int { questions.filter { answers[$0.id] != nil }.count }
    private var correct: Int { questions.filter { answers[$0.id] == $0.mcq.answer }.count }

    var body: some View {
        NavigationStack {
            Group {
                if store.authState != .signedIn {
                    ConnectPrompt()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            Picker("Paper", selection: $paperFilter) {
                                Text("Both").tag(Paper?.none)
                                ForEach(Paper.allCases) { Text($0.shortName).tag(Paper?.some($0)) }
                            }
                            .pickerStyle(.segmented)

                            if !questions.isEmpty { scoreCard }

                            if loading && questions.isEmpty {
                                ForEach(0..<2, id: \.self) { _ in SkeletonCard() }
                            } else if questions.isEmpty {
                                ContentUnavailableView(
                                    "No MCQs for \(DigestDate.pretty(dateString))",
                                    systemImage: "checklist",
                                    description: Text("They're made with each morning's digest.")
                                )
                                .padding(.top, 40)
                            } else {
                                ForEach(Array(questions.enumerated()), id: \.element.id) { i, q in
                                    McqCard(index: i + 1, mcq: q.mcq, paper: q.paper, picked: binding(for: q.id))
                                }
                            }
                        }
                        .padding(16)
                    }
                    .background(Color(.systemGroupedBackground))
                    .solidTopEdge()
                    .refreshable { await load() }
                    .task(id: dateString) { await load() }
                }
            }
            .navigationTitle("Practice · \(DigestDate.pretty(dateString))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.authState == .signedIn {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        Button { showCalendar = true } label: { Image(systemName: "calendar") }
                        Button { step(1) } label: { Image(systemName: "chevron.right") }.disabled(isToday)
                    }
                }
            }
            .sheet(isPresented: $showCalendar) {
                NavigationStack {
                    DatePicker("Date", selection: $router.practiceDate, in: ...Date.now, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .environment(\.timeZone, .dhaka)
                        .padding()
                        .navigationTitle("Practice a past day")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Done") { showCalendar = false } }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private var scoreCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: questions.isEmpty ? 0 : CGFloat(answered) / CGFloat(questions.count))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy, value: answered)
                Text("\(correct)").font(.title3.weight(.bold))
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(correct) correct of \(answered) answered").font(.headline)
                Text("\(questions.count) questions · \(questions.count - answered) left")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if answered > 0 {
                Button("Reset") { withAnimation { answers.removeAll() } }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func binding(for id: String) -> Binding<String?> {
        Binding(get: { answers[id] }, set: { answers[id] = $0 })
    }

    private func step(_ days: Int) {
        guard let next = Calendar.dhaka.date(byAdding: .day, value: days, to: router.practiceDate), next <= .now else { return }
        router.practiceDate = next
    }

    private func load() async {
        answers.removeAll()
        digests = store.cached(dateString)
        loading = true
        defer { loading = false }
        if let fresh = try? await store.load(dateString), !fresh.isEmpty { digests = fresh }
    }
}
