import SwiftUI
import MatronModels

/// "Context: 265k/1m" — the context-window gauge from the last status
/// frame. Caption-sized secondary text; sits left of the Mac header title
/// and at the top of the iOS session-status sheet.
public struct ContextGaugeLabel: View {
    let context: SessionStatus.Context

    public init(context: SessionStatus.Context) {
        self.context = context
    }

    public var body: some View {
        Text("Context: \(UsageMetersFormat.compactTokens(context.tokens))/\(UsageMetersFormat.compactTokens(context.window))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Context: \(UsageMetersFormat.spokenTokens(context.tokens)) of \(UsageMetersFormat.spokenTokens(context.window)) tokens")
    }
}

/// Stacked horizontal usage bars (Session / Week / model) with the reset
/// time trailing each bar. `.compact` fits the Mac toolbar's height;
/// `.regular` is the roomier iOS-sheet form. A 1-minute TimelineView keeps
/// countdown text ("3h20") fresh between status frames; `fixedNow` swaps
/// it for a frozen clock so snapshots are deterministic.
public struct UsageBarsView: View {
    public enum Scale {
        case compact, regular

        var font: Font { self == .compact ? .system(size: 9) : .caption }
        var barWidth: CGFloat { self == .compact ? 90 : 160 }
        var barHeight: CGFloat { self == .compact ? 3 : 6 }
        var rowSpacing: CGFloat { self == .compact ? 2 : 8 }
    }

    let limits: [SessionStatus.Limit]
    let scale: Scale
    let fixedNow: Date?

    public init(limits: [SessionStatus.Limit], scale: Scale = .compact, fixedNow: Date? = nil) {
        self.limits = limits
        self.scale = scale
        self.fixedNow = fixedNow
    }

    public var body: some View {
        if let fixedNow {
            rows(now: fixedNow)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                rows(now: timeline.date)
            }
        }
    }

    private func rows(now: Date) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: scale.rowSpacing) {
            // Server order, capped at three — the header is sized for
            // session / week / per-model week.
            ForEach(Array(limits.prefix(3).enumerated()), id: \.offset) { _, limit in
                GridRow {
                    Text("\(UsageMetersFormat.barLabel(limit.label)):")
                        .gridColumnAlignment(.trailing)
                    bar(for: limit)
                    Text(UsageMetersFormat.resetDisplay(resetsAt: limit.resetsAt, raw: limit.resets, now: now) ?? "")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(for: limit, now: now))
            }
        }
        .font(scale.font)
    }

    private func bar(for limit: SessionStatus.Limit) -> some View {
        let fraction = CGFloat(min(max(limit.percent, 0), 100)) / 100
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.12))
            Capsule()
                .fill(UsageMetersFormat.barColor(percent: limit.percent))
                .frame(width: scale.barWidth * fraction)
        }
        .frame(width: scale.barWidth, height: scale.barHeight)
    }

    private func accessibilityText(for limit: SessionStatus.Limit, now: Date) -> String {
        var text = "\(UsageMetersFormat.barLabel(limit.label)), \(limit.percent) percent used"
        if let reset = UsageMetersFormat.resetDisplay(resetsAt: limit.resetsAt, raw: limit.resets, now: now) {
            text += ", resets \(reset)"
        }
        return text
    }
}
