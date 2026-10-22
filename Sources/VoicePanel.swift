import SwiftUI

// Dictation's place in the composer while it's on (see Dictation). Recording: the words heard so far
// above a row of Discard, the timer and level meter, and Stop. Then the transcript to check and fix,
// with Discard, Redo, Edit (into the normal message field) and Send.
struct VoicePanel: View {
    @ObservedObject var dictation: Dictation
    let onSend: (String) -> Void
    let onEdit: (String) -> Void

    var body: some View {
        Group {
            if dictation.phase == .recording { recording } else { review }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: Recording

    var recording: some View {
        VStack(spacing: 10) {
            // What's been heard, with the timer and level meter under it.
            VStack(alignment: .leading, spacing: 10) {
                Text(dictation.preview.isEmpty ? "Listening…" : dictation.preview)
                    .font(.subheadline).italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(dictation.preview.isEmpty ? "Listening" : "Hearing: \(dictation.preview)")
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    Text(Self.clock(dictation.seconds))
                        .font(.body.monospacedDigit())
                        .fixedSize()
                    LevelMeter(levels: dictation.levels)
                        .frame(height: 26)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording, \(Self.clock(dictation.seconds))")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            HStack(spacing: 10) {
                circleButton("trash", "Discard recording") { dictation.discard() }
                Spacer()
                // Feeling lucky: no review, the transcript goes out as soon as it's ready.
                Button { dictation.stopAndSend(onSend) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glassProminentIfAvailable)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel("Send without review")
                Button { dictation.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.red)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glassIfAvailable)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel("Stop and review")
            }
        }
    }

    // MARK: Transcribing / review

    var review: some View {
        let ready = dictation.phase == .review
        return VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                if !ready {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(dictation.sending ? "Sending…" : "Transcribing…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                } else if let problem = dictation.problem {
                    Label(problem, systemImage: "exclamationmark.bubble")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                } else {
                    TextField("Transcript", text: $dictation.transcript, axis: .vertical)
                        .lineLimit(1...5)
                        .accessibilityLabel("Transcript")
                    Text("Tap text to fix a word")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            HStack(spacing: 10) {
                circleButton("trash", "Discard recording") { dictation.discard() }
                circleButton("arrow.counterclockwise", "Redo transcription") { dictation.redo() }
                    .disabled(!ready)
                circleButton("pencil", "Edit in message field") { onEdit(dictation.take()) }
                    .disabled(!dictation.canSend)
                Button { onSend(dictation.take()) } label: {
                    Label("Send", systemImage: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.glassProminentIfAvailable)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(!dictation.canSend)
            }
        }
    }

    func circleButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        CircleButton(symbol: symbol, action: action).accessibilityLabel(label)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct CircleButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.glassIfAvailable)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .tint(.primary)
    }
}

/// Bars for the most recent loudness, newest on the right. Drawn, so it never changes the layout.
struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        Canvas { ctx, size in
            let bar: CGFloat = 3, step: CGFloat = 6
            var x = size.width - bar
            for level in levels.reversed() {
                guard x >= 0 else { break }
                let h = max(bar, CGFloat(level) * size.height)
                let r = CGRect(x: x, y: (size.height - h) / 2, width: bar, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: bar / 2), with: .style(.secondary))
                x -= step
            }
        }
        .accessibilityHidden(true)
    }
}

extension PrimitiveButtonStyle where Self == GlassProminentIfAvailableStyle {
    static var glassProminentIfAvailable: GlassProminentIfAvailableStyle { GlassProminentIfAvailableStyle() }
}

/// Tinted Liquid Glass buttons on iOS 26 (Send, Stop), filled ones before.
struct GlassProminentIfAvailableStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26, *) {
            Button(configuration).buttonStyle(.glassProminent)
        } else {
            Button(configuration).buttonStyle(.borderedProminent)
        }
    }
}
