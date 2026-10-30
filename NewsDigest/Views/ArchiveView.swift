import SwiftUI

struct ArchiveView: View {
    @EnvironmentObject private var store: DigestStore
    @State private var query = ""
    @State private var mode = 0
    @State private var reader: SavedItem?

    var body: some View {
        NavigationStack {
            Group {
                if store.authState != .signedIn && store.archiveDates.isEmpty {
                    ConnectPrompt()
                } else if !query.isEmpty {
                    results(store.search(query), empty: "No matches for “\(query)”")
                } else {
                    VStack(spacing: 0) {
                        Picker("", selection: $mode) {
                            Text("Days").tag(0)
                            Text("Saved (\(store.bookmarks.count))").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

                        if mode == 0 { days } else { results(store.bookmarks, empty: "Tap the bookmark on any card to save it here for revision.") }
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Archive")
            .searchable(text: $query, prompt: "Search: Padma, ASEAN, GDP…")
            .task { try? await store.refreshArchive() }
            .navigationDestination(for: String.self) { date in
                DayDigestView(date: date).navigationTitle(DigestDate.pretty(date))
            }
            .fullScreenCover(item: $reader) { item in
                ReaderView(paper: item.paper, date: DigestDate.date(item.date), pageId: item.item.pageId)
            }
        }
    }

    private var days: some View {
        List {
            if store.missingThisWeek > 0 {
                Section {
                    Label {
                        Text("\(store.missingThisWeek) missing in the last 7 days")
                            .font(.subheadline.weight(.semibold))
                        Text("The server tries these again every hour.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
            ForEach(groupedByMonth, id: \.0) { month, dates in
                Section(month) {
                    ForEach(dates, id: \.self) { date in
                        NavigationLink(value: date) {
                            DayRow(date: date, digests: store.cached(date), missing: store.missingPapers(date))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { try? await store.refreshArchive() }
        .overlay {
            if store.archiveDates.isEmpty {
                ContentUnavailableView("No digests yet", systemImage: "tray", description: Text("They'll show up here after the first morning run."))
            }
        }
    }

    private var groupedByMonth: [(String, [String])] {
        var order: [String] = []
        var dict: [String: [String]] = [:]
        for d in store.archiveDates {
            let month = DigestDate.date(d).formatted(.dateTime.month(.wide).year())
            if dict[month] == nil { order.append(month) }
            dict[month, default: []].append(d)
        }
        return order.map { ($0, dict[$0]!) }
    }

    private func results(_ items: [SavedItem], empty: String) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(items) { ItemCard(saved: $0, showDate: true, onOpenPage: { reader = $0 }) }
            }
            .padding(16)
        }
        .overlay {
            if items.isEmpty { ContentUnavailableView(empty, systemImage: "magnifyingglass") }
        }
    }
}

private struct DayRow: View {
    let date: String
    let digests: [Digest]
    let missing: [Paper]

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text(DigestDate.date(date).formatted(.dateTime.day()))
                    .font(.title2.weight(.bold))
                Text(DigestDate.date(date).formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(DigestDate.pretty(date)).font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    ForEach(digests.filter { !missing.contains($0.paper) }) { d in
                        PaperBadge(paper: d.paper)
                        Text("\(d.itemCount)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !missing.isEmpty {
                    Label(
                        missing.count == Paper.allCases.count
                            ? "Both papers missing"
                            : "\(missing.map(\.shortName).joined(separator: ", ")) missing",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
