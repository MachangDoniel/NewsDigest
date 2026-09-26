import Foundation

/// Built-in Supabase project, so the app only asks for your email and password.
/// Safe to commit: the publishable key can only read what row-level security allows,
/// which is nothing until a user signs in (see supabase/schema.sql).
/// Forks: replace these with your own project, or change the project in Settings.
enum AppConfig {
    static let supabaseURL = "https://utjluiipjiznedsglqsm.supabase.co"
    static let supabasePublishableKey = "sb_publishable_30UE1vzeEt2MzIR3ufVWYw_lr0ZQm7V"
}
