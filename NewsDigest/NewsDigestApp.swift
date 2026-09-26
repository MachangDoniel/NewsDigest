import SwiftUI

@main
struct NewsDigestApp: App {
    @StateObject private var store = DigestStore()
    @StateObject private var router = Router()

    var body: some Scene {
        WindowGroup {
            TabView(selection: $router.tab) {
                TodayView()
                    .tabItem { Label("Today", systemImage: "sparkles.rectangle.stack") }
                    .tag(AppTab.today)
                PracticeView()
                    .tabItem { Label("Practice", systemImage: "checklist") }
                    .tag(AppTab.practice)
                ArchiveView()
                    .tabItem { Label("Archive", systemImage: "calendar") }
                    .tag(AppTab.archive)
                PapersView()
                    .tabItem { Label("Papers", systemImage: "newspaper") }
                    .tag(AppTab.papers)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
            .environmentObject(store)
            .environmentObject(router)
        }
    }
}
