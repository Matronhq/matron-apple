import SwiftUI
import MatronModels

/// One slim mission row (spec 2026-09-30 §2): dot · #num · title ·
/// one-line status · needs-you · age. Replaces the mission card on the
/// home screen; the Closed fold uses it with `MissionRowModel(closed:)`.
public struct MissionRowView: View {
    let row: MissionRowModel
    /// Fixed for snapshots; nil ticks every minute.
    let now: Date?
    public init(row: MissionRowModel, now: Date? = nil) { self.row = row; self.now = now }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            MissionActivityDot(activity: row.activity, isClosed: row.mission.state == .closed)
            #if os(macOS)
            Text(verbatim: "#\(row.mission.num)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .leading)
            #endif
            VStack(alignment: .leading, spacing: 2) {
                Text(row.mission.title).font(.body.weight(.semibold)).lineLimit(1)
                Text(secondLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            NeedsYouPill(count: row.needsYouCount)
            age
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mission \(row.mission.num), \(row.mission.title), \(secondLine)"
            + (row.needsYouCount > 0 ? ", \(row.needsYouCount) \(row.needsYouCount == 1 ? "item needs" : "items need") you" : ""))
    }

    private var secondLine: String {
        if row.mission.state == .closed {
            return ProjectsFormat.closedMissionLine(row.mission)
        }
        return ProjectsFormat.missionLine(row.mission, now: now ?? Date())
    }

    @ViewBuilder private var age: some View {
        Group {
            if let now { Text(RelativeMinuteTimeView.format(row.lastActivity, now: now)) } else { RelativeMinuteTimeView(row.lastActivity) }
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary).fixedSize()
    }
}
