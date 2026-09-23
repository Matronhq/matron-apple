#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

private final class NoChildrenChat: ChatService, @unchecked Sendable {
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> { AsyncStream { $0.finish() } }
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> { AsyncThrowingStream { $0.finish() } }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

/// App-shaped: the sidebar carries the shell's toolbar (Back/Forward, the
/// spacer, New Chat) in the same modifier order as `MacChatListView`, and
/// the detail installs the chat header accessory, which is what leaves the
/// detail section of the NSToolbar zero-width.
private struct ShellToolbarHarness: View {
    let history: MacNavigationHistory
    let strip: SubChatStripViewModel

    var body: some View {
        NavigationSplitView {
            List { Text("sidebar") }
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 472, ideal: 472, max: 472)
                .toolbar {
                    MacHistoryToolbarItems(history: history, goBack: {}, goForward: {})
                    #if compiler(>=6.2)
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible, placement: .primaryAction)
                    }
                    #endif
                    ToolbarItem(placement: .primaryAction) { Button("New") {} }
                }
        } detail: {
            MacChatHeaderHost {
                Color.clear.preference(key: MacChatToolbarPreference.self, value: MacChatToolbarProps(
                    roomID: "r", publisher: UUID(), title: "Chat", boxName: nil, styledTitle: nil,
                    accessibilityTitle: nil, status: nil, stripViewModel: strip, missionID: nil,
                    needsYouCount: 0, itemsAvailable: true,
                    actions: .init(onOpenSubChat: { _ in }, onCompact: {}, onOpenMission: { _ in },
                                   showMediaBrowser: .constant(false), showItemsPane: .constant(false))))
            }
        }
    }
}

/// Dan, #2608: the Back/Forward chevrons sat in AppKit's `»` overflow
/// however wide the window was. `.navigation` placement put them in the
/// detail section, which the chat header accessory leaves zero-width.
@MainActor
final class MacHistoryToolbarTests: XCTestCase {
    func test_chevrons_areVisibleInTheSidebarSection_notFoldedIntoOverflow() async throws {
        let strip = SubChatStripViewModel(chat: NoChildrenChat(), parentConvoID: "p")
        let host = NSHostingController(rootView: ShellToolbarHarness(history: MacNavigationHistory(), strip: strip))
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1300, height: 600))
        window.orderFront(nil)
        defer { window.close() }

        let end = Date().addingTimeInterval(2)
        while Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        XCTAssertFalse(Self.hasClippedIndicator(in: window.contentView?.superview),
                       "an item was folded into the » overflow")
        let visibleButtons = (window.toolbar?.visibleItems ?? []).compactMap(\.view).filter {
            $0.convert($0.bounds, to: nil).maxX <= 472
        }
        XCTAssertGreaterThanOrEqual(visibleButtons.count, 2,
                                    "Back and Forward must be visible inside the 472 pt sidebar section")
    }

    private static func hasClippedIndicator(in view: NSView?) -> Bool {
        guard let view else { return false }
        if String(describing: type(of: view)).contains("ClippedItemsIndicator"), !view.isHidden, view.frame.width > 0 {
            return true
        }
        return view.subviews.contains { hasClippedIndicator(in: $0) }
    }
}
#endif
