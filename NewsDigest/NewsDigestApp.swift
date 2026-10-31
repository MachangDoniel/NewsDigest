import SwiftUI

@main
struct NewsDigestApp: App {
    @StateObject private var store = DigestStore()
    @StateObject private var router = Router()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PaperNotifier.start()
    }

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
                    .badge(store.missingThisWeek)
                PapersView()
                    .tabItem { Label("Papers", systemImage: "newspaper") }
                    .tag(AppTab.papers)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
            .task {
                await store.refreshCoverage()
                await PaperNotifier.requestPermission()
                await PaperNotifier.notifyNewPapers(store: store)
            }
            .environmentObject(store)
            .environmentObject(router)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { PaperNotifier.scheduleBackgroundCheck() }
            if phase == .active { Task { await PaperNotifier.notifyNewPapers(store: store) } }
        }
        .backgroundTask(.appRefresh(PaperNotifier.backgroundTaskID)) {
            await PaperNotifier.scheduleBackgroundCheck()
            await PaperNotifier.notifyNewPapers(store: store)
        }
    }
}
