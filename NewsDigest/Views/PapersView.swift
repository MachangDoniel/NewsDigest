import SwiftUI

struct PapersView: View {
    @State private var open: Paper?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(Paper.allCases) { paper in
                        Button { open = paper } label: { PaperCard(paper: paper) }
                            .buttonStyle(.plain)
                    }

                    Label("Sign in once inside each paper. The app remembers your login. Tap Ask on any page or article for a BCS summary, or to open it in ChatGPT, Gemini, Claude and more.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Papers")
            .fullScreenCover(item: $open) { ReaderView(paper: $0, date: .now) }
        }
    }
}

private struct PaperCard: View {
    let paper: Paper

    var body: some View {
        HStack(spacing: 16) {
            Text(paper.monogram)
                .font(.title.weight(.black))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(paper.color.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(paper.name).font(.title3.weight(.bold))
                Text("Today's e-paper · \(Date.now.formatted(.dateTime.day().month(.wide)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
