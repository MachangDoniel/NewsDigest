import SwiftUI

/// Wraps children onto multiple lines (for key-fact tags).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * spacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    /// A tag never gets wider than the row, so long ones wrap onto more lines instead of overflowing.
    private func size(_ view: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let natural = view.sizeThatFits(.unspecified)
        guard natural.width > maxWidth, maxWidth.isFinite else { return natural }
        return view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = size(subviews[i], maxWidth: bounds.width)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = size(subviews[i], maxWidth: maxWidth)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > maxWidth {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

struct PaperBadge: View {
    let paper: Paper
    var body: some View {
        Text(paper.shortName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(paper.color)
            .background(paper.color.opacity(0.12), in: Capsule())
    }
}

struct Chip: View {
    let title: String
    var icon: String?
    var count: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.caption) }
                Text(title).font(.subheadline.weight(.medium))
                if let count {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(selected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
    }
}

struct ItemCard: View {
    @EnvironmentObject private var store: DigestStore
    let saved: SavedItem
    var showDate = false
    var onOpenPage: ((SavedItem) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                PaperBadge(paper: saved.paper)
                Label(Category.short(saved.category), systemImage: Category.icon(saved.category))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showDate {
                    Text("· \(DigestDate.pretty(saved.date))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if saved.item.isHigh {
                    Label("High", systemImage: "flame.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                }
            }

            Text(saved.item.headline)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(saved.item.bullets, id: \.self) { bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(y: -2)
                        Text(bullet).font(.subheadline).foregroundStyle(.primary.opacity(0.85))
                    }
                }
            }

            if !saved.item.keyFacts.isEmpty {
                FlowLayout {
                    ForEach(saved.item.keyFacts, id: \.self) { fact in
                        Text(fact)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                            .textSelection(.enabled)
                    }
                }
            }

            if let excerpt = saved.item.excerpt, !excerpt.isEmpty {
                FromThePaper(headline: saved.item.sourceHeadline, excerpt: excerpt, tint: saved.paper.color)
            }

            if saved.item.needsCheck {
                Label("Read by a lighter AI model. Check numbers and dates on the page.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 18) {
                if let onOpenPage {
                    Button { onOpenPage(saved) } label: {
                        Label("Page \(saved.item.page)", systemImage: "newspaper")
                    }
                }
                Spacer()
                ShareLink(item: shareText) { Image(systemName: "square.and.arrow.up") }
                Button { store.toggleBookmark(saved) } label: {
                    Image(systemName: store.isBookmarked(saved) ? "bookmark.fill" : "bookmark")
                }
                .sensoryFeedback(.impact(weight: .light), trigger: store.isBookmarked(saved))
            }
            .font(.subheadline)
            .foregroundStyle(Color.accentColor)
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var shareText: String {
        ([saved.item.headline] + saved.item.bullets.map { "• \($0)" } + ["Key facts: " + saved.item.keyFacts.joined(separator: "; ")])
            .joined(separator: "\n")
    }
}

/// The paper's own headline and opening lines, collapsed by default.
struct FromThePaper: View {
    let headline: String?
    let excerpt: String
    let tint: Color
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "text.quote")
                    Text("From the paper").font(.caption.weight(.semibold))
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2)
                }
                .foregroundStyle(tint)
            }
            .buttonStyle(.plain)

            if open {
                if let headline, !headline.isEmpty {
                    Text(headline).font(.subheadline.weight(.semibold))
                }
                Text(excerpt).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) { Rectangle().fill(tint.opacity(0.5)).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2)) }
    }
}

struct McqCard: View {
    let index: Int
    let mcq: Mcq
    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Q\(index). \(mcq.question)").font(.subheadline.weight(.semibold))
            if mcq.needsCheck {
                Label("From a lighter AI model. Verify the answer.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            ForEach(mcq.options, id: \.self) { option in
                Button { withAnimation(.snappy) { picked = option } } label: {
                    HStack {
                        Text(option).font(.subheadline).multilineTextAlignment(.leading)
                        Spacer()
                        if picked != nil, option == mcq.answer {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if picked == option {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                    .padding(10)
                    .background(background(for: option), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(picked != nil)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sensoryFeedback(trigger: picked) { _, new in
            new == nil ? nil : (new == mcq.answer ? .success : .error)
        }
    }

    private func background(for option: String) -> Color {
        guard picked != nil else { return Color(.tertiarySystemFill) }
        if option == mcq.answer { return .green.opacity(0.18) }
        if option == picked { return .red.opacity(0.18) }
        return Color(.tertiarySystemFill)
    }
}

struct StatusBanner: View {
    let status: RunStatus
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.isProblem ? "exclamationmark.triangle.fill" : "clock")
                .foregroundStyle(status.isProblem ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.title).font(.subheadline.weight(.semibold))
                Text(status.help).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background((status.isProblem ? Color.orange : Color.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Placeholder cards shown while loading.
struct SkeletonCard: View {
    @State private var on = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 4).frame(width: 110, height: 12)
            RoundedRectangle(cornerRadius: 4).frame(height: 18)
            RoundedRectangle(cornerRadius: 4).frame(width: 240, height: 18)
            RoundedRectangle(cornerRadius: 4).frame(height: 12)
            RoundedRectangle(cornerRadius: 4).frame(width: 200, height: 12)
        }
        .foregroundStyle(Color.secondary.opacity(on ? 0.12 : 0.22))
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { on = true } }
    }
}
