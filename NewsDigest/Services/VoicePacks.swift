import Foundation

/// A Kokoro voice pack from sherpa-onnx's releases. Packs live in a folder shared with
/// Speak Partner (App Group `group.com.neuralsound.voicepacks`, `tts_models/<id>`), so a pack
/// either app has downloaded is used by both without downloading it again.
struct VoicePack: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let megabytes: Int
    let voices: [KokoroVoice]

    var url: URL { URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/\(id).tar.bz2")! }

    static let v019 = VoicePack(
        id: "kokoro-en-v0_19", name: "Kokoro v0.19",
        detail: "11 English voices. Speak Partner uses this one.",
        megabytes: 319,
        voices: [
            .init(sid: 0, name: "Default", accent: .us, female: true),
            .init(sid: 1, name: "Bella", accent: .us, female: true),
            .init(sid: 2, name: "Nicole", accent: .us, female: true),
            .init(sid: 3, name: "Sarah", accent: .us, female: true),
            .init(sid: 4, name: "Sky", accent: .us, female: true),
            .init(sid: 5, name: "Adam", accent: .us, female: false),
            .init(sid: 6, name: "Michael", accent: .us, female: false),
            .init(sid: 7, name: "Emma", accent: .uk, female: true),
            .init(sid: 8, name: "Isabella", accent: .uk, female: true),
            .init(sid: 9, name: "George", accent: .uk, female: false),
            .init(sid: 10, name: "Lewis", accent: .uk, female: false),
        ])

    /// Speaker ids 0–27 are the English voices; the rest of the pack is other languages.
    static let v10 = VoicePack(
        id: "kokoro-int8-multi-lang-v1_0", name: "Kokoro v1.0",
        detail: "28 English voices, newer and more natural. Smaller download.",
        megabytes: 132,
        voices: [
            "Alloy", "Aoede", "Bella", "Heart", "Jessica", "Kore", "Nicole", "Nova", "River", "Sarah", "Sky",
        ].enumerated().map { KokoroVoice(sid: $0.offset, name: $0.element, accent: .us, female: true) }
        + ["Adam", "Echo", "Eric", "Fenrir", "Liam", "Michael", "Onyx", "Puck", "Santa"]
            .enumerated().map { KokoroVoice(sid: 11 + $0.offset, name: $0.element, accent: .us, female: false) }
        + ["Alice", "Emma", "Isabella", "Lily"]
            .enumerated().map { KokoroVoice(sid: 20 + $0.offset, name: $0.element, accent: .uk, female: true) }
        + ["Daniel", "Fable", "George", "Lewis"]
            .enumerated().map { KokoroVoice(sid: 24 + $0.offset, name: $0.element, accent: .uk, female: false) })

    static let all = [v10, v019]
    static func with(id: String) -> VoicePack? { all.first { $0.id == id } }
}

struct KokoroVoice: Hashable {
    enum Accent: String { case us = "US", uk = "UK" }
    let sid: Int
    let name: String
    let accent: Accent
    let female: Bool

    var label: String { "\(name) (\(accent.rawValue), \(female ? "female" : "male"))" }
}

/// The voice picked in Settings, stored as "<pack id>:<speaker id>".
struct KokoroChoice: Hashable {
    static let key = "kokoroVoice"
    let pack: VoicePack
    let voice: KokoroVoice

    var tag: String { "\(pack.id):\(voice.sid)" }

    init(pack: VoicePack, voice: KokoroVoice) {
        self.pack = pack
        self.voice = voice
    }

    init?(tag: String) {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let pack = VoicePack.with(id: String(parts[0])), let sid = Int(parts[1]),
              let voice = pack.voices.first(where: { $0.sid == sid }) else { return nil }
        self.init(pack: pack, voice: voice)
    }

    /// The saved choice if its pack is on the phone, else the first voice of an installed pack.
    static var current: KokoroChoice? {
        if let tag = UserDefaults.standard.string(forKey: key), let c = KokoroChoice(tag: tag),
           VoicePacks.isInstalled(c.pack) { return c }
        // Bella is the voice Speak Partner's tests used and sounds good in both packs.
        return VoicePack.all.first(where: VoicePacks.isInstalled)
            .map { KokoroChoice(pack: $0, voice: $0.voices.first { $0.name == "Bella" } ?? $0.voices[0]) }
    }
}

/// Downloads, unpacks and deletes voice packs in the shared folder.
@MainActor
final class VoicePacks: ObservableObject {
    static let appGroup = "group.com.neuralsound.voicepacks"

    /// Download or unpack progress per pack id: 0…1 while downloading, nil once done.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var unpacking: Set<String> = []
    @Published private(set) var installed: Set<String> = []
    @Published var error: String?

    private var downloads: [String: PackDownload] = [:]

    init() { refresh() }

    func refresh() {
        installed = Set(VoicePack.all.filter(Self.isInstalled).map(\.id))
    }

    /// `<shared container>/tts_models`, or this app's own folder if the App Group is missing.
    nonisolated static var root: URL {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("tts_models", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true  // can be downloaded again
            try? dir.setResourceValues(values)
        }
        return dir
    }

    nonisolated static func folder(of pack: VoicePack) -> URL {
        root.appendingPathComponent(pack.id, isDirectory: true)
    }

    /// The pack's model file: quantised packs ship `model.int8.onnx` instead of `model.onnx`.
    nonisolated static func modelFile(of pack: VoicePack) -> URL? {
        let dir = folder(of: pack)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.first { $0.hasSuffix(".onnx") }.map { dir.appendingPathComponent($0) }
    }

    nonisolated static func isInstalled(_ pack: VoicePack) -> Bool {
        let dir = folder(of: pack)
        let fm = FileManager.default
        return modelFile(of: pack) != nil
            && fm.fileExists(atPath: dir.appendingPathComponent("voices.bin").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("tokens.txt").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("espeak-ng-data").path)
    }

    func isBusy(_ pack: VoicePack) -> Bool { progress[pack.id] != nil || unpacking.contains(pack.id) }

    func download(_ pack: VoicePack) {
        guard !isBusy(pack), !Self.isInstalled(pack) else { return refresh() }
        error = nil
        progress[pack.id] = 0
        let download = PackDownload(url: pack.url) { [weak self] fraction in
            Task { @MainActor in if self?.progress[pack.id] != nil { self?.progress[pack.id] = fraction } }
        }
        downloads[pack.id] = download
        Task {
            defer { downloads[pack.id] = nil }
            do {
                let archive = try await download.run()
                progress[pack.id] = nil
                unpacking.insert(pack.id)
                defer { unpacking.remove(pack.id) }
                try await Task.detached(priority: .userInitiated) {
                    defer { try? FileManager.default.removeItem(at: archive) }
                    try Self.install(archive: archive, pack: pack)
                }.value
            } catch {
                progress[pack.id] = nil
                if (error as? URLError)?.code != .cancelled {
                    self.error = "\(pack.name) couldn't be downloaded: \(error.localizedDescription)"
                }
            }
            refresh()
        }
    }

    func cancel(_ pack: VoicePack) {
        downloads[pack.id]?.cancel()
        progress[pack.id] = nil
    }

    func delete(_ pack: VoicePack) {
        try? FileManager.default.removeItem(at: Self.folder(of: pack))
        refresh()
    }

    /// Unpacks into a staging folder next to the packs, then moves the pack folder into place
    /// in one step, so neither app ever sees a half-unpacked pack.
    private nonisolated static func install(archive: URL, pack: VoicePack) throws {
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try TarBz2.extract(archive, to: staging)
        let unpacked = staging.appendingPathComponent(pack.id, isDirectory: true)
        guard fm.fileExists(atPath: unpacked.path) else { throw TarBz2.Failure("The download has no \(pack.id) folder.") }
        // The other app may have finished the same pack meanwhile; keep theirs.
        if isInstalled(pack) { return }
        try? fm.removeItem(at: folder(of: pack))
        try fm.moveItem(at: unpacked, to: folder(of: pack))
    }
}

/// One file download with progress, kept in a temporary file the caller then owns.
private final class PackDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(url: URL, onProgress: @escaping (Double) -> Void) {
        self.url = url
        self.onProgress = onProgress
    }

    func run() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func cancel() { session?.invalidateAndCancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        if expected > 0 { onProgress(Double(written) / Double(expected)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so move it first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar.bz2")
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            guard status == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        session.finishTasksAndInvalidate()
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Streams a .tar.bz2 to disk: bzip2 from the system library, and a small tar reader for the
/// plain files and folders sherpa-onnx's packs contain.
enum TarBz2 {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func extract(_ archive: URL, to destination: URL) throws {
        guard let input = fopen(archive.path, "rb") else { throw Failure("Can't open the download.") }
        defer { fclose(input) }
        var bzError: Int32 = 0
        guard let bz = BZ2_bzReadOpen(&bzError, input, 0, 0, nil, 0), bzError == BZ_OK else {
            throw Failure("The download isn't a bzip2 file.")
        }
        defer { BZ2_bzReadClose(&bzError, bz) }

        let tar = TarReader(destination: destination)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = buffer.withUnsafeMutableBytes { BZ2_bzRead(&bzError, bz, $0.baseAddress, Int32($0.count)) }
            if bzError != BZ_OK && bzError != BZ_STREAM_END { throw Failure("The download is damaged (bzip2 error \(bzError)).") }
            if n > 0 { try buffer.withUnsafeBytes { try tar.feed($0.prefix(Int(n))) } }
            if bzError == BZ_STREAM_END || tar.finished { break }
        }
        try tar.close()
    }

    /// Feed it the tar bytes in any chunk sizes.
    private final class TarReader {
        let destination: URL
        private(set) var finished = false
        private var header = Data()
        private var file: FileHandle?
        private var remaining = 0     // bytes of the current entry's data still to come
        private var padding = 0       // zero bytes after it, up to the next 512-byte block
        private var collecting: Data? // a long-name or pax entry, read into memory
        private var collectingType: UInt8 = 0
        private var nextName: String?

        init(destination: URL) { self.destination = destination }

        func feed(_ bytes: UnsafeRawBufferPointer.SubSequence) throws {
            var bytes = bytes
            while !bytes.isEmpty, !finished {
                if remaining > 0 {
                    let take = min(remaining, bytes.count)
                    let chunk = Data(bytes.prefix(take))
                    if collecting != nil { collecting!.append(chunk) } else { try file?.write(contentsOf: chunk) }
                    remaining -= take
                    bytes = bytes.dropFirst(take)
                    if remaining == 0 { try endEntry() }
                } else if padding > 0 {
                    let take = min(padding, bytes.count)
                    padding -= take
                    bytes = bytes.dropFirst(take)
                } else {
                    let take = min(512 - header.count, bytes.count)
                    header.append(Data(bytes.prefix(take)))
                    bytes = bytes.dropFirst(take)
                    if header.count == 512 {
                        try startEntry(header)
                        header.removeAll(keepingCapacity: true)
                    }
                }
            }
        }

        func close() throws {
            try file?.close()
            file = nil
        }

        private func startEntry(_ h: Data) throws {
            if h.allSatisfy({ $0 == 0 }) { finished = true; return }
            let size = Self.octal(h[124..<136])
            let type = h[156]
            var name = Self.string(h[0..<100])
            if h[257..<262] == Data("ustar".utf8) {
                let prefix = Self.string(h[345..<500])
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            if let long = nextName { name = long }
            nextName = nil
            remaining = size
            padding = (512 - size % 512) % 512

            switch type {
            case UInt8(ascii: "L"), UInt8(ascii: "x"):  // GNU long name, pax header
                collecting = Data()
                collectingType = type
            case UInt8(ascii: "5"):
                try FileManager.default.createDirectory(at: try path(name), withIntermediateDirectories: true)
            case UInt8(ascii: "0"), 0:
                let url = try path(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                file = try FileHandle(forWritingTo: url)
            default:
                break  // links and other entries: skipped (the packs have none)
            }
            if remaining == 0 { try endEntry() }
        }

        private func endEntry() throws {
            try file?.close()
            file = nil
            guard let data = collecting else { return }
            collecting = nil
            if collectingType == UInt8(ascii: "L") {
                nextName = Self.string(data[...])
            } else if let text = String(data: data, encoding: .utf8) {
                // Pax records: "<length> key=value\n"
                for line in text.split(separator: "\n") {
                    if let range = line.range(of: " path=") { nextName = String(line[range.upperBound...]) }
                }
            }
        }

        /// The entry's place under the destination; refuses names that would leave it.
        private func path(_ name: String) throws -> URL {
            let parts = name.split(separator: "/").filter { $0 != "." && !$0.isEmpty }
            guard !parts.contains("..") else { throw Failure("The download has an unsafe file name.") }
            return parts.reduce(destination) { $0.appendingPathComponent(String($1)) }
        }

        private static func string(_ d: Data) -> String {
            String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
        }

        private static func octal(_ d: Data) -> Int {
            Int(string(d).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
        }
    }
}
