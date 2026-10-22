import Foundation
import SherpaOnnxC

/// Kokoro running on the phone through sherpa-onnx. One model is loaded at a time; making
/// speech is slow CPU work, so it runs on its own queue, one request after another.
final class KokoroEngine: @unchecked Sendable {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let pack: VoicePack
    private let accent: KokoroVoice.Accent
    private let queue = DispatchQueue(label: "kokoro", qos: .userInitiated)
    private var tts: OpaquePointer?

    init(pack: VoicePack, accent: KokoroVoice.Accent) {
        self.pack = pack
        self.accent = accent
    }

    deinit {
        if let tts { SherpaOnnxDestroyOfflineTts(tts) }
    }

    /// Whether this engine can speak `choice` without reloading.
    func fits(_ choice: KokoroChoice) -> Bool {
        // v1.0 picks its pronunciation dictionary by accent; v0.19 has only one.
        choice.pack == pack && (pack != .v10 || choice.voice.accent == accent)
    }

    /// The speech for `text` as a WAV file in memory, at normal speed (playback sets the speed).
    func wav(_ text: String, sid: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.generate(text, sid: sid) })
            }
        }
    }

    /// Loads the model ahead of the first section.
    func warmUp() {
        queue.async { _ = try? self.load() }
    }

    private func load() throws -> OpaquePointer {
        if let tts { return tts }
        guard VoicePacks.isInstalled(pack), let model = VoicePacks.modelFile(of: pack) else {
            throw Failure(message: "\(pack.name) isn't downloaded.")
        }
        let dir = VoicePacks.folder(of: pack)
        // C strings stay alive until the model is made.
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            strings.append(p)
            return UnsafePointer(p)
        }

        var config = SherpaOnnxOfflineTtsConfig()
        config.model.kokoro.model = c(model.path)
        config.model.kokoro.voices = c(dir.appendingPathComponent("voices.bin").path)
        config.model.kokoro.tokens = c(dir.appendingPathComponent("tokens.txt").path)
        config.model.kokoro.data_dir = c(dir.appendingPathComponent("espeak-ng-data").path)
        config.model.kokoro.length_scale = 1.0
        if pack == .v10 {
            let lexicon = accent == .uk ? "lexicon-gb-en.txt" : "lexicon-us-en.txt"
            config.model.kokoro.lexicon = c(dir.appendingPathComponent(lexicon).path)
        }
        config.model.num_threads = 2
        config.model.debug = 0
        config.model.provider = c("cpu")
        config.max_num_sentences = 1

        guard let made = SherpaOnnxCreateOfflineTts(&config) else {
            throw Failure(message: "\(pack.name) couldn't be loaded. Try deleting and downloading it again.")
        }
        tts = made
        return made
    }

    private func generate(_ text: String, sid: Int) throws -> Data {
        let tts = try load()
        var options = SherpaOnnxGenerationConfig()
        options.sid = Int32(sid)
        options.speed = 1.0
        options.silence_scale = 0.2
        guard let audio = SherpaOnnxOfflineTtsGenerateWithConfig(tts, text, &options, nil, nil) else {
            throw Failure(message: "Kokoro couldn't read this section.")
        }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        let samples = audio.pointee
        guard samples.n > 0 else { throw Failure(message: "Kokoro made no sound for this section.") }
        var data = Data(count: Int(SherpaOnnxWaveFileSize(samples.n)))
        data.withUnsafeMutableBytes { buffer in
            SherpaOnnxWriteWaveToBuffer(samples.samples, samples.n, samples.sample_rate,
                                        buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return data
    }
}
