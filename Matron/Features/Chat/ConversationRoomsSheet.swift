import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// The agent-chat rooms a conversation is in, as a sheet over its chat
/// (Dan, 2026-10-01): the iPhone's form of the Mac's side pane. One room
/// opens straight on its timeline; several open on a list, each pushing
/// its timeline inside the sheet. The timeline is the read-only sub-chat
/// viewer; "Open as chat" leaves the sheet for the room's own chat, which
/// has a composer.
struct ConversationRoomsSheet: View {
    /// The chat's live room list: titles and states follow it while the
    /// sheet is up.
    let rooms: [ConversationRoom]
    let provider: (String) -> (ChatViewModel, SubChatStripViewModel)
    /// Dismisses the sheet, then opens the room on the chat's stack.
    let onOpenAsChat: (String) -> Void
    /// Dismisses the sheet, then runs the action — for links tapped in a
    /// room's timeline, whose destinations are under the sheet.
    let leaveThen: (@escaping () -> Void) -> Void

    /// Whether the sheet opened on one room or on the list, fixed when it
    /// appears: a room arriving or leaving while it is up must not swap
    /// the page under the reader.
    @State private var soleRoomID: String?
    @State private var path: [String] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openTrackerItem) private var openTrackerItemUnderneath
    @Environment(\.openConversation) private var openConversationUnderneath

    init(rooms: [ConversationRoom], provider: @escaping (String) -> (ChatViewModel, SubChatStripViewModel),
         onOpenAsChat: @escaping (String) -> Void, leaveThen: @escaping (@escaping () -> Void) -> Void) {
        self.rooms = rooms
        self.provider = provider
        self.onOpenAsChat = onOpenAsChat
        self.leaveThen = leaveThen
        _soleRoomID = State(initialValue: Self.soleRoomID(rooms))
    }

    /// The room the sheet opens straight on: the only one there is.
    static func soleRoomID(_ rooms: [ConversationRoom]) -> String? {
        rooms.count == 1 ? rooms.first?.id : nil
    }

    static func title(of roomID: String, in rooms: [ConversationRoom]) -> String {
        rooms.first { $0.id == roomID }?.title ?? "Room"
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let soleRoomID {
                    room(soleRoomID)
                } else {
                    ConversationRoomsList(rooms: rooms) { path.append($0) }
                        .navigationTitle("Rooms")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { room($0) }
        }
        // The sheet has its own stack: the chat's is under it.
        .environment(\.chatNavigationPath, nil)
        .environment(\.openTrackerItem, openTrackerItemUnderneath.map { open in
            { number in leaveThen { open(number) } }
        })
        .environment(\.openConversation, openConversationUnderneath.map { open in
            { convoID in leaveThen { open(convoID) } }
        })
    }

    private func room(_ roomID: String) -> some View {
        let (chatVM, stripVM) = provider(roomID)
        return SubChatView(viewModel: chatVM, stripViewModel: stripVM, childID: roomID,
                           fallbackTitle: Self.title(of: roomID, in: rooms), isRoom: true)
            // Identity per room, so its `@State` view models are the
            // room's own (see `ChatDestinationView`).
            .id(roomID)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { onOpenAsChat(roomID) } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .accessibilityLabel("Open this room as a chat")
                    .accessibilityIdentifier("rooms.openAsChat")
                }
            }
    }
}
