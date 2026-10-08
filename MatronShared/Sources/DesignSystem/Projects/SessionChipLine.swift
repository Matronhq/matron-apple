import SwiftUI
import MatronModels

/// "P:ad pat · waiting   A:13 box-a · running  +1 more  +2 rooms" — a
/// mission row's sessions on the project page (spec §2: "2 session
/// chips"), then its agent-chat rooms as a count (they never take a chip).
public struct SessionChipLine: View {
    let sessions: [DashboardSession]
    let roomCount: Int
    let limit: Int
    @Environment(\.colorScheme) private var colorScheme
    public init(sessions: [DashboardSession], roomCount: Int = 0, limit: Int = 2) {
        self.sessions = sessions; self.roomCount = roomCount; self.limit = limit
    }

    public static func moreText(total: Int, limit: Int) -> String? { total > limit ? "+\(total - limit) more" : nil }

    public var body: some View {
        if !sessions.isEmpty || roomCount > 0 {
            HStack(spacing: 10) {
                ForEach(sessions.prefix(limit)) { chip($0) }
                if let more = Self.moreText(total: sessions.count, limit: limit) {
                    Text(more).font(.caption).foregroundStyle(.secondary)
                }
                if roomCount > 0 {
                    Text(MissionsDashboardFormat.rooms(roomCount)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }

    private func chip(_ session: DashboardSession) -> some View {
        HStack(spacing: 4) {
            if let tag = session.tag,
               let run = SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                            sessionShort: tag.sessionShort, colorScheme: colorScheme) {
                run.font(.caption.monospaced())
            }
            Text("\(session.tag?.boxName ?? session.boxName ?? session.title) · \(DashboardStateDot.label(session.state).lowercased())")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
