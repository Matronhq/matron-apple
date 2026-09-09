import SwiftUI
import UIKit
import Observation

/// The two pages of the chat screen (app shell, spec §4).
enum ChatPage: Hashable {
    case chat
    case tasks
}

/// Owns which page is showing and the one side effect of paging: landing on
/// the tasks page drops the composer's keyboard; paging back does not
/// re-focus it. `resignComposer` is injectable so tests can observe it —
/// the default sends `resignFirstResponder` down the responder chain, the
/// composer being a plain `TextField` with no `@FocusState` seam of its own.
@MainActor @Observable
final class ChatPagerModel {
    var page: ChatPage = .chat
    private let resignComposer: () -> Void

    init(resignComposer: @escaping () -> Void = ChatPagerModel.resignFirstResponder) {
        self.resignComposer = resignComposer
    }

    /// Toolbar buttons. Callers wrap in `withAnimation` for the slide.
    func go(to page: ChatPage) {
        handleScrolled(to: page)
    }

    /// The pager's `.scrollPosition(id:)` write-back after a swipe.
    func handleScrolled(to page: ChatPage) {
        guard self.page != page else { return }
        self.page = page
        if page == .tasks { resignComposer() }
    }

    static func resignFirstResponder() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// Horizontal paging container: page 0 is the chat (timeline + composer),
/// page 1 the tracker. Native `.paging` gives the Instagram/X feel and the
/// interactive drag-back for free; both pages stay mounted (a plain
/// `HStack`, not lazy) so the timeline's scroll state survives paging.
/// `showsTasks == false` (unsupported journal) mounts one page only, and
/// `.scrollBounceBehavior(.basedOnSize)` makes the swipe a no-op rather
/// than a rubber-band. The pager only owns horizontal drags: the vertical
/// timeline and list scroll views underneath keep their own gestures, and
/// UIKit's leading-edge back-swipe recognizer still wins over a scroll view.
struct ChatPager<Chat: View, Tasks: View>: View {
    let model: ChatPagerModel
    let showsTasks: Bool
    @ViewBuilder let chat: () -> Chat
    @ViewBuilder let tasks: () -> Tasks

    @State private var scrolledPage: ChatPage?

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    chat()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .id(ChatPage.chat)
                    if showsTasks {
                        tasks()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(ChatPage.tasks)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollPosition(id: $scrolledPage)
            .onAppear { scrolledPage = model.page }
            // Swipe → model (keyboard rule lives there).
            .onChange(of: scrolledPage) { _, page in
                if let page { model.handleScrolled(to: page) }
            }
            // Button → scroll (the model changed first; mirror it).
            .onChange(of: model.page) { _, page in
                if scrolledPage != page { scrolledPage = page }
            }
            // A journal that turns out unsupported while on the tasks page
            // loses that page — snap home rather than strand the position.
            .onChange(of: showsTasks) { _, shows in
                if !shows { model.handleScrolled(to: .chat) }
            }
        }
    }
}
