import SwiftUI
import MatronModels

/// The words of a chat header's rooms control, pure so each is a plain
/// test and the Mac and iOS headers never disagree.
public enum ConversationRoomsFormat {
    /// "Rooms · 2"; `nil` for a chat that is in no room (no control).
    public static func label(count: Int) -> String? {
        count > 0 ? "Rooms · \(count)" : nil
    }

    public static func accessibilityLabel(count: Int) -> String {
        "\(count) agent chat room\(count == 1 ? "" : "s")"
    }

    /// What VoiceOver reads for one room in the list: state, then title.
    public static func rowAccessibilityLabel(_ room: ConversationRoom) -> String {
        "\(DashboardStateDot.label(room.state)), \(room.title)"
    }
}

/// The iOS chat header's "Rooms · n" chip, beside the mission chip and
/// drawn like it. The host wraps it in a Button opening the rooms sheet.
public struct RoomsChipLabel: View {
    let count: Int
    public init(count: Int) { self.count = count }

    public var body: some View {
        if let label = ConversationRoomsFormat.label(count: count) {
            Text(verbatim: label)
                .lineLimit(1)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.10), in: Capsule())
                .accessibilityLabel(ConversationRoomsFormat.accessibilityLabel(count: count))
                .accessibilityHint("Shows the agent chat rooms this conversation is in")
        }
    }
}

/// Every room a conversation is in, as rows — the iOS rooms sheet's list
/// when there is more than one. A tap opens the room.
public struct ConversationRoomsList: View {
    let rooms: [ConversationRoom]
    let onOpen: (String) -> Void
    public init(rooms: [ConversationRoom], onOpen: @escaping (String) -> Void) {
        self.rooms = rooms; self.onOpen = onOpen
    }

    public var body: some View {
        List(rooms) { room in
            Button { onOpen(room.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    DashboardStateDot(state: room.state)
                    Text(room.title).font(.body).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ConversationRoomsFormat.rowAccessibilityLabel(room))
            .accessibilityAddTraits(.isButton)
        }
    }
}
