import SwiftUI

struct ContentView: View {
    private let siteURL = URL(string: "https://biddabari.com")!

    @State private var progress: Double = 0
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 2)
            }

            WebView(url: siteURL, progress: $progress, isLoading: $isLoading)
        }
        .ignoresSafeArea(edges: .bottom)
        .statusBarHidden(false)
    }
}

#Preview {
    ContentView()
}
