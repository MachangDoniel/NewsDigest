import SwiftUI

/// Read-aloud controls for the reader, kept out of the way: a headphones button when idle,
/// a small pill while reading, and the full controls only after tapping the pill.
/// They fold back into the pill after a few seconds without a tap.
struct ListenControls: View {
    @ObservedObject var reader: SpeechReader
    let tint: Color
    let loading: Bool
    let onStart: () -> Void
    @Binding var expanded: Bool

    /// Bumped on every tap in the panel, which restarts the auto-hide timer.
    @State private var touch = 0

    var body: some View {
        Group {
            if !reader.isActive {
                startButton
            } else if expanded {
                panel.transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                pill.transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: expanded)
        .animation(.spring(duration: 0.3), value: reader.isActive)
        .task(id: touch) {
            guard expanded else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, reader.isPlaying { expanded = false }
        }
        .onChange(of: reader.isActive) { _, active in if !active { expanded = false } }
    }

    private var startButton: some View {
        Button(action: onStart) {
            Group {
                if loading { ProgressView() } else { Image(systemName: "headphones") }
            }
            .font(.title3.weight(.semibold))
            .frame(width: 50, height: 50)
            .foregroundStyle(tint)
            .background(.regularMaterial, in: Circle())
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        }
        .disabled(loading)
        .accessibilityLabel("Read this page aloud")
    }

    private var pill: some View {
        Button { expanded = true; touch += 1 } label: {
            HStack(spacing: 8) {
                Image(systemName: reader.isPlaying ? "waveform" : "pause.fill")
                    .symbolEffect(.variableColor.iterative, isActive: reader.isPlaying)
                Text("\(reader.index + 1)/\(reader.stories.count)").monospacedDigit()
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .frame(height: 50)
            .foregroundStyle(tint)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        }
        .accessibilityLabel("Reading story \(reader.index + 1) of \(reader.stories.count). Show controls")
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Story \(reader.index + 1) of \(reader.stories.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(reader.current?.headline ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button { expanded = false } label: {
                    Image(systemName: "chevron.down").font(.subheadline.weight(.semibold)).padding(6)
                }
                .accessibilityLabel("Hide controls")
            }

            if let problem = reader.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Menu {
                    ForEach(SpeechReader.rates, id: \.self) { r in
                        Button { reader.rate = r; touch += 1 } label: {
                            if r == reader.rate { Label(Self.label(r), systemImage: "checkmark") } else { Text(Self.label(r)) }
                        }
                    }
                } label: {
                    Text(Self.label(reader.rate)).font(.subheadline.weight(.semibold)).monospacedDigit().frame(width: 48)
                }
                .accessibilityLabel("Speed \(Self.label(reader.rate))")

                Spacer()
                control("backward.fill", "Previous story") { reader.previous() }
                Spacer()
                control(reader.isPlaying ? "pause.fill" : "play.fill", reader.isPlaying ? "Pause" : "Play", size: .title) { reader.togglePause() }
                Spacer()
                control("forward.fill", "Next story") { reader.next() }
                    .disabled(reader.index + 1 >= reader.stories.count)
                Spacer()

                Button { reader.stop() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 48)
                }
                .accessibilityLabel("Stop reading")
            }
            .foregroundStyle(tint)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private func control(_ icon: String, _ label: String, size: Font = .title2, action: @escaping () -> Void) -> some View {
        Button { action(); touch += 1 } label: {
            Image(systemName: icon).font(size).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(label)
    }

    private static func label(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}
