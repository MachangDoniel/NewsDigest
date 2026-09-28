import AVFoundation
import CryptoKit
import MediaPlayer
import NaturalLanguage

/// Reads a page's stories aloud, one story at a time. Uses the Gemini voice through the
/// `speak` action of the `summarize` Edge Function, which makes each section once and keeps it,
/// and falls back to Apple's built-in voices when that isn't available. Back/forward jump 5 seconds
/// within the section being read, from the app or from the lock screen and headphones.
@MainActor
final class SpeechReader: NSObject, ObservableObject,
    @preconcurrency AVSpeechSynthesizerDelegate, @preconcurrency AVAudioPlayerDelegate {
    static let voiceKey = "readAloudVoice"
    /// Choices for Settings. "gemini" goes through the server; "apple" stays on the phone.
    static let voices: [(id: String, label: String)] = [
        ("gemini", "Gemini voice"),
        ("apple", "Apple voice (free, offline)"),
    ]

    @Published private(set) var stories: [PaperStory] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    /// True while Apple's voice reads: back/forward then move by sentence instead of 5 seconds.
    @Published private(set) var bySentence = false
    /// Why reading can't go on, e.g. no Apple voice for the language (usually Bangla).
    @Published private(set) var problem: String?
    /// Shown when the natural voice isn't available and Apple's voice is used instead.
    @Published private(set) var note: String?
    @Published var rate: Float = UserDefaults.standard.object(forKey: "speechRate") as? Float ?? 1.0 {
        didSet {
            UserDefaults.standard.set(rate, forKey: "speechRate")
            if let player { player.rate = rate } else if isPlaying { stepSentence(by: 0) }
        }
    }

    static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var isActive: Bool { !stories.isEmpty }
    var current: PaperStory? { stories.indices.contains(index) ? stories[index] : nil }

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var chunks: [String] = []
    private var chunk = 0
    /// Only output we last started may advance the queue; stopped or stale ones are ignored.
    private var token = UUID()
    private var utterance: AVSpeechUtterance?
    /// Apple's voice: where in the section the current utterance began, and the word being spoken
    /// (UTF-16 offsets into the section), for moving by sentence.
    private var appleStart = 0
    private var appleSpoken = 0
    private var fetches: [String: Task<Data?, Never>] = [:]
    /// After the Gemini voice fails, Apple's voice reads until this time, then Gemini is tried again.
    private var naturalOffUntil: Date?
    private weak var store: DigestStore?
    private var title = ""
    private var commandsSet = false

    override init() {
        super.init()
        synth.delegate = self
    }

    private var voiceSetting: String { UserDefaults.standard.string(forKey: Self.voiceKey) ?? "gemini" }
    private var useNatural: Bool { voiceSetting != "apple" && (naturalOffUntil ?? .distantPast) <= .now }

    // MARK: - Controls

    func start(_ stories: [PaperStory], title: String, store: DigestStore) {
        self.stories = stories.filter { !$0.headline.isEmpty || !$0.body.isEmpty }
        self.title = title
        self.store = store
        note = nil
        guard !self.stories.isEmpty else { return }
        Self.pruneCache()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        setUpRemoteCommands()
        play(story: 0)
    }

    func togglePause() { isPlaying ? pause() : resume() }

    func pause() {
        guard isPlaying else { return }
        if let player { player.pause() } else { synth.pauseSpeaking(at: .word) }
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard isActive, !isPlaying else { return }
        if let player {
            isPlaying = true
            player.play()
            updateNowPlaying()
        } else if synth.isPaused {
            isPlaying = true
            synth.continueSpeaking()
            updateNowPlaying()
        } else {
            speakChunk()
        }
    }

    private func next() {
        guard isActive else { return }
        if index + 1 < stories.count { play(story: index + 1) } else { stop() }
    }

    /// Back/forward: 5 seconds within the section with the Gemini voice. Apple's voice can't jump
    /// by time, so there it moves to the previous or next sentence.
    func seek(by seconds: TimeInterval) {
        guard isActive else { return }
        if let player {
            player.currentTime = min(max(0, player.currentTime + seconds), max(0, player.duration - 0.1))
            updateNowPlaying()
        } else {
            stepSentence(by: seconds < 0 ? -1 : 1)
        }
    }

    /// Apple's voice: restarts at the sentence `delta` sentences away from the one being spoken
    /// (0 = this one). Before the first sentence it goes to the previous section's last sentence;
    /// past the last one, to the next section.
    private func stepSentence(by delta: Int) {
        guard chunks.indices.contains(chunk) else { return }
        let starts = Self.sentenceStarts(chunks[chunk])
        let current = starts.lastIndex { $0 <= appleSpoken } ?? 0
        let target = current + delta
        if target < 0 {
            guard chunk > 0 else { return speakChunk(from: 0) }
            chunk -= 1
            speakChunk(from: Self.sentenceStarts(chunks[chunk]).last ?? 0)
        } else if target >= starts.count {
            advance()
        } else {
            speakChunk(from: starts[target])
        }
    }

    /// Where each sentence starts (UTF-16 offsets): after "।", or after ".", "?", "!" followed by a
    /// space (so "3.5" stays whole), and after line breaks.
    private static func sentenceStarts(_ text: String) -> [Int] {
        let ns = text as NSString
        let isSpace = { (c: unichar) in c == 0x20 || c == 0x0A || c == 0x09 || c == 0xA0 }
        var starts = [0]
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            let next = i + 1 < ns.length ? ns.character(at: i + 1) : 0x20
            if c == 0x0964 || c == 0x0A || ([0x2E, 0x3F, 0x21].contains(c) && isSpace(next)) {
                var j = i + 1
                while j < ns.length, isSpace(ns.character(at: j)) { j += 1 }
                if j < ns.length, j > starts.last! { starts.append(j) }
                i = j
            } else {
                i += 1
            }
        }
        return starts
    }

    func stop() {
        stopOutput()
        fetches.values.forEach { $0.cancel() }
        fetches = [:]
        stories = []
        isPlaying = false
        problem = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Speaking

    private func play(story: Int) {
        index = story
        chunks = Self.chunks(of: stories[story])
        chunk = 0
        speakChunk()
    }

    /// Headline first, then the body in sections of about a paragraph. Gemini takes roughly
    /// 0.4 s per second of audio, so short sections start quickly and the next is ready in time.
    private static func chunks(of story: PaperStory) -> [String] {
        let sentences = story.body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap { $0.count > 600 ? sentencesOf($0) : [$0] }
        var out: [String] = story.headline.isEmpty ? [] : [story.headline]
        var piece = ""
        for p in sentences {
            if !piece.isEmpty, piece.count + p.count > 450 { out.append(piece); piece = "" }
            piece += piece.isEmpty ? p : "\n" + p
        }
        if !piece.isEmpty { out.append(piece) }
        return out
    }

    /// Splits a long paragraph after "।", ".", "?" or "!".
    private static func sentencesOf(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "।.?!".contains(ch), current.count > 40 {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    private func stopOutput() {
        token = UUID()
        utterance = nil
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
    }

    /// Reads the current section; `offset` (Apple's voice only) starts partway, at a sentence.
    private func speakChunk(from offset: Int = 0) {
        stopOutput()
        guard chunks.indices.contains(chunk) else { return next() }
        let text = chunks[chunk]
        let lang = Self.language(of: stories[index].headline + " " + text)
        isPlaying = true
        updateNowPlaying()
        guard useNatural else { return speakWithApple(text, lang: lang, from: offset) }

        let token = token
        Task {
            let data = await audio(for: text)
            guard token == self.token else { return }
            prefetchNext()
            guard let data, let player = try? AVAudioPlayer(data: data) else {
                return speakWithApple(text, lang: lang)
            }
            player.delegate = self
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
            self.player = player
            bySentence = false
            if isPlaying { player.play() }  // paused while loading: resume() starts it
        }
    }

    private func speakWithApple(_ text: String, lang: String, from offset: Int = 0) {
        bySentence = true
        guard let voice = Self.appleVoice(for: lang) else {
            problem = "This iPhone has no voice for this language. Add one in Settings → Accessibility → Spoken Content → Voices."
            pause()
            return
        }
        problem = nil
        let start = min(max(0, offset), (text as NSString).length)
        appleStart = start
        appleSpoken = start
        let u = AVSpeechUtterance(string: (text as NSString).substring(from: start))
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * rate
        u.postUtteranceDelay = chunk == 0 ? 0.5 : 0.25  // a beat after the headline
        utterance = u
        synth.speak(u)
        isPlaying = true
    }

    private func advance() {
        chunk += 1
        speakChunk()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        guard utterance === self.utterance else { return }
        appleSpoken = appleStart + range.location
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish finished: AVSpeechUtterance) {
        guard finished === utterance else { return }
        advance()
    }

    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        guard finished === player else { return }
        player = nil
        advance()
    }

    // MARK: - Natural voice

    /// The Gemini audio for a section: from this phone's cache, a fetch already on its way, or the
    /// server (which sends its saved copy, or makes the audio once and saves it).
    private func audio(for text: String) async -> Data? {
        let key = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = Self.cacheDir.appendingPathComponent(key + ".wav")
        if let data = try? Data(contentsOf: file) { return data }
        if let running = fetches[key] { return await running.value }

        guard let store, store.authState == .signedIn else {
            fallBack("Sign in on the Today tab for the Gemini voice. Using Apple's voice for now.", for: 60)
            return nil
        }
        let task = Task<Data?, Never> { [weak self] in
            // Gemini's free tier allows only a few voice requests a minute. When it's busy,
            // wait as long as it asks and try again rather than giving up on the voice.
            for attempt in 0..<3 {
                do {
                    let res: SpeakResponse = try await store.invokeFunction("summarize", body: SpeakRequest(text: text))
                    if res.ok, let link = res.url.flatMap(URL.init(string:)) {
                        let (data, response) = try await URLSession.shared.data(from: link)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { break }
                        try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
                        try? data.write(to: file)
                        self?.note = nil
                        return data
                    }
                    switch res.reason {
                    case "busy" where attempt < 2:
                        let wait = min(max(res.retryAfter ?? 10, 3), 30)
                        self?.note = "The Gemini voice is busy. Continuing in \(Int(wait)) seconds…"
                        try await Task.sleep(for: .seconds(wait))
                        continue
                    case "busy":
                        self?.fallBack("The Gemini voice is busy. Using Apple's voice for a minute.", for: 60)
                    case "quota":
                        self?.fallBack("The Gemini voice is out of quota for today. Using Apple's voice.", for: 30 * 60)
                    default:
                        self?.fallBack((res.message ?? "The Gemini voice isn't available.") + " Using Apple's voice for a minute.", for: 60)
                    }
                } catch {
                    if !Task.isCancelled { self?.fallBack("The Gemini voice couldn't be reached. Using Apple's voice for a minute.", for: 60) }
                }
                break
            }
            return nil
        }
        fetches[key] = task
        let data = await task.value
        fetches[key] = nil
        return data
    }

    /// Fetches the next two sections while this one plays, one at a time so the requests
    /// don't pile up against Gemini's per-minute limit.
    private func prefetchNext() {
        guard useNatural else { return }
        var upcoming = Array(chunks.dropFirst(chunk + 1))
        if stories.indices.contains(index + 1) { upcoming += Self.chunks(of: stories[index + 1]) }
        let next = Array(upcoming.prefix(2))
        Task {
            for text in next where useNatural { _ = await audio(for: text) }
        }
    }

    /// Reads with Apple's voice for a while, then tries Gemini again.
    private func fallBack(_ message: String, for seconds: TimeInterval) {
        naturalOffUntil = .now.addingTimeInterval(seconds)
        note = message
    }

    private struct SpeakRequest: Encodable {
        let action = "speak"
        let text: String
    }
    private struct SpeakResponse: Decodable {
        let ok: Bool
        let url: String?
        let reason: String?
        let retryAfter: Double?
        let message: String?
    }

    private static let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("speech", isDirectory: true)

    /// The phone only keeps audio for a couple of days; the server keeps its own copy.
    private static func pruneCache() {
        let fm = FileManager.default
        let cutoff = Date.now.addingTimeInterval(-2 * 86_400)
        let files = (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: file) }
        }
    }

    // MARK: - Voices

    /// "bn" for Bangla, otherwise "en".
    private static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(500)))
        return recognizer.dominantLanguage == .bengali ? "bn" : "en"
    }

    /// The best installed Apple voice for the language, preferring enhanced and premium voices.
    private static func appleVoice(for lang: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        let region = Locale.current.region?.identifier ?? ""
        return voices.max { a, b in
            (a.quality.rawValue, a.language.hasSuffix(region) ? 1 : 0) < (b.quality.rawValue, b.language.hasSuffix(region) ? 1 : 0)
        }
    }

    // MARK: - Lock screen and headphones

    private func setUpRemoteCommands() {
        guard !commandsSet else { return }
        commandsSet = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePause(); return .success }
        center.skipForwardCommand.preferredIntervals = [5]
        center.skipBackwardCommand.preferredIntervals = [5]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.seek(by: 5); return .success }
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.seek(by: -5); return .success }
    }

    private func updateNowPlaying() {
        guard let current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.headline.isEmpty ? "Story \(index + 1)" : current.headline,
            MPMediaItemPropertyArtist: title,
            MPMediaItemPropertyAlbumTrackNumber: index + 1,
            MPMediaItemPropertyAlbumTrackCount: stories.count,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }

    deinit {
        let center = MPRemoteCommandCenter.shared()
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipForwardCommand, center.skipBackwardCommand]
            .forEach { $0.removeTarget(nil) }
    }
}
