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

    /// A swipe right anywhere on the CHAT page goes back
    /// to the conversation list (Instagram-style), not only from the
    /// leading edge. Pure so tests can pin the rule. Requires: the chat
    /// page (on the tasks page a rightward swipe pages back to the chat),
    /// a rightward, mostly horizontal drag past 80pt, and a start outside
    /// the leading 44pt — that strip belongs to UIKit's own interactive
    /// pop gesture, and firing here too would pop twice. A chat at the
    /// root of its stack (the Coordinator's, with a tab to go back to)
    /// has no UIKit pop, so there the strip is the pager's too
    /// (`leadingEdgeIsFree`).
    static func swipeBackPops(page: ChatPage, translation: CGSize, startX: CGFloat,
                              leadingEdgeIsFree: Bool = false) -> Bool {
        page == .chat
            && (leadingEdgeIsFree || startX > 44)
            && translation.width > 80
            && abs(translation.width) > abs(translation.height)
    }

    /// The page a drag began on. `.scrollPosition` writes the new page back
    /// MID-drag (Bugbot, PR #194), so `endDrag` judges the swipe-back rule
    /// against this, not `page` — otherwise a rightward swipe from the
    /// tasks page reads as "chat page, wide rightward drag" and pops.
    private var pageAtDragStart: ChatPage?

    func beginDrag() {
        if pageAtDragStart == nil { pageAtDragStart = page }
    }

    /// Ends a drag; returns whether it was a swipe back (see `swipeBackPops`).
    func endDrag(translation: CGSize, startX: CGFloat, leadingEdgeIsFree: Bool = false) -> Bool {
        let start = pageAtDragStart ?? page
        pageAtDragStart = nil
        return Self.swipeBackPops(page: start, translation: translation, startX: startX,
                                  leadingEdgeIsFree: leadingEdgeIsFree)
    }

    /// The tracker pane's width beside the chat, as the Mac's items pane.
    static let trackerPaneWidth: CGFloat = 340

    /// The narrowest chat column the tracker pane is put beside; below it
    /// the tracker is a page away, as on iPhone.
    static let minChatWidthBesideTracker: CGFloat = 420

    /// Whether the tracker sits beside the chat: only in the iPad's split
    /// shell, only when the column fits both, and not while the user has
    /// hidden the pane.
    static func showsTrackerAlongside(inSplitShell: Bool, width: CGFloat, paneHidden: Bool) -> Bool {
        inSplitShell && !paneHidden && width >= trackerPaneWidth + minChatWidthBesideTracker
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
    /// Fired for a full-width rightward swipe on the chat page (see
    /// `ChatPagerModel.swipeBackPops`); `ChatView` pops the outer stack.
    var onSwipeBack: (() -> Void)? = nil
    /// No UIKit pop owns the leading edge (see `swipeBackPops`).
    var leadingEdgeIsFree = false
    /// The tracker may sit beside the chat instead of a page away: the
    /// iPad's split shell, pane not hidden. It does once the pager's own
    /// width fits both (`ChatPagerModel.showsTrackerAlongside`), decided
    /// here from the first layout so the pane never pops in a frame late.
    /// No paging and no swipe back then; `model.page` stays `.chat`.
    var tasksAlongsideAllowed = false
    @ViewBuilder let chat: () -> Chat
    @ViewBuilder let tasks: () -> Tasks

    @State private var scrolledPage: ChatPage?

    var body: some View {
        GeometryReader { geo in
            let tasksAlongside = tasksAlongsideAllowed && showsTasks && ChatPagerModel.showsTrackerAlongside(
                inSplitShell: true, width: geo.size.width, paneHidden: false)
            ScrollView(.horizontal) {
                // One structure for both layouts: switching the pane in
                // or out only resizes the pages, so the chat page is never
                // remounted (a remount restarts the timeline's load).
                let pane = tasksAlongside ? ChatPagerModel.trackerPaneWidth : geo.size.width
                HStack(spacing: 0) {
                    chat()
                        .frame(width: tasksAlongside ? geo.size.width - pane : geo.size.width,
                               height: geo.size.height)
                        .id(ChatPage.chat)
                    if showsTasks {
                        tasks()
                            .frame(width: pane, height: geo.size.height)
                            .overlay(alignment: .leading) {
                                if tasksAlongside {
                                    Rectangle().fill(.separator).frame(width: 1 / 3)
                                        .ignoresSafeArea()
                                }
                            }
                            .id(ChatPage.tasks)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollDisabled(tasksAlongside)
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
            // Full-width swipe back. `simultaneous` so it never steals the
            // pager's own paging drag or the vertical timeline scroll; the
            // rule only fires on the chat page, where a rightward drag has
            // nowhere to page to anyway (page 0 just rubber-bands).
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { _ in model.beginDrag() }
                    .onEnded { v in
                        if model.endDrag(translation: v.translation, startX: v.startLocation.x,
                                         leadingEdgeIsFree: leadingEdgeIsFree), !tasksAlongside {
                            onSwipeBack?()
                        }
                    }
            )
        }
    }
}
