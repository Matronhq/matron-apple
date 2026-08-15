import SwiftUI
import MatronModels

/// The capacity block under an agent's name in the New Chat chooser: how
/// many sessions the box is running and every usage-limit line, or a quiet
/// "Checking…" placeholder while the fan-out reply is in flight. Shared by
/// the Mac and iOS sheets so the two choosers can't drift.
///
/// Display-only — nothing here gates picking the box. An old bridge that
/// sends no capacity blocks renders as nothing at all.
public struct AgentCapacityRowContent: View {
    let capacity: BoxCapacity?
    let pending: Bool
    /// Frozen clock for the reset captions, so snapshots are deterministic
    /// (same idiom as `UsageBarsView.fixedNow`); nil = now.
    let fixedNow: Date?

    public init(capacity: BoxCapacity?, pending: Bool, fixedNow: Date? = nil) {
        self.capacity = capacity
        self.pending = pending
        self.fixedNow = fixedNow
    }

    public var body: some View {
        if let capacity {
            VStack(alignment: .leading, spacing: 2) {
                if let live = capacity.liveSessions {
                    Text(Self.sessionsText(live))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(capacity.limitLines) { line in
                    limitRow(line)
                }
            }
        } else if pending {
            Text("Checking…")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func limitRow(_ line: LimitLine) -> some View {
        let now = fixedNow ?? Date()
        let reset = BoxCapacity.resetText(line.resetsAt, now: now)
        // A percent from before the line's own reset moment is stale —
        // render it tertiary (with the "reset" caption) rather than in the
        // usual green/orange/red, which would vouch for a dead number.
        let expired = BoxCapacity.hasReset(line.resetsAt, now: now)
        return HStack(spacing: 4) {
            Text(line.label)
                .foregroundStyle(.secondary)
            Text("\(line.percent)%")
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(expired ? AnyShapeStyle(.tertiary)
                                         : AnyShapeStyle(Self.percentColor(line.percent)))
            if let reset {
                Text("· \(reset)")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(line.label), \(line.percent) percent used"
                + (expired ? " before the limit reset" : "")
                + (reset.map { ", \($0)" } ?? ""))
    }

    /// "No active sessions" / "1 active session" / "N active sessions".
    /// Spelled out rather than left to automatic grammar agreement — the
    /// apps ship no string catalog for `inflect:` to consult.
    static func sessionsText(_ count: Int) -> String {
        switch count {
        case ...0: return "No active sessions"
        case 1: return "1 active session"
        default: return "\(count) active sessions"
        }
    }

    /// Percent tint, delegating to the /usage bars' threshold table so every
    /// usage surface agrees (green < 50, orange < 80, red >= 80).
    static func percentColor(_ percent: Int) -> Color {
        UsageMetersFormat.barColor(percent: percent)
    }
}
