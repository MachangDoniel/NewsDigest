import AVFoundation
import CryptoKit
import MediaPlayer
import NaturalLanguage

/// Reads a page's stories aloud, one story at a time. Uses the Gemini voice through the
/// `speak` action of the `summarize` Edge Function, which makes each section once and keeps it,
/// and falls back to Apple's built-in voices when that isn't available. Back/forward skip between stories, from the app or from the lock
/// screen and headphones.
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
    /// Why reading can't go on, e.g. no Apple voice for the language (usually Bangla).
    @Published private(set) var problem: String?
    /// Shown when the natural voice isn't available and Apple's voice is used instead.
    @Published private(set) var note: String?
    @Published var rate: Float = UserDefaults.standard.object(forKey: "speechRate") as? Float ?? 1.0 {
        didSet {
            UserDefaults.standard.set(rate, forKey: "speechRate")
            if let player { player.rate = rate } else if isPlaying { speakChunk() }
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
    private var fetches: [String: Task<Data?, Never>] = [:]
    /// Set after the natural voice fails, so the rest of this session doesn't wait on it.
    private var naturalOff = false
    private weak var store: DigestStore?
    private var title = ""
    private var commandsSet = false

    override init() {
        super.init()
        synth.delegate = self
    }

    private var voiceSetting: String { UserDefaults.standard.string(forKey: Self.voiceKey) ?? "gemini" }
    private var useNatural: Bool { voiceSetting != "apple" && !naturalOff }

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

    func next() {
        guard isActive else { return }
        if index + 1 < stories.count { play(story: index + 1) } else { stop() }
    }

    /// Back to the start of this story, or to the previous one when already at its start.
    func previous() {
        guard isActive else { return }
        play(story: chunk == 0 && index > 0 ? index - 1 : index)
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

    private func speakChunk() {
        stopOutput()
        guard chunks.indices.contains(chunk) else { return next() }
        let text = chunks[chunk]
        let lang = Self.language(of: stories[index].headline + " " + text)
        isPlaying = true
        updateNowPlaying()
        guard useNatural else { return speakWithApple(text, lang: lang) }

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
            if isPlaying { player.play() }  // paused while loading: resume() starts it
        }
    }

    private func speakWithApple(_ text: String, lang: String) {
        guard let voice = Self.appleVoice(for: lang) else {
            problem = "This iPhone has no voice for this language. Add one in Settings → Accessibility → Spoken Content → Voices."
            pause()
            return
        }
        problem = nil
        let u = AVSpeechUtterance(string: text)
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
            fallBack("Sign in on the Today tab for the Gemini voice. Using Apple's voice for now.")
            return nil
        }
        let task = Task<Data?, Never> { [weak self] in
            do {
                let res: SpeakResponse = try await store.invokeFunction("summarize", body: SpeakRequest(text: text))
                if res.ok, let link = res.url.flatMap(URL.init(string:)) {
                    let (data, response) = try await URLSession.shared.data(from: link)
                    if (response as? HTTPURLResponse)?.statusCode == 200 {
                        try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
                        try? data.write(to: file)
                        return data
                    }
                }
                self?.fallBack((res.message ?? "The Gemini voice isn't available.") + " Using Apple's voice for now.")
            } catch {
                if !Task.isCancelled { self?.fallBack("The Gemini voice couldn't be reached. Using Apple's voice for now.") }
            }
            return nil
        }
        fetches[key] = task
        let data = await task.value
        fetches[key] = nil
        return data
    }

    /// Starts fetching the next two sections while this one plays, so there's no gap between them.
    private func prefetchNext() {
        guard useNatural else { return }
        var upcoming = Array(chunks.dropFirst(chunk + 1))
        if stories.indices.contains(index + 1) { upcoming += Self.chunks(of: stories[index + 1]) }
        for text in upcoming.prefix(2) {
            Task { _ = await audio(for: text) }
        }
    }

    private func fallBack(_ message: String) {
        naturalOff = true
        note = message
    }

    private struct SpeakRequest: Encodable {
        let action = "speak"
        let text: String
    }
    private struct SpeakResponse: Decodable { let ok: Bool; let url: String?; let message: String? }

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
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
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
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.nextTrackCommand, center.previousTrackCommand]
            .forEach { $0.removeTarget(nil) }
    }
}
