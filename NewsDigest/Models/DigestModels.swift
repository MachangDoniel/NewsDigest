import Foundation

/// Mirrors server/src/types.ts and the `digests` table.
struct Digest: Codable, Identifiable, Hashable {
    let id: Int
    let date: String            // yyyy-MM-dd (Dhaka)
    let paper: Paper
    let sections: [DigestSection]
    let mcqs: [Mcq]
    let pageCount: Int

    enum CodingKeys: String, CodingKey {
        case id, date, paper, sections, mcqs
        case pageCount = "page_count"
    }

    var itemCount: Int { sections.reduce(0) { $0 + $1.items.count } }
}

struct DigestSection: Codable, Hashable {
    let category: String
    let items: [DigestItem]
}

struct DigestItem: Codable, Hashable {
    let headline: String
    let bullets: [String]
    let keyFacts: [String]
    let bcsRelevance: String
    let page: Int
    let model: String?
    var pageId: String? = nil
    /// "text" when summarized from the paper's article text, "image" when read off the page scan.
    var source: String? = nil
    /// The paper's own headline and opening lines (text mode).
    var sourceHeadline: String? = nil
    var excerpt: String? = nil

    var isHigh: Bool { bcsRelevance == "high" }
    /// A lighter model reading a page image sometimes misreads numbers (e.g. Bangla digits). Text is exact.
    var needsCheck: Bool { source != "text" && ModelCheck.isLight(model) }
}

enum ModelCheck {
    static func isLight(_ model: String?) -> Bool {
        guard let model else { return false }
        return model.contains("lite") || model.hasPrefix("groq")
    }
}

struct Mcq: Codable, Hashable {
    let question: String
    let options: [String]
    let answer: String
    var model: String? = nil
    var source: String? = nil

    var needsCheck: Bool { source != "text" && ModelCheck.isLight(model) }
}

struct RunStatus: Codable, Hashable {
    let date: String
    let paper: Paper
    let state: String
    let message: String?

    var isProblem: Bool { state == "login_expired" || state == "challenge" || state == "error" }

    var title: String {
        switch state {
        case "login_expired": "\(paper.name) login expired"
        case "challenge": "\(paper.name) asked for a verification check"
        case "not_published": "\(paper.name) edition not out yet"
        case "error": "\(paper.name) digest failed"
        default: "\(paper.name) ready"
        }
    }

    var help: String {
        switch state {
        case "login_expired" where paper == .prothomalo:
            "Check the PROTHOMALO_EMAIL / PROTHOMALO_PASSWORD secrets on GitHub."
        case "login_expired":
            "Check the DAILYSTAR_EMAIL / DAILYSTAR_PASSWORD secrets on GitHub."
        case "challenge":
            "The site showed a CAPTCHA. Use ✨ Summarize in the Papers tab today."
        case "not_published":
            "The server will try again later this morning."
        default:
            message ?? ""
        }
    }
}

/// An item plus where it came from — used for bookmarks and search results.
struct SavedItem: Codable, Hashable, Identifiable {
    let date: String
    let paper: Paper
    let category: String
    let item: DigestItem

    var id: String { "\(date)|\(paper.rawValue)|\(item.headline)" }
}

enum Category {
    static let all = ["Bangladesh Affairs", "International Affairs", "Economy", "Science & Tech", "Environment", "Sports", "Others"]

    static func icon(_ name: String) -> String {
        switch name {
        case "Bangladesh Affairs": "building.columns"
        case "International Affairs": "globe.asia.australia"
        case "Economy": "chart.line.uptrend.xyaxis"
        case "Science & Tech": "atom"
        case "Environment": "leaf"
        case "Sports": "trophy"
        default: "square.grid.2x2"
        }
    }

    static func short(_ name: String) -> String {
        switch name {
        case "Bangladesh Affairs": "Bangladesh"
        case "International Affairs": "International"
        case "Science & Tech": "Sci & Tech"
        default: name
        }
    }
}

enum DigestDate {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = .dhaka
        f.timeZone = .dhaka
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }
    static func date(_ string: String) -> Date { formatter.date(from: string) ?? .now }

    static func pretty(_ string: String) -> String {
        let d = date(string)
        let cal = Calendar.dhaka
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

/// What the Admin screen shows; built by the `summarize` function's `admin_overview` action.
/// Encodable too, so the screen can export it as a file.
struct AdminOverview: Codable {
    struct Run: Codable, Identifiable {
        let date: String
        let paper: Paper
        /// "ok", a `RunStatus` state, or "missing" when nothing was built or reported.
        let state: String
        let message: String?
        let pages: Int?
        var id: String { date + paper.rawValue }

        var summary: String {
            switch state {
            case "ok": "Built" + (pages.map { " · \($0) pages" } ?? "")
            case "challenge": "Blocked by a bot check"
            case "login_expired": "Login expired"
            case "not_published": "Edition not out yet"
            case "error": "Failed"
            default: "Not built"
            }
        }
    }

    struct WorkflowRun: Codable, Identifiable {
        let id: Int
        let at: String
        let event: String
        /// "success", "failure", "cancelled", or "queued" / "in_progress" while running.
        let result: String
    }

    struct Database: Codable {
        let ok: Bool
        let message: String?
        let pingMs: Int
        let digests: Int
        let firstDate: String?
        let latestDate: String?
    }

    /// Real sizes against the Supabase free plan's limits. Nil when the server couldn't measure them.
    struct Storage: Codable {
        let dbBytes: Int?
        let dbLimitBytes: Int
        let audioBytes: Int?
        let audioLimitBytes: Int
        let audioFiles: Int?
        let statusRows: Int?
        let usageRows: Int?
    }

    struct Usage: Codable {
        struct Hour: Codable, Identifiable { let at: String; let app: Int; let server: Int; let web: Int; var id: String { at } }
        struct Day: Codable, Identifiable {
            let date: String
            let app: Int
            let server: Int
            let web: Int
            let failed: Int
            var id: String { date }
        }
        struct ByUser: Codable, Identifiable {
            let email: String
            let count: Int
            let last: String
            let device: String?
            let ip: String?
            let userAgent: String?
            /// "web" rows are website visitors, one per address.
            var id: String { email + (ip ?? "") }
        }
        struct ByAction: Codable, Identifiable {
            let action: String
            let count: Int
            let failed: Int
            let avgMs: Int?
            var id: String { action }
        }
        struct Event: Codable {
            let at: String
            let email: String?
            let action: String
            let ok: Bool
            let latencyMs: Int?
            let device: String?
            let ip: String?
            let status: Int?
        }
        /// Request counts by action ("summarize", "chat", "speak", "whoami", "run_digest", and
        /// "digest" for pages the hourly server run summarized).
        let today: [String: Int]
        let week: [String: Int]
        let failedToday: Int
        let failedWeek: Int
        /// App requests this calendar month against the free plan's Edge Function allowance.
        let monthCalls: Int
        let monthLimit: Int
        let avgMsToday: Int?
        let usersToday: Int
        let hourly: [Hour]
        let daily: [Day]
        let byUser: [ByUser]
        let byAction: [ByAction]
        let recent: [Event]
    }

    struct User: Codable, Identifiable {
        let email: String
        let lastSignIn: String?
        let admin: Bool
        var id: String { email }
    }

    let runs: [Run]
    let workflow: [WorkflowRun]
    let database: Database
    let storage: Storage
    let usage: Usage
    let users: [User]
}
