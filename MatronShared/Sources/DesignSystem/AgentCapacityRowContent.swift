import SwiftUI
import MatronModels

/// The capacity block under an agent's name in the New Chat chooser: how
/// many sessions the box is running and every usage-limit line, or a quiet
/// "Checking…" placeholder while the fan-out reply is in flight. Shared by
/// the Mac and iOS sheets so the two choosers can't drift.
///
/// The block also renders for a box that is *offline*, from the last capacity
/// it reported: the host suspends idle boxes, so that is the only way to see
/// which sleeping box still has quota. Those rows pass `freshness: .offline`,
/// which de-emphasises every percentage and adds one age caption — see
/// `AgentCapacityFreshness`.
///
/// Display-only — nothing here gates picking the box. An old bridge that
/// sends no capacity blocks renders as nothing at all.
public struct AgentCapacityRowContent: View {
    let capacity: BoxCapacity?
    let pending: Bool
    /// Live numbers, or cached ones from a box that is asleep.
    let freshness: AgentCapacityFreshness
    /// Frozen clock for the reset and age captions, so snapshots are
    /// deterministic (same idiom as `UsageBarsView.fixedNow`); nil = now.
    let fixedNow: Date?

    public init(capacity: BoxCapacity?, pending: Bool,
                freshness: AgentCapacityFreshness = .live, fixedNow: Date? = nil) {
        self.capacity = capacity
        self.pending = pending
        self.freshness = freshness
        self.fixedNow = fixedNow
    }

    public var body: some View {
        if let capacity, hasContent(capacity) {
            VStack(alignment: .leading, spacing: 2) {
                if let sessions = Self.sessionsLine(capacity, freshness: freshness) {
                    Text(sessions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(capacity.limitLines) { line in
                    limitRow(line)
                }
                // Block-level, once: the per-line "reset" caption says the
                // window rolled over, this says when the numbers were read.
                if let age = freshness.ageText(now: fixedNow ?? Date()) {
                    Text(age)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else if pending {
            Text("Checking…")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// Whether there is anything to show at all. Guards the age caption in
    /// particular: on its own it would be a disclaimer under a row that
    /// discloses nothing (a legacy bridge sent no capacity blocks).
    private func hasContent(_ capacity: BoxCapacity) -> Bool {
        Self.sessionsLine(capacity, freshness: freshness) != nil || !capacity.limitLines.isEmpty
    }

    private func limitRow(_ line: LimitLine) -> some View {
        let now = fixedNow ?? Date()
        let reset = BoxCapacity.resetText(line.resetsAt, now: now)
        let expired = BoxCapacity.hasReset(line.resetsAt, now: now)
        return HStack(spacing: 4) {
            Text(line.label)
                .foregroundStyle(.secondary)
            Text("\(line.percent)%")
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(Self.percentEmphasis(line.percent, expired: expired,
                                                      freshness: freshness).shapeStyle)
            if let reset {
                Text("· \(reset)")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.limitAccessibilityLabel(
            label: line.label, percent: line.percent, expired: expired,
            resetText: reset, freshness: freshness))
    }

    /// The live-session count worth showing, or nil when there is none.
    ///
    /// Cached blocks never show one: a box the host has put to sleep is
    /// running nothing, so its last session count is not merely stale but
    /// false. The quota lines are what survive being offline — they describe
    /// a window, not a moment.
    ///
    /// Shared with the Mac grid, which renders the bare number in a
    /// fixed-width cell rather than this view's sentence.
    public static func shownSessions(_ capacity: BoxCapacity?,
                                     freshness: AgentCapacityFreshness) -> Int? {
        guard !freshness.isStale else { return nil }
        return capacity?.liveSessions
    }

    /// The sessions line, or nil when there is none to show.
    public static func sessionsLine(_ capacity: BoxCapacity,
                                    freshness: AgentCapacityFreshness) -> String? {
        shownSessions(capacity, freshness: freshness).map(sessionsText)
    }

    /// How a percentage is rendered.
    public enum PercentEmphasis: Equatable {
        case tinted(Color)
        /// The number is shown but not vouched for.
        case deemphasised

        /// Ready for `foregroundStyle`: the two cases are different
        /// `ShapeStyle` types, so they have to be erased to be one expression.
        public var shapeStyle: AnyShapeStyle {
            switch self {
            case .tinted(let color): return AnyShapeStyle(color)
            case .deemphasised: return AnyShapeStyle(.tertiary)
            }
        }
    }

    /// A percentage earns the usual green/orange/red only when it describes
    /// the box as it is now. Two independent ways it can fail to: the line's
    /// own reset moment has passed (`expired`, so the percent predates the
    /// rollover), or the whole block was read off the cache while the box is
    /// asleep. Either one de-emphasises; both together is not a third state.
    public static func percentEmphasis(_ percent: Int, expired: Bool,
                                       freshness: AgentCapacityFreshness) -> PercentEmphasis {
        (expired || freshness.isStale) ? .deemphasised : .tinted(percentColor(percent))
    }

    /// One limit's spoken label, shared by the stacked iOS row and the Mac
    /// grid cell so the two can't drift.
    public static func limitAccessibilityLabel(label: String, percent: Int, expired: Bool,
                                               resetText: String?,
                                               freshness: AgentCapacityFreshness) -> String {
        "\(label), \(percent) percent used"
            + (expired ? " before the limit reset" : "")
            + (resetText.map { ", \($0)" } ?? "")
            // Unqualified by an age on purpose: the row's own caption
            // announces that once, and a three-column Mac row would otherwise
            // repeat it three times.
            + (freshness.isStale ? ", last known" : "")
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
