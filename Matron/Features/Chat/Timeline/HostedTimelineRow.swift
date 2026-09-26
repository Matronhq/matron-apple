import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// What rows in the UIKit timeline can ask the chat screen to do.
struct ChatTimelineActions {
    /// Push a sub-chat onto the chat's navigation path (hosted cells can't
    /// reach the `NavigationStack` through `NavigationLink(value:)`).
    var openSubChat: (String) -> Void
    var openSpawnRoom: ((String) -> Void)?
    var openItem: ((String) -> Void)?
    var openMission: ((String) -> Void)?
    /// A downloaded file attachment → the chat's file preview sheet.
    var previewFile: (URL, String) -> Void
    /// A resolved image tapped → the chat's gallery sheet.
    var tapImage: (URL, Image) -> Void

    static var inert: ChatTimelineActions {
        ChatTimelineActions(openSubChat: { _ in }, openSpawnRoom: nil, openItem: nil, openMission: nil,
                            previewFile: { _, _ in }, tapImage: { _, _ in })
    }
}

/// SwiftUI environment values hosted cells need, carried across the UIKit
/// boundary explicitly (UIKit-hosted SwiftUI doesn't inherit custom keys).
struct TimelineHostedEnvironment {
    var openTrackerItem: ((Int) -> Void)?
    var openConversation: ((String) -> Void)?
    var conversationLinkHost: ConversationLinkHost?

    init(openTrackerItem: ((Int) -> Void)? = nil, openConversation: ((String) -> Void)? = nil,
         conversationLinkHost: ConversationLinkHost? = nil) {
        self.openTrackerItem = openTrackerItem
        self.openConversation = openConversation
        self.conversationLinkHost = conversationLinkHost
    }

    init(_ environment: EnvironmentValues) {
        self.init(openTrackerItem: environment.openTrackerItem,
                  openConversation: environment.openConversation,
                  conversationLinkHost: environment.conversationLinkHost)
    }
}

extension View {
    func timelineHostedEnvironment(_ environment: TimelineHostedEnvironment) -> some View {
        self.environment(\.openTrackerItem, environment.openTrackerItem)
            .environment(\.openConversation, environment.openConversation)
            .environment(\.conversationLinkHost, environment.conversationLinkHost)
    }
}

/// Mirror of `TimelineRowView` (private struct in `ChatView.swift`, ~line
/// 1580) for the UIKit timeline's hosted rows. Same `TimelineItemView`
/// wiring, closure for closure, EXCEPT:
/// - no `Equatable` conformance and no `.equatable()` / `.id(anchorID)` at
///   a call site — the diffable data source, not SwiftUI diffing, decides
///   which cells re-render (`TimelineMeasureCache`'s content-equality gate
///   already does the "did this row actually change" job).
/// - the subtask card is always a `Button` into `actions.openSubChat`
///   (never `NavigationLink(value:)` — the hosted cell is behind a UIKit
///   boundary, on the far side of the `NavigationStack`).
/// - `onTapImage`, `onTapFile` and the subtask tap route through
///   `ChatTimelineActions` instead of individual closure properties.
/// - `hasMultipleSenders` and the subtask child live on `HostedRowContent`
///   rather than as separate properties.
/// The SwiftUI `TimelineRowView` is left untouched and is deleted together
/// with the whole SwiftUI timeline path — a change to either mirror must be
/// mirrored in the other until then.
struct HostedTimelineRow: View {
    let content: HostedRowContent
    let viewModel: ChatViewModel
    let actions: ChatTimelineActions

    var body: some View {
        switch content.row {
        case .separator(let date):
            DateSeparator(date: date)
        case .message(let item):
            if let child = content.subtaskChild {
                Button {
                    actions.openSubChat(child.id)
                } label: {
                    SubtaskLinkCard(title: child.title, isRunning: child.isRunning)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            } else {
                TimelineItemView(
                    item: item,
                    resolveImage: { viewModel.image(for: $0) },
                    onRetry: { id in viewModel.retrySend(itemID: id) },
                    onTapImage: actions.tapImage,
                    onTapFile: { mxc, filename in
                        Task {
                            if let url = await viewModel.writeTempFile(mxcURL: mxc, filename: filename) {
                                actions.previewFile(url, filename)
                            }
                        }
                    },
                    isDownloadingFile: { viewModel.isDownloadingFile($0) },
                    isMediaUnavailable: { viewModel.isMediaUnavailable($0) },
                    askViewModel: { viewModel.askViewModel(forPrompt: $0) },
                    isPromptAnswered: { viewModel.isPromptAnswered($0) },
                    answerSummary: { viewModel.answerSummary(forPrompt: $0) },
                    agentChatState: { viewModel.agentChatState($0) },
                    onAnswerAgentChat: { eventID, request, approve in
                        Task {
                            await viewModel.answerAgentChat(eventID: eventID, request: request,
                                                            decision: approve ? .approve : .deny)
                        }
                    },
                    agentSpawnState: { viewModel.agentSpawnState($0, request: $1) },
                    onAnswerAgentSpawn: { eventID, request, approve in
                        Task {
                            try? await viewModel.answerAgentSpawn(eventID: eventID, request: request,
                                                                  decision: approve ? .approve : .deny)
                        }
                    },
                    onOpenSpawnRoom: actions.openSpawnRoom,
                    onOpenItem: actions.openItem,
                    onOpenMission: actions.openMission,
                    convoID: viewModel.roomID,
                    hasMultipleSenders: content.hasMultipleSenders
                )
            }
        }
    }
}

/// Builds every hosted SwiftUI view the timeline shows or measures — one
/// source for both, so a measured height is the rendered height.
@MainActor
struct HostedRowFactory {
    let viewModel: ChatViewModel
    var actions: ChatTimelineActions
    var environment: TimelineHostedEnvironment

    var router: TimelineLinkRouter {
        TimelineLinkRouter(openTrackerItem: environment.openTrackerItem,
                           openConversation: environment.openConversation)
    }

    func row(_ content: HostedRowContent) -> AnyView {
        AnyView(HostedTimelineRow(content: content, viewModel: viewModel, actions: actions)
            .timelineHostedEnvironment(environment))
    }

    func piece(_ piece: HostedPiece) -> AnyView {
        switch piece {
        case .pills(let text):
            return AnyView(ConversationLinkPillRow(refs: text.pills, style: text.isOwn ? .me : .bot,
                                                   hasAvatar: text.avatarSender != nil)
                .timelineHostedEnvironment(environment))
        case .table(let table):
            return AnyView(MarkdownTableGrid(table: table, router: router))
        }
    }

    func footer(label: String) -> AnyView {
        AnyView(ActivityIndicatorRow(label: label))
    }
}
