import SwiftUI
import MatronModels

/// The iOS chat header's second line (spec 2026-09-30 §6, mockup 04 right):
/// "box · ~/workdir" — visible without opening anything — then the mission chip and, for a conversation in an
/// agent-chat room, the "Rooms · n" chip. They share the line; the workdir
/// middle-truncates first. When even `contextMinWidth` of workdir beside
/// the whole chips won't fit, the chips drop to a compact line of their own.
public struct ChatHeaderSubtitle: View {
    /// The least workdir text worth keeping beside the chip.
    public static let contextMinWidth: CGFloat = 96

    public enum Layout: Equatable { case contextAndChip, chipOnly, contextOnly, none }

    public static func layout(context: String?, missions: ConversationMissions, roomCount: Int = 0) -> Layout {
        switch (context?.isEmpty == false, MissionChipLabel.text(missions) != nil || roomCount > 0) {
        case (true, true): return .contextAndChip
        case (false, true): return .chipOnly
        case (true, false): return .contextOnly
        case (false, false): return .none
        }
    }

    let context: String?
    let missions: ConversationMissions
    let onTapChip: () -> Void
    /// How many agent-chat rooms the conversation is in; 0 draws no chip.
    let roomCount: Int
    let onTapRooms: () -> Void
    /// The chat's displayed title, so the chip can drop a mission name the
    /// title already says (`MissionChipLabel.repeatsTitle`).
    let conversationTitle: String?
    public init(context: String?, missions: ConversationMissions, onTapChip: @escaping () -> Void,
                roomCount: Int = 0, onTapRooms: @escaping () -> Void = {}, conversationTitle: String? = nil) {
        self.context = context; self.missions = missions; self.onTapChip = onTapChip
        self.roomCount = roomCount; self.onTapRooms = onTapRooms; self.conversationTitle = conversationTitle
    }

    public var body: some View {
        switch Self.layout(context: context, missions: missions, roomCount: roomCount) {
        case .contextAndChip:
            // `ViewThatFits` compares IDEAL widths. The workdir's ideal is
            // pinned to `contextMinWidth`, so the one-line form is chosen
            // whenever 96 pt of workdir plus the whole chip fit — and then
            // it is laid out at the real width, where the workdir grows or
            // truncates while the higher-priority chip keeps its size.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    contextText
                        .frame(minWidth: Self.contextMinWidth, idealWidth: Self.contextMinWidth, maxWidth: .infinity)
                    chip.layoutPriority(1)
                }
                VStack(spacing: 1) {
                    contextText
                    chip
                }
            }
        case .chipOnly: chip
        case .contextOnly: contextText
        case .none: EmptyView()
        }
    }

    private var contextText: some View {
        Text(context ?? "")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            // The tail of a path is the part worth keeping.
            .truncationMode(.middle)
    }

    /// The mission chip, the rooms chip, or both: the rooms chip keeps its
    /// size and the mission's name truncates.
    @ViewBuilder private var chip: some View {
        if roomCount > 0 {
            HStack(spacing: 6) {
                if MissionChipLabel.text(missions) != nil { missionChip }
                Button(action: onTapRooms) { RoomsChipLabel(count: roomCount) }
                    .buttonStyle(.plain)
                    .layoutPriority(1)
                    .accessibilityIdentifier("chat.roomsChip")
            }
        } else {
            missionChip
        }
    }

    private var missionChip: some View {
        Button(action: onTapChip) { MissionChipLabel(missions: missions, conversationTitle: conversationTitle) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.missionsChip")
    }
}
