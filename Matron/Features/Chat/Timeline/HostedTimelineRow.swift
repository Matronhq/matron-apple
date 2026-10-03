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
    var openPageLink: ((MatronPageLink) -> Void)?
    var conversationLinkHost: ConversationLinkHost?

    init(openTrackerItem: ((Int) -> Void)? = nil, openConversation: ((String) -> Void)? = nil,
         openPageLink: ((MatronPageLink) -> Void)? = nil,
         conversationLinkHost: ConversationLinkHost? = nil) {
        self.openTrackerItem = openTrackerItem
        self.openConversation = openConversation
        self.openPageLink = openPageLink
        self.conversationLinkHost = conversationLinkHost
    }

    init(_ environment: EnvironmentValues) {
        self.init(openTrackerItem: environment.openTrackerItem,
                  openConversation: environment.openConversation,
                  openPageLink: environment.openPageLink,
                  conversationLinkHost: environment.conversationLinkHost)
    }
}

extension View {
    func timelineHostedEnvironment(_ environment: TimelineHostedEnvironment) -> some View {
        self.environment(\.openTrackerItem, environment.openTrackerItem)
            .environment(\.openConversation, environment.openConversation)
            .environment(\.openPageLink, environment.openPageLink)
            .environment(\.conversationLinkHost, environment.conversationLinkHost)
    }

    /// Applies the Dynamic Type size a hosted view should render at, as a
    /// SwiftUI environment value (`\.dynamicTypeSize`) rather than a UIKit
    /// trait override — an off-window `UIHostingController`'s
    /// `traitOverrides.preferredContentSizeCategory` is silently ignored
    /// (measures at the simulator/device's current size regardless), while
    /// the environment value works everywhere. `HostedSizer` (measurement)
    /// and `HostedRowFactory` (measurement AND, later, live rendering) both
    /// call this — one source, so a measured height stays the rendered
    /// height at every Dynamic Type size, not just whatever the host
    /// happens to be running at.
    ///
    /// `DynamicTypeSize(_ uiSizeCategory: UIContentSizeCategory)` is the
    /// SDK's own failable initializer (`SwiftUI.swiftinterface`,
    /// `extension DynamicTypeSize`) — it maps all 12 categories (7 standard
    /// + 5 accessibility) and only fails for `.unspecified`, so `?? .large`
    /// only ever matters for that case.
    func timelineDynamicTypeSize(_ sizeCategory: UIContentSizeCategory) -> some View {
        environment(\.dynamicTypeSize, DynamicTypeSize(sizeCategory) ?? .large)
    }
}

/// A timeline row drawn by the existing SwiftUI views (`TimelineItemView`
/// and friends): everything that is not a plain text message. It began as a
/// mirror of the SwiftUI timeline's row view, removed 2026-09-28, and
/// differs from what that was in these ways:
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
/// - no `.contextMenu { Copy }`. A hosted row never IS a plain text item —
///   those render in their own `TextMessageCell`
///   (`TimelineRowContentBuilder` only ever produces `.hosted` for a
///   `.message` row when its kind isn't `.text`, or it's a resolved
///   subtask indicator). Copy lives on the collection view's own context
///   menu, covering every cell kind in one place.
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
                           openConversation: environment.openConversation,
                           openPageLink: environment.openPageLink)
    }

    /// `sizeCategory` is applied here (not left to the caller) so
    /// measurement (`TimelineMeasurer`, via `HostedSizer`) and live
    /// rendering (a future `HostedRowCell`, once it exists) share the
    /// exact same view — including the exact same Dynamic Type size —
    /// from this one factory, rather than each wiring the environment
    /// separately and risking drift.
    func row(_ content: HostedRowContent, sizeCategory: UIContentSizeCategory) -> AnyView {
        AnyView(HostedTimelineRow(content: content, viewModel: viewModel, actions: actions)
            .timelineHostedEnvironment(environment)
            .timelineDynamicTypeSize(sizeCategory))
    }

    func piece(_ piece: HostedPiece, sizeCategory: UIContentSizeCategory) -> AnyView {
        switch piece {
        case .pills(let text):
            return AnyView(ConversationLinkPillRow(refs: text.pills, style: text.isOwn ? .me : .bot,
                                                   hasAvatar: text.avatarSender != nil)
                .timelineHostedEnvironment(environment)
                .timelineDynamicTypeSize(sizeCategory))
        case .table(let table):
            return AnyView(MarkdownTableGrid(table: table, router: router)
                .timelineDynamicTypeSize(sizeCategory))
        }
    }

    func footer(label: String, sizeCategory: UIContentSizeCategory) -> AnyView {
        AnyView(ActivityIndicatorRow(label: label).timelineDynamicTypeSize(sizeCategory))
    }
}
