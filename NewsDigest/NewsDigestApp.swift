import SwiftUI

@main
struct NewsDigestApp: App {
    @StateObject private var store = DigestStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                TodayView()
                    .tabItem { Label("Today", systemImage: "sparkles.rectangle.stack") }
                ArchiveView()
                    .tabItem { Label("Archive", systemImage: "calendar") }
                PapersView()
                    .tabItem { Label("Papers", systemImage: "newspaper") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .environmentObject(store)
        }
    }
}
