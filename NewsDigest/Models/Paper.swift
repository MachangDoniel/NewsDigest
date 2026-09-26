import SwiftUI

enum Paper: String, CaseIterable, Identifiable, Codable {
    case dailystar
    case prothomalo

    var id: String { rawValue }

    var name: String {
        switch self {
        case .dailystar: "The Daily Star"
        case .prothomalo: "Prothom Alo"
        }
    }

    var shortName: String {
        switch self {
        case .dailystar: "Daily Star"
        case .prothomalo: "প্রথম আলো"
        }
    }

    var color: Color {
        switch self {
        case .dailystar: Color(red: 0.0, green: 0.36, blue: 0.62)
        case .prothomalo: Color(red: 0.80, green: 0.10, blue: 0.13)
        }
    }

    var monogram: String {
        switch self {
        case .dailystar: "DS"
        case .prothomalo: "প্র"
        }
    }

    /// Hosts the in-app reader keeps inside the WebView (login pages included).
    var hosts: [String] {
        switch self {
        case .dailystar: ["thedailystar.net"]
        case .prothomalo: ["prothomalo.com", "eprothomalo.com"]
        }
    }

    func editionURL(for date: Date = .now) -> URL {
        let f = DateFormatter()
        f.timeZone = .dhaka
        f.dateFormat = "dd/MM/yyyy"
        let d = f.string(from: date)
        switch self {
        case .dailystar: return URL(string: "https://epaper.thedailystar.net/Home/DIndex?eid=1&edate=\(d)")!
        case .prothomalo: return URL(string: "https://epaper.prothomalo.com/Home/DIndex?eid=1&edate=\(d)")!
        }
    }
}

extension TimeZone {
    static let dhaka = TimeZone(identifier: "Asia/Dhaka")!
}

extension Calendar {
    static let dhaka: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .dhaka
        return c
    }()
}
