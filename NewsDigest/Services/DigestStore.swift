import Foundation
import Supabase

/// Talks to Supabase (read-only) and keeps an on-disk cache so the archive works offline.
@MainActor
final class DigestStore: ObservableObject {
    enum AuthState { case unconfigured, signedOut, signedIn }

    @Published private(set) var authState: AuthState = .unconfigured
    @Published private(set) var dates: [String] = []
    @Published private(set) var bookmarks: [SavedItem] = []

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

    var supabaseURL: String { UserDefaults.standard.string(forKey: Self.urlKey) ?? "" }

    func configure(url: String, anonKey: String) {
        UserDefaults.standard.set(url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.urlKey)
        Keychain.set(anonKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.anonKeyKey)
        configureFromStorage()
    }

    private func configureFromStorage() {
        guard let url = URL(string: supabaseURL), url.host != nil, let key = Keychain.get(Self.anonKeyKey), !key.isEmpty else {
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
            for await (_, session) in client.auth.authStateChanges {
                self?.authState = session == nil ? .signedOut : .signedIn
            }
        }
    }

    func signIn(email: String, password: String) async throws {
        guard let client else { throw StoreError.notConfigured }
        try await client.auth.signIn(email: email, password: password)
        authState = .signedIn
    }

    func signOut() async {
        try? await client?.auth.signOut()
        authState = client == nil ? .unconfigured : .signedOut
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

enum StoreError: LocalizedError {
    case notConfigured
    var errorDescription: String? { "Connect your Supabase project in Settings first." }
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
