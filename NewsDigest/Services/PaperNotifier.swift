import BackgroundTasks
import UserNotifications

/// Local notifications: one per paper, once its digest for today is on the server.
/// There's no push here, so iOS decides when the background check runs; it can be hours late.
@MainActor
enum PaperNotifier {
    static let backgroundTaskID = "com.newsdigest.paper-check"
    private static let notifiedKey = "notifiedPapers"
    private static let delegate = ForegroundBanners()

    static func start() {
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Asks iOS to wake the app for another check. Each wake-up has to ask for the next.
    static func scheduleBackgroundCheck() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Notifies once for each of today's papers that has appeared since the last check.
    static func notifyNewPapers(store: DigestStore) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        let today = DigestDate.string(.now)
        guard let papers = try? await store.papers(on: today) else { return }

        let defaults = UserDefaults.standard
        // Only today's entries are kept, so the list can't grow.
        var notified = (defaults.stringArray(forKey: notifiedKey) ?? []).filter { $0.hasPrefix(today) }
        for paper in papers {
            let id = "\(today)/\(paper.rawValue)"
            guard !notified.contains(id) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(paper.name) digest is ready"
            content.body = "Today's summaries are ready to read."
            content.sound = .default
            guard (try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))) != nil else { continue }
            notified.append(id)
        }
        defaults.set(notified, forKey: notifiedKey)
    }
}

/// iOS hides notifications while the app is open unless told otherwise.
private final class ForegroundBanners: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
