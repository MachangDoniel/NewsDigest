import Foundation

/// Built-in Supabase project, so the app only asks for your email and password.
/// The values come from Supabase.xcconfig, which is kept out of git (see Supabase.example.xcconfig).
/// The publishable key can only read what row-level security allows,
/// which is the digests and their run status, read-only (see supabase/schema.sql).
/// A different project can also be entered in Settings.
enum AppConfig {
    static let supabaseURL = info("SupabaseHost").map { "https://\($0)" } ?? ""
    static let webAppURL = URL(string: "https://newsdigest.ai.studio/")!
    static let supabasePublishableKey = info("SupabasePublishableKey") ?? ""

    private static func info(_ key: String) -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
