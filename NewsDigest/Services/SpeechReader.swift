import AVFoundation
import MediaPlayer
import NaturalLanguage

/// Reads a page's stories aloud with Apple's built-in voices, one story at a time.
/// Back/forward skip between stories, from the app or from the lock screen and headphones.
@MainActor
final class SpeechReader: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    @Published private(set) var stories: [PaperStory] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    /// Set when this iPhone has no voice for the story's language (usually Bangla).
    @Published private(set) var problem: String?
    @Published var rate: Float = UserDefaults.standard.object(forKey: "speechRate") as? Float ?? 1.0 {
        didSet {
            UserDefaults.standard.set(rate, forKey: "speechRate")
            if isPlaying { speakChunk() }  // apply the new speed right away
        }
    }

    static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var isActive: Bool { !stories.isEmpty }
    var current: PaperStory? { stories.indices.contains(index) ? stories[index] : nil }

    private let synth = AVSpeechSynthesizer()
    private var chunks: [String] = []
    private var chunk = 0
    /// Only the utterance we last started may advance the queue; stopped ones are ignored.
    private var utterance: AVSpeechUtterance?
    private var title = ""
    private var commandsSet = false

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: - Controls

    func start(_ stories: [PaperStory], title: String) {
        self.stories = stories.filter { !$0.headline.isEmpty || !$0.body.isEmpty }
        self.title = title
        guard !self.stories.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        setUpRemoteCommands()
        play(story: 0)
    }

    func togglePause() { isPlaying ? pause() : resume() }

    func pause() {
        guard isPlaying else { return }
        synth.pauseSpeaking(at: .word)
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard isActive, !isPlaying else { return }
        if synth.isPaused { synth.continueSpeaking(); isPlaying = true; updateNowPlaying() } else { speakChunk() }
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
        utterance = nil
        synth.stopSpeaking(at: .immediate)
        stories = []
        isPlaying = false
        problem = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Speaking

    private func play(story: Int) {
        index = story
        let s = stories[story]
        // Headline first, then the body a paragraph at a time so skipping and speed changes stay quick.
        let paragraphs = s.body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        chunks = (s.headline.isEmpty ? [] : [s.headline]) + paragraphs
        chunk = 0
        speakChunk()
    }

    private func speakChunk() {
        guard chunks.indices.contains(chunk) else { return next() }
        let text = chunks[chunk]
        guard let voice = Self.voice(for: stories[index].headline + " " + text) else {
            problem = "This iPhone has no voice for this language. Add one in Settings → Accessibility → Spoken Content → Voices."
            pause()
            return
        }
        problem = nil
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * rate
        u.postUtteranceDelay = chunk == 0 ? 0.5 : 0.25  // a beat after the headline
        utterance = nil
        synth.stopSpeaking(at: .immediate)
        utterance = u
        synth.speak(u)
        isPlaying = true
        updateNowPlaying()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish finished: AVSpeechUtterance) {
        guard finished === utterance else { return }
        chunk += 1
        speakChunk()
    }

    /// The best installed voice for the text's language, preferring enhanced and premium voices.
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(500)))
        let lang = recognizer.dominantLanguage?.rawValue ?? "en"
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
