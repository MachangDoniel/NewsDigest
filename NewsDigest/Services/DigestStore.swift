import Foundation
import Supabase
import UIKit

/// Talks to Supabase (read-only) and keeps an on-disk cache so the archive works offline.
@MainActor
final class DigestStore: ObservableObject {
    enum AuthState { case unconfigured, signedOut, signedIn }

    @Published private(set) var authState: AuthState = .unconfigured
    /// The signed-in account is in the server's `admins` table. Only decides what the app shows;
    /// the server checks again on every admin request.
    @Published private(set) var isAdmin = false
    @Published private(set) var dates: [String] = []
    @Published private(set) var bookmarks: [SavedItem] = []
    /// Which papers the server has for each recent date; nil until it has answered once.
    @Published private(set) var coverage: [String: Set<Paper>]?

    private var client: SupabaseClient?
    private var cache: [String: [Digest]] = [:]       // date -> digests
    private var statusCache: [String: [RunStatus]] = [:]
    private let decoder = JSONDecoder()

    static let urlKey = "supabaseURL"
    static let anonKeyKey = "supabaseAnonKey"

    init() {
        cache = DiskCache.load([String: [Digest]].self, name: "digests") ?? [:]
        dates = cache.keys.sorted(by: >)
        bookmarks = DiskCache.load([SavedItem].self, name: "bookmarks") ?? []
        configureFromStorage()
    }

    // MARK: - Setup & auth

    /// A project entered in Settings wins; otherwise the built-in one from AppConfig.
    var supabaseURL: String {
        UserDefaults.standard.string(forKey: Self.urlKey).flatMap { $0.isEmpty ? nil : $0 } ?? AppConfig.supabaseURL
    }
    private var supabaseKey: String {
        Keychain.get(Self.anonKeyKey).flatMap { $0.isEmpty ? nil : $0 } ?? AppConfig.supabasePublishableKey
    }
    var usesCustomProject: Bool { !(UserDefaults.standard.string(forKey: Self.urlKey) ?? "").isEmpty }

    func configure(url: String, anonKey: String) {
        UserDefaults.standard.set(url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.urlKey)
        Keychain.set(anonKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.anonKeyKey)
        configureFromStorage()
    }

    func useDefaultProject() {
        UserDefaults.standard.removeObject(forKey: Self.urlKey)
        Keychain.set(nil, for: Self.anonKeyKey)
        configureFromStorage()
    }

    private func configureFromStorage() {
        let key = supabaseKey
        guard let url = URL(string: supabaseURL), url.host != nil, !key.isEmpty else {
            client = nil
            authState = .unconfigured
            return
        }
        let client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: .init(auth: .init(emitLocalSessionAsInitialSession: true))
        )
        self.client = client
        authState = client.auth.currentSession == nil ? .signedOut : .signedIn
        Task { [weak self] in
            for await (event, session) in client.auth.authStateChanges {
                self?.authState = session == nil ? .signedOut : .signedIn
                if event == .initialSession || event == .signedIn || event == .signedOut { await self?.refreshAdmin() }
            }
        }
    }

    func signIn(email: String, password: String) async throws {
        guard let client else { throw StoreError.notConfigured }
        try await client.auth.signIn(email: email, password: password)
        authState = .signedIn
    }

    /// Calls a Supabase Edge Function as the signed-in user (e.g. `summarize`).
    func invokeFunction<T: Decodable, B: Encodable>(_ name: String, body: B) async throws -> T {
        guard let client else { throw StoreError.notConfigured }
        guard authState == .signedIn else { throw StoreError.signedOut }
        // `session` refreshes an expired access token first; the function rejects stale ones (401).
        let session = try await client.auth.session
        return try await withTimeout(seconds: 100) {
            try await client.functions.invoke(
                name,
                options: FunctionInvokeOptions(headers: ["Authorization": "Bearer \(session.accessToken)", "X-Device": Self.device], body: body)
            )
        }
    }

    /// Sent with each request so the Admin screen can show what kind of device is asking.
    private static let device: String = {
        #if targetEnvironment(simulator)
        "Simulator"
        #else
        UIDevice.current.model
        #endif
    }()

    private struct RunDigestRequest: Encodable {
        let action = "run_digest"
        var paper: String?
        var date: String?
        var force = false
    }
    private struct RunDigestResponse: Decodable { let ok: Bool; let message: String? }

    /// Starts the server digest now instead of waiting for the next hourly run (admins only).
    /// `date` fills in a missed day; `force` rebuilds a digest that already exists.
    /// The `summarize` function triggers the GitHub workflow, so no GitHub token lives on the phone.
    func runDigestNow(paper: Paper? = nil, date: String? = nil, force: Bool = false) async throws -> (ok: Bool, message: String) {
        let request = RunDigestRequest(paper: paper?.rawValue, date: date, force: force)
        let res: RunDigestResponse = try await invokeFunction("summarize", body: request)
        return (res.ok, res.message ?? (res.ok ? "Digest started." : "Couldn't start the digest."))
    }

    // MARK: - Admin

    private struct ActionRequest: Encodable { let action: String }
    private struct WhoAmI: Decodable { let admin: Bool }

    private func refreshAdmin() async {
        guard authState == .signedIn else { isAdmin = false; return }
        let me: WhoAmI? = try? await invokeFunction("summarize", body: ActionRequest(action: "whoami"))
        isAdmin = me?.admin ?? false
    }

    func adminOverview() async throws -> AdminOverview {
        try await invokeFunction("summarize", body: ActionRequest(action: "admin_overview"))
    }

    private struct PingResponse: Decodable { let ok: Bool; let pingMs: Int }

    /// Times one small database query on the server; nil if it failed.
    func adminPing() async throws -> Int? {
        let res: PingResponse = try await invokeFunction("summarize", body: ActionRequest(action: "admin_ping"))
        return res.ok ? res.pingMs : nil
    }

    private struct OkResponse: Decodable { let ok: Bool; let message: String? }

    /// Empties the usage log. Digests are not touched.
    func adminResetUsage() async throws {
        let res: OkResponse = try await invokeFunction("summarize", body: ActionRequest(action: "admin_reset_usage"))
        if !res.ok { throw StoreError.server(res.message ?? "Couldn't reset the usage log.") }
    }

    func signOut() async {
        try? await client?.auth.signOut()
        authState = client == nil ? .unconfigured : .signedOut
        isAdmin = false
    }

    // MARK: - Reading

    func cached(_ date: String) -> [Digest] { cache[date] ?? [] }
    func cachedStatus(_ date: String) -> [RunStatus] { statusCache[date] ?? [] }

    /// Fetches one day's digests and run status. Falls back to the cache when offline.
    func load(_ date: String) async throws -> [Digest] {
        guard let client else { throw StoreError.notConfigured }
        async let digestData = client.from("digests").select().eq("date", value: date).execute().data
        async let statusData = client.from("run_status").select().eq("date", value: date).execute().data
        let digests = try decoder.decode([Digest].self, from: try await digestData)
            .sorted { $0.paper.rawValue < $1.paper.rawValue }
        statusCache[date] = (try? decoder.decode([RunStatus].self, from: try await statusData)) ?? []
        if !digests.isEmpty {
            cache[date] = digests
            if !dates.contains(date) { dates = (dates + [date]).sorted(by: >) }
            persist()
        }
        return digests
    }

    /// Pulls the last ~90 days (used by the archive + search) and caches them.
    func refreshArchive() async throws {
        guard let client else { throw StoreError.notConfigured }
        let data = try await client.from("digests").select()
            .order("date", ascending: false)
            .limit(180)
            .execute().data
        let all = try decoder.decode([Digest].self, from: data)
        var byDate: [String: [Digest]] = [:]
        for d in all { byDate[d.date, default: []].append(d) }
        for (k, v) in byDate { cache[k] = v.sorted { $0.paper.rawValue < $1.paper.rawValue } }
        dates = cache.keys.sorted(by: >)
        persist()
        await refreshCoverage()
    }

    // MARK: - Missing papers

    private static let coverageDays = 30
    private static let watchedDays = 7
    private struct DigestKey: Decodable { let date: String; let paper: Paper }

    /// `count` days before today in Dhaka, newest first. Today isn't included: it may not be out yet.
    private func pastDays(_ count: Int) -> [String] {
        (1...count).compactMap { Calendar.dhaka.date(byAdding: .day, value: -$0, to: .now) }.map(DigestDate.string)
    }

    /// Asks only for dates and papers, so it's cheap enough to run each time the app opens.
    func refreshCoverage() async {
        guard let client, let since = pastDays(Self.coverageDays).last else { return }
        async let digestData = client.from("digests").select("date,paper").gte("date", value: since).execute().data
        async let statusData = client.from("run_status").select().gte("date", value: since).execute().data
        guard let keys = try? decoder.decode([DigestKey].self, from: try await digestData) else { return }
        var saved: [String: Set<Paper>] = [:]
        for key in keys { saved[key.date, default: []].insert(key.paper) }
        coverage = saved
        if let statuses = try? decoder.decode([RunStatus].self, from: try await statusData) {
            statusCache.merge(Dictionary(grouping: statuses, by: \.date)) { _, new in new }
        }
    }

    /// Papers the server doesn't have for this date. Empty for today and for dates too old to check.
    func missingPapers(_ date: String) -> [Paper] {
        guard let coverage, pastDays(Self.coverageDays).contains(date) else { return [] }
        return Paper.allCases.filter { !(coverage[date] ?? []).contains($0) }
    }

    /// Missing papers in the last week: the ones the server is still retrying. Shown on the Archive tab.
    var missingThisWeek: Int { pastDays(Self.watchedDays).reduce(0) { $0 + missingPapers($1).count } }

    /// Every date to list in the Archive, including recent ones with a paper missing.
    var archiveDates: [String] {
        guard coverage != nil else { return dates }
        return Set(dates).union(pastDays(Self.coverageDays)).sorted(by: >)
    }

    func search(_ query: String) -> [SavedItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        var out: [SavedItem] = []
        for date in dates {
            for digest in cache[date] ?? [] {
                for section in digest.sections {
                    for item in section.items {
                        let hay = ([item.headline] + item.bullets + item.keyFacts).joined(separator: " ").lowercased()
                        if hay.contains(q) {
                            out.append(SavedItem(date: date, paper: digest.paper, category: section.category, item: item))
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: - Bookmarks

    func isBookmarked(_ item: SavedItem) -> Bool { bookmarks.contains { $0.id == item.id } }

    func toggleBookmark(_ item: SavedItem) {
        if let i = bookmarks.firstIndex(where: { $0.id == item.id }) {
            bookmarks.remove(at: i)
        } else {
            bookmarks.insert(item, at: 0)
        }
        DiskCache.save(bookmarks, name: "bookmarks")
    }

    private func persist() {
        // Keep the newest 120 days on disk.
        let keep = Set(cache.keys.sorted(by: >).prefix(120))
        cache = cache.filter { keep.contains($0.key) }
        DiskCache.save(cache, name: "digests")
    }
}

/// Fails with `StoreError.timedOut` if `operation` takes longer than `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw StoreError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

enum StoreError: LocalizedError {
    case notConfigured, signedOut, timedOut
    case server(String)
    var errorDescription: String? {
        switch self {
        case .server(let message): message
        case .notConfigured: "Connect your Supabase project in Settings first."
        case .signedOut: "Sign in on the Today tab to use ✨ Summarize."
        case .timedOut: "The AI took too long to answer."
        }
    }
}

enum DiskCache {
    private static func url(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).json")
    }

    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }
}
