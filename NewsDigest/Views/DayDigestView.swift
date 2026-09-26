import SwiftUI

/// One day's digest: status banners, paper + category filters, cards, and practice MCQs.
struct DayDigestView: View {
    @EnvironmentObject private var store: DigestStore
    let date: String

    @State private var digests: [Digest] = []
    @State private var loading = true
    @State private var error: String?
    @State private var paperFilter: Paper?
    @State private var category: String?
    @State private var highOnly = false
    @State private var reader: SavedItem?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                ForEach(store.cachedStatus(date).filter { $0.state != "ok" }, id: \.self) { StatusBanner(status: $0) }

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
        // Solid title bar: otherwise cards scrolling under it show through above the pinned filters.
        .toolbarBackground(Color(.systemGroupedBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .refreshable { await load() }
        .task(id: date) { await load() }
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
                description: Text("The server builds it each morning around 6 AM. You can also use ✨ Summarize in the Papers tab.")
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

            if !mcqs.isEmpty {
                Label("Practice MCQs", systemImage: "checklist")
                    .font(.title3.weight(.bold))
                    .padding(.top, 16)
                ForEach(Array(mcqs.enumerated()), id: \.offset) { i, q in McqCard(index: i + 1, mcq: q) }
            }
        }
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

    private var mcqs: [Mcq] { category == nil ? visibleDigests.flatMap(\.mcqs) : [] }

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
