import SwiftUI

/// A bot-aligned typing / tool-use indicator: three softly pulsing dots
/// followed by a label ("Thinking…", "Running <tool>"). Rendered as a
/// trailing timeline row while the agent is working, then removed. Lives in
/// `MatronDesignSystem` so iOS (`TimelineItemView`) and macOS
/// (`MacTimelineItemView`) share one source of truth.
public struct ActivityIndicatorRow: View {
    let label: String
    /// Drives the dot animation. A single phase shared across the three dots,
    /// each offset so they pulse in sequence.
    @State private var animating = false

    public init(label: String) {
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: 6, height: 6)
                        .foregroundStyle(.secondary)
                        .opacity(animating ? 1 : 0.3)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever()
                                .delay(Double(index) * 0.2),
                            value: animating
                        )
                }
            }
            if !label.isEmpty {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .onAppear { animating = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.isEmpty ? "Agent is working" : label)
    }
}
