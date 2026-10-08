import SwiftUI

/// The app-wide voice-note pill: while a note records, it
/// sits on every page with where the note is going, the running time,
/// Cancel and Send; tapping the rest of it returns to that place. After a
/// failed send it turns into a Retry / Discard row, so a note recorded for
/// a conversation that has since gone away is never silently lost.
///
/// Values only — the app shells bind it to `VoiceNoteSession`.
public struct VoiceNoteIndicator: View {
    public enum Mode: Equatable {
        case recording(start: Date)
        case sending
        /// `canRetry` false: only Dismiss — nothing is left to send.
        case failed(message: String, canRetry: Bool = true)
    }

    let mode: Mode
    let title: String
    let onOpen: () -> Void
    let onCancel: () -> Void
    let onSend: () -> Void

    public init(mode: Mode, title: String,
                onOpen: @escaping () -> Void,
                onCancel: @escaping () -> Void,
                onSend: @escaping () -> Void) {
        self.mode = mode
        self.title = title
        self.onOpen = onOpen
        self.onCancel = onCancel
        self.onSend = onSend
    }

    public var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    glyph
                    VStack(alignment: .leading, spacing: 1) {
                        headline
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the place this voice note is for")
            .accessibilityIdentifier("voiceNoteIndicator.open")

            switch mode {
            case .recording:
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel voice note")
                .accessibilityIdentifier("voiceNoteIndicator.cancel")
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send voice note")
                .accessibilityIdentifier("voiceNoteIndicator.send")
            case .sending:
                ProgressView()
                    .controlSize(.small)
            case .failed(_, let canRetry):
                Button(action: onCancel) { Text(canRetry ? "Discard" : "Dismiss").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("voiceNoteIndicator.discard")
                if canRetry {
                    Button("Retry", action: onSend)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("voiceNoteIndicator.retry")
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 480)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    @ViewBuilder private var glyph: some View {
        switch mode {
        case .recording:
            Circle().fill(Color.red).frame(width: 10, height: 10)
                .accessibilityHidden(true)
        case .sending:
            Image(systemName: "waveform").foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var headline: some View {
        switch mode {
        case .recording(let start):
            HStack(spacing: 6) {
                Text("Recording")
                Text(start, style: .timer).monospacedDigit()
            }
            .font(.subheadline.weight(.semibold))
        case .sending:
            Text("Sending voice note…").font(.subheadline.weight(.semibold))
        case .failed:
            Text("Voice note didn't send").font(.subheadline.weight(.semibold))
        }
    }

    private var subtitle: String {
        switch mode {
        case .recording, .sending: return "For \(title)"
        case .failed(let message, _): return "\(title): \(message)"
        }
    }
}
