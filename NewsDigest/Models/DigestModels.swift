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

    var isHigh: Bool { bcsRelevance == "high" }
}

struct Mcq: Codable, Hashable {
    let question: String
    let options: [String]
    let answer: String
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
