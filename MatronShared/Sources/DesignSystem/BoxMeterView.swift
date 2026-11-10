import SwiftUI
import MatronModels

/// One usage meter on the Boxes screen: the percent, a thin bar and when it
/// resets. Same colours and de-emphasis rule as the New Chat chooser.
public struct BoxMeterView: View {
    let line: LimitLine?
    let freshness: AgentCapacityFreshness
    /// Frozen clock for snapshots; nil = now.
    let fixedNow: Date?

    public init(line: LimitLine?, freshness: AgentCapacityFreshness, fixedNow: Date? = nil) {
        self.line = line
        self.freshness = freshness
        self.fixedNow = fixedNow
    }

    public var body: some View {
        if let line {
            let now = fixedNow ?? Date()
            let expired = BoxCapacity.hasReset(line.resetsAt, now: now)
            let style = AgentCapacityRowContent
                .percentEmphasis(line.percent, expired: expired, freshness: freshness).shapeStyle
            let reset = BoxCapacity.resetCaption(line.resetsAt, now: now)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(line.percent)%")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(style)
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(style)
                                .frame(width: max(2, proxy.size.width * min(1, CGFloat(line.percent) / 100)))
                        }
                    }
                if let reset {
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AgentCapacityRowContent.limitAccessibilityLabel(
                label: line.label, percent: line.percent, expired: expired,
                resetText: reset, freshness: freshness))
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// A box's state: a coloured dot and its name.
public struct BoxStateLabel: View {
    let state: BoxConnectionState

    public init(state: BoxConnectionState) { self.state = state }

    public var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(state.title)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var color: Color {
        switch state {
        case .online: return .green
        case .asleep: return .gray
        case .offline: return .red
        }
    }
}

/// The small tinted pill beside a box's name.
public struct BoxBadge: View {
    let text: String
    let color: Color

    public init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}
