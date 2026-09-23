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

/// Coordinator: a 72 pt sidebar with no room for toolbar items, so the
/// shell hands Back/Forward to the chat header instead.
private struct CoordinatorHarness: View {
    let navigation: MacNavigationActions
    let strip: SubChatStripViewModel

    var body: some View {
        NavigationSplitView {
            List { Text("nav") }
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 72, ideal: 72, max: 72)
                .toolbar { MacCoordinatorToolbarPlaceholder() }
        } detail: {
            MacChatHeaderHost(navigation: navigation) {
                Color.clear.preference(key: MacChatToolbarPreference.self, value: MacChatToolbarProps(
                    roomID: "k", publisher: UUID(), title: "Coordinator", boxName: nil, styledTitle: nil,
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

    /// Dan, #2608: on Coordinator the chevrons must be on screen too. They
    /// ride in the chat header as a capsule at its leading edge, and the
    /// capsule is a click target (not title bar).
    func test_coordinator_headerCarriesTheChevrons_asAClickableCapsule() async throws {
        let strip = SubChatStripViewModel(chat: NoChildrenChat(), parentConvoID: "p")
        var backs = 0
        let navigation = MacNavigationActions(canGoBack: true, canGoForward: false,
                                              goBack: { backs += 1 }, goForward: {})
        let host = NSHostingController(rootView: CoordinatorHarness(navigation: navigation, strip: strip))
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1300, height: 600))
        window.orderFront(nil)
        defer { window.close() }

        var accessory: MacChatHeaderAccessory?
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            accessory = MacChatHeaderAccessory.existing(in: window)
            if accessory?.model.navigation != nil, accessory?.hitRegions.capsules.isEmpty == false { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let header = try XCTUnwrap(accessory, "the chat column must install the header accessory")
        let published = try XCTUnwrap(header.model.navigation, "the header must receive the window's Back/Forward")
        XCTAssertTrue(published.canGoBack)
        XCTAssertFalse(published.canGoForward)
        published.goBack()
        XCTAssertEqual(backs, 1)
        let leading = header.hitRegions.capsules.min { $0.minX < $1.minX }
        XCTAssertNotNil(leading)
        XCTAssertLessThan(leading?.minX ?? .infinity, 20, "the chevron capsule sits at the header's leading edge")

        // Dan, #2608: with no sidebar toolbar item at all the title bar
        // shrank to 32 pt and cropped the 52 pt header.
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        let titleBar = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThanOrEqual(titleBar, MacChatHeaderAccessory.height,
                                    "the title bar must be tall enough for the header, got \(titleBar)")
        XCTAssertFalse(Self.hasClippedIndicator(in: window.contentView?.superview),
                       "the placeholder must not be folded into the » overflow")
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
