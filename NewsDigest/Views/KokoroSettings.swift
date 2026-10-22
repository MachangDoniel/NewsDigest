import AVFoundation
import SwiftUI

/// Settings → Read aloud, when Kokoro is picked: the voice packs (download, delete) and the voice.
struct KokoroSettings: View {
    @StateObject private var packs = VoicePacks()
    @StateObject private var preview = KokoroPreview()
    @AppStorage(KokoroChoice.key) private var voiceTag = ""
    @State private var confirmDelete: VoicePack?

    private var installedPacks: [VoicePack] { VoicePack.all.filter { packs.installed.contains($0.id) } }

    var body: some View {
        Section {
            ForEach(VoicePack.all) { pack in packRow(pack) }
        } header: {
            Text("Kokoro voice packs")
        } footer: {
            Text("Packs are shared with Speak Partner on this iPhone, so one either app has downloaded is ready in both. Download on Wi-Fi and keep the app open until it's done.")
        }

        if !installedPacks.isEmpty {
            Section {
                Picker("Voice", selection: selection) {
                    ForEach(installedPacks) { pack in
                        Section(pack.name) {
                            ForEach(pack.voices, id: \.sid) { voice in
                                Text(voice.label).tag(KokoroChoice(pack: pack, voice: voice).tag)
                            }
                        }
                    }
                }
                Button {
                    if let choice = KokoroChoice(tag: selection.wrappedValue) { preview.play(choice) }
                } label: {
                    if preview.loading {
                        HStack { ProgressView(); Text("Making a sample…") }
                    } else {
                        Label("Play a sample", systemImage: "play.circle")
                    }
                }
                .disabled(preview.loading)
                if let error = preview.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("Kokoro reads English stories on this phone: free, offline and no quota. Bangla stories use the Gemini voice, or Apple's voice when Gemini isn't available.")
            }
        }

        if let error = packs.error {
            Section { Text(error).font(.footnote).foregroundStyle(.red) }
        }
    }

    /// The saved voice, or the default one when the saved voice's pack isn't on the phone.
    private var selection: Binding<String> {
        Binding(
            get: {
                if let c = KokoroChoice(tag: voiceTag), packs.installed.contains(c.pack.id) { return voiceTag }
                return KokoroChoice.current?.tag ?? ""
            },
            set: { voiceTag = $0 })
    }

    @ViewBuilder
    private func packRow(_ pack: VoicePack) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.name).font(.body.weight(.medium))
                Text(pack.detail).font(.caption).foregroundStyle(.secondary)
                if let fraction = packs.progress[pack.id] {
                    ProgressView(value: fraction)
                    Text("Downloading \(Int(fraction * 100))% of \(pack.megabytes) MB").font(.caption2).foregroundStyle(.secondary)
                } else if packs.unpacking.contains(pack.id) {
                    Text("Unpacking…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if packs.progress[pack.id] != nil {
                Button("Cancel", role: .cancel) { packs.cancel(pack) }.buttonStyle(.borderless)
            } else if packs.unpacking.contains(pack.id) {
                ProgressView()
            } else if packs.installed.contains(pack.id) {
                Menu {
                    Button("Delete", role: .destructive) { confirmDelete = pack }
                } label: {
                    Label("On phone", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green).font(.title3)
                }
                .accessibilityLabel("\(pack.name) is on this phone. Options")
            } else {
                Button {
                    packs.download(pack)
                } label: {
                    Text("\(pack.megabytes) MB").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Download \(pack.name), \(pack.megabytes) megabytes")
            }
        }
        .confirmationDialog(
            "Delete \(confirmDelete?.name ?? "")?", isPresented: Binding(get: { confirmDelete == pack }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { packs.delete(pack); confirmDelete = nil }
        } message: {
            Text("It's shared with Speak Partner, so Speak Partner loses it too.")
        }
        .onAppear { packs.refresh() }
    }
}

/// Plays a short sample of a Kokoro voice in Settings.
@MainActor
final class KokoroPreview: ObservableObject {
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var engine: KokoroEngine?
    private var player: AVAudioPlayer?

    func play(_ choice: KokoroChoice) {
        player?.stop()
        error = nil
        loading = true
        if engine.map({ !$0.fits(choice) }) ?? true {
            engine = KokoroEngine(pack: choice.pack, accent: choice.voice.accent)
        }
        let engine = engine!
        Task {
            defer { loading = false }
            do {
                let wav = try await engine.wav("Good morning. Here are today's top stories, read by \(choice.voice.name).", sid: choice.voice.sid)
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try? AVAudioSession.sharedInstance().setActive(true)
                player = try AVAudioPlayer(data: wav)
                player?.play()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
