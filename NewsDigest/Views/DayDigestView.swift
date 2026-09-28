import SwiftUI

/// One day's digest: status banners, paper + category filters, cards, and practice MCQs.
struct DayDigestView: View {
    @EnvironmentObject private var store: DigestStore
    @EnvironmentObject private var router: Router
    let date: String

    @State private var digests: [Digest] = []
    @State private var loading = true
    @State private var error: String?
    @State private var paperFilter: Paper?
    @State private var category: String?
    @State private var highOnly = false
    @State private var reader: SavedItem?
    @State private var run: RunNow = .idle

    enum RunNow: Equatable { case idle, starting, started(String), failed(String) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                ForEach(store.cachedStatus(date).filter { $0.state != "ok" }, id: \.self) { StatusBanner(status: $0) }

                if canRunNow { runNowCard }

                if mcqCount > 0 {
                    Button { router.practice(date) } label: { practiceBanner }
                        .buttonStyle(.plain)
                }

                Section {
                    content
                } header: {
                    filters
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .solidTopEdge()
        .refreshable { await load() }
        .task(id: date) { await load() }
        .task(id: run) { await followRun() }
        .fullScreenCover(item: $reader) { item in
            ReaderView(paper: item.paper, date: DigestDate.date(item.date), pageId: item.item.pageId)
        }
    }

    // MARK: - Filters

    private var filters: some View {
        VStack(spacing: 10) {
            Picker("Paper", selection: $paperFilter) {
                Text("Both").tag(Paper?.none)
                ForEach(Paper.allCases) { Text($0.shortName).tag(Paper?.some($0)) }
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(title: "High", icon: "flame.fill", selected: highOnly) { highOnly.toggle() }
                    Divider().frame(height: 22)
                    Chip(title: "All", count: counts.values.reduce(0, +), selected: category == nil) { category = nil }
                    ForEach(Category.all.filter { counts[$0, default: 0] > 0 }, id: \.self) { c in
                        Chip(title: Category.short(c), icon: Category.icon(c), count: counts[c], selected: category == c) {
                            category = category == c ? nil : c
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loading && digests.isEmpty {
            ForEach(0..<3, id: \.self) { _ in SkeletonCard() }
        } else if let error, digests.isEmpty {
            ContentUnavailableView("Couldn't load", systemImage: "wifi.exclamationmark", description: Text(error))
        } else if digests.isEmpty {
            ContentUnavailableView(
                "No digest for \(DigestDate.pretty(date))",
                systemImage: "newspaper",
                description: Text("The server tries every hour from 6 AM until the papers are out. You can also use ✨ Summarize in the Papers tab.")
            )
        } else if items.isEmpty {
            ContentUnavailableView("Nothing matches these filters", systemImage: "line.3.horizontal.decrease.circle")
        } else {
            ForEach(grouped, id: \.0) { category, items in
                if self.category == nil {
                    Label(category, systemImage: Category.icon(category))
                        .font(.title3.weight(.bold))
                        .padding(.top, 8)
                }
                ForEach(items) { ItemCard(saved: $0, onOpenPage: { reader = $0 }) }
            }

        }
    }

    private var mcqCount: Int { digests.reduce(0) { $0 + $1.mcqs.count } }

    private var practiceBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Practice \(mcqCount) MCQs").font(.headline)
                Text("Test yourself on \(DigestDate.pretty(date).lowercased() == "today" ? "today's" : "this day's") news")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Run now

    /// Today, with at least one paper still missing: offer to build it now instead of waiting for the hourly run.
    private var canRunNow: Bool {
        guard date == DigestDate.string(.now), !(loading && digests.isEmpty) else { return false }
        return Set(digests.map(\.paper)).count < Paper.allCases.count
    }

    private var runNowCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 8) {
                Text("Papers out already?").font(.subheadline.weight(.semibold))
                Group {
                    switch run {
                    case .idle, .starting:
                        Text("The server checks every hour. Build today's digest now instead of waiting.")
                    case .started(let message):
                        Text(message + " This page refreshes on its own.")
                    case .failed(let message):
                        Text(message).foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if case .started = run {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await startRun() } } label: {
                        Text(run == .starting ? "Starting…" : "Run digest now")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(run == .starting)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func startRun() async {
        run = .starting
        do {
            let res = try await store.runDigestNow()
            run = res.ok ? .started(res.message) : .failed(res.message)
        } catch {
            run = .failed(error.localizedDescription)
        }
    }

    /// After starting a run, reloads every minute for up to 20 minutes until both papers are in.
    private func followRun() async {
        guard case .started = run else { return }
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled { return }
            await load()
            if !canRunNow { break }
        }
        run = .idle
    }

    // MARK: - Data

    private var visibleDigests: [Digest] { digests.filter { paperFilter == nil || $0.paper == paperFilter } }

    private var allItems: [SavedItem] {
        visibleDigests.flatMap { d in
            d.sections.flatMap { s in s.items.map { SavedItem(date: date, paper: d.paper, category: s.category, item: $0) } }
        }
        .filter { !highOnly || $0.item.isHigh }
    }

    private var counts: [String: Int] { Dictionary(grouping: allItems, by: \.category).mapValues(\.count) }

    private var items: [SavedItem] { allItems.filter { category == nil || $0.category == category } }

    private var grouped: [(String, [SavedItem])] {
        let dict = Dictionary(grouping: items, by: \.category)
        return Category.all.compactMap { c in dict[c].map { (c, $0) } }
    }


    private func load() async {
        if digests.isEmpty { digests = store.cached(date) }
        loading = true
        defer { loading = false }
        do {
            let fresh = try await store.load(date)
            if !fresh.isEmpty || digests.isEmpty { digests = fresh }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
