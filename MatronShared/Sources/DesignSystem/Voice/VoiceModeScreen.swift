import SwiftUI

/// The iPhone's voice-mode screen (spec 2026-10-03 §6): the conversation's
/// name and box, one large state indicator, the line being spoken as a
/// caption, up to four buttons for the current thing's labels, and End.
/// A tap anywhere else interrupts.
///
/// A plain view over a plain model: it knows nothing of the engine, so the
/// Mac's stage can reuse it and snapshots need no audio.
public struct VoiceModeScreen: View {
    public struct Model: Equatable {
        public enum Phase: Equatable, CaseIterable {
            case listening
            case sending
            /// Nothing to say and the agent is busy.
            case working
            /// Nothing to say and nobody talking: a tap opens the microphone.
            case waiting
            case speaking
            /// "Sending: Go" has been said; "cancel" stops it.
            case confirming
            /// "Did you mean Go?" has been asked; only "yes" sends it.
            case asking
        }

        public var title: String
        public var boxName: String?
        public var phase: Phase
        public var caption: String?
        public var labels: [String]
        /// Voice notes kept until the connection is back.
        public var unsentCount: Int

        public init(title: String, boxName: String? = nil, phase: Phase, caption: String? = nil,
                    labels: [String] = [], unsentCount: Int = 0) {
            self.title = title; self.boxName = boxName; self.phase = phase; self.caption = caption
            self.labels = labels; self.unsentCount = unsentCount
        }
    }

    /// At most this many label buttons are drawn; the rest are spoken only.
    public static let maxButtons = 4

    let model: Model
    let onTap: () -> Void
    let onSend: () -> Void
    let onAction: (String) -> Void
    let onEnd: () -> Void

    public init(model: Model, onTap: @escaping () -> Void, onSend: @escaping () -> Void,
                onAction: @escaping (String) -> Void, onEnd: @escaping () -> Void) {
        self.model = model
        self.onTap = onTap
        self.onSend = onSend
        self.onAction = onAction
        self.onEnd = onEnd
    }

    public var body: some View {
        VStack(spacing: 24) {
            header
            Spacer(minLength: 0)
            indicator
            caption
            Spacer(minLength: 0)
            actions
            controls
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityAction(named: Text(Self.tapHint(model.phase)), onTap)
    }

    // MARK: Parts

    private var header: some View {
        VStack(spacing: 4) {
            Text(model.title.isEmpty ? "Voice mode" : model.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let box = model.boxName, !box.isEmpty {
                Text(box)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if model.unsentCount > 0 {
                Text(Self.unsentText(model.unsentCount))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var indicator: some View {
        VStack(spacing: 16) {
            Image(systemName: Self.symbol(model.phase))
                .font(.system(size: 72, weight: .regular))
                .foregroundStyle(Self.tint(model.phase))
                .frame(width: 168, height: 168)
                .background(Circle().fill(Self.tint(model.phase).opacity(0.14)))
            Text(Self.stateText(model.phase, boxName: model.boxName))
                .font(.title2.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder private var caption: some View {
        if let caption = model.caption, !caption.isEmpty {
            Text(caption)
                .font(.title3)
                .multilineTextAlignment(.center)
                .lineLimit(8)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var actions: some View {
        let labels = Array(model.labels.prefix(Self.maxButtons))
        if !labels.isEmpty {
            VStack(spacing: 10) {
                // By position: two labels may read the same.
                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                    Button { onAction(label) } label: {
                        Text(label)
                            .font(.headline)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            if model.phase == .listening {
                Button(action: onSend) {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
            }
            Button(role: .destructive, action: onEnd) {
                Label("End", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Words and symbols (static, so tests pin them)

    static func stateText(_ phase: Model.Phase, boxName: String?) -> String {
        switch phase {
        case .listening: return "Listening"
        case .sending: return "Sending"
        case .working: return "\(boxName ?? "The agent") is working"
        case .waiting: return "Tap to talk"
        case .speaking: return "Speaking"
        case .confirming: return "Say cancel to stop"
        case .asking: return "Say yes or no"
        }
    }

    static func symbol(_ phase: Model.Phase) -> String {
        switch phase {
        case .listening: return "mic.fill"
        case .sending: return "arrow.up"
        case .working: return "ellipsis"
        case .waiting: return "hand.tap.fill"
        case .speaking: return "waveform"
        case .confirming: return "checkmark"
        case .asking: return "questionmark"
        }
    }

    static func tint(_ phase: Model.Phase) -> Color {
        switch phase {
        case .listening: return .red
        case .sending, .confirming, .asking: return .blue
        case .working, .waiting: return .secondary
        case .speaking: return .green
        }
    }

    static func tapHint(_ phase: Model.Phase) -> String {
        switch phase {
        case .speaking: return "Interrupt"
        case .waiting, .working: return "Talk"
        case .confirming, .asking: return "Cancel"
        case .listening, .sending: return "Voice mode"
        }
    }

    static func unsentText(_ count: Int) -> String {
        count == 1 ? "1 voice note waiting for a connection" : "\(count) voice notes waiting for a connection"
    }
}
