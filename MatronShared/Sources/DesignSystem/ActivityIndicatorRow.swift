import SwiftUI

/// A bot-aligned typing / tool-use indicator: three stepping dots followed
/// by a label ("Thinking…", "Running <tool>"). Rendered as a trailing
/// timeline row while the agent is working, then removed. Lives in
/// `MatronDesignSystem` so iOS (`TimelineItemView`) and macOS
/// (`MacTimelineItemView`) share one source of truth.
///
/// The dots STEP (one lit at a time, no tween) instead of running a
/// `repeatForever` pulse. An in-flight SwiftUI animation makes the hosting
/// view re-layout and re-walk the ENTIRE display list every frame — and the
/// Mac timeline is an eager VStack of up to 120 mounted rows, so the old
/// pulse cost O(whole conversation) at up to 120Hz for as long as an agent
/// was working: a sustained ~55% of the main thread, sampled live on Dan's
/// Mac 2026-08-16. Discrete `TimelineView` ticks re-render ~3×/s instead.
public struct ActivityIndicatorRow: View {
    let label: String
    /// One step per period: the lit dot advances 0 → 1 → 2 and wraps.
    private static let stepInterval: TimeInterval = 0.35
    /// Reduce Motion holds the dots steady — and also spares the battery.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(label: String) {
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 8) {
            if reduceMotion {
                dots(lit: nil)
            } else {
                TimelineView(.periodic(from: .distantPast, by: Self.stepInterval)) { context in
                    dots(lit: Int(
                        context.date.timeIntervalSinceReferenceDate / Self.stepInterval
                    ) % 3)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.isEmpty ? "Agent is working" : label)
    }

    /// `lit` highlights one dot; nil (Reduce Motion) renders all three at a
    /// steady mid opacity. No `.animation` between steps — a tween would
    /// reintroduce the per-frame display-list walk the step exists to avoid.
    private func dots(lit: Int?) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundStyle(.secondary)
                    .opacity(lit == nil ? 0.55 : (lit == index ? 1 : 0.3))
            }
        }
    }
}
