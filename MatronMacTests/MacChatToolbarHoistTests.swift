#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

private final class FakeChatForHoist: ChatService, @unchecked Sendable {
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        AsyncStream { $0.finish() }
    }
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

private final class RoomModel: ObservableObject {
    @Published var roomID = "room-a"
}

@MainActor
private func makeProps(roomID: String, strip: SubChatStripViewModel) -> MacChatToolbarProps {
    MacChatToolbarProps(
        roomID: roomID, title: "Chat \(roomID)", boxName: nil, styledTitle: nil,
        accessibilityTitle: nil, status: nil, stripViewModel: strip, missionID: nil,
        needsYouCount: 0, itemsAvailable: true,
        actions: .init(onOpenSubChat: { _ in }, onCompact: {}, onOpenMission: { _ in },
                       showMediaBrowser: .constant(false), showItemsPane: .constant(false)))
}

/// The production shape: a per-room `.id` subtree PUBLISHES its props, the
/// toolbar is declared outside that identity.
private struct HoistedHarness: View {
    @ObservedObject var model: RoomModel
    let strip: SubChatStripViewModel

    var body: some View {
        MacChatToolbarHost {
            Color.clear
                .preference(key: MacChatToolbarPreference.self, value: makeProps(roomID: model.roomID, strip: strip))
                .id(model.roomID)
        }
    }
}

/// The shape this replaced: the toolbar declared INSIDE the per-room identity.
private struct InsideIdentityHarness: View {
    @ObservedObject var model: RoomModel
    let strip: SubChatStripViewModel

    var body: some View {
        Color.clear
            .toolbar { MacChatToolbar(props: makeProps(roomID: model.roomID, strip: strip)) }
            .id(model.roomID)
    }
}

@MainActor
final class MacChatToolbarHoistTests: XCTestCase {

    func test_propsEquality_coversWhatIsDrawn_andTheRoom_notTheActions() {
        let strip = SubChatStripViewModel(chat: FakeChatForHoist(), parentConvoID: "p1")
        XCTAssertEqual(makeProps(roomID: "a", strip: strip), makeProps(roomID: "a", strip: strip),
                       "fresh closures alone must not read as a change, or every body pass republishes")
        XCTAssertNotEqual(makeProps(roomID: "a", strip: strip), makeProps(roomID: "b", strip: strip),
                          "a switch must republish so the toolbar stops acting on the room that left")
        let otherStrip = SubChatStripViewModel(chat: FakeChatForHoist(), parentConvoID: "p2")
        XCTAssertNotEqual(makeProps(roomID: "a", strip: strip), makeProps(roomID: "a", strip: otherStrip))
    }

    func test_preferenceReduce_keepsTheFirstPublisher() {
        let strip = SubChatStripViewModel(chat: FakeChatForHoist(), parentConvoID: "p1")
        var value: MacChatToolbarProps? = nil
        MacChatToolbarPreference.reduce(value: &value) { makeProps(roomID: "a", strip: strip) }
        MacChatToolbarPreference.reduce(value: &value) { makeProps(roomID: "b", strip: strip) }
        XCTAssertEqual(value?.roomID, "a")
    }

    /// The point of the hoist: a room switch keeps the window's toolbar item
    /// views instead of destroying and rebuilding them.
    func test_roomSwitch_keepsToolbarItemViews_whenHoisted() async throws {
        let (before, after) = try await itemViewsAcrossSwitch { model, strip in
            AnyView(HoistedHarness(model: model, strip: strip))
        }
        XCTAssertFalse(before.isEmpty, "the harness must actually produce toolbar items")
        XCTAssertEqual(before, after, "hoisted: the same item views must survive a room switch")
    }

    /// Control — proves the assertion above can see a rebuild at all.
    func test_roomSwitch_rebuildsToolbarItemViews_whenInsideTheRoomIdentity() async throws {
        let (before, after) = try await itemViewsAcrossSwitch { model, strip in
            AnyView(InsideIdentityHarness(model: model, strip: strip))
        }
        XCTAssertFalse(before.isEmpty, "the harness must actually produce toolbar items")
        XCTAssertNotEqual(before, after, "inside the identity every switch rebuilds the item views — the cost the hoist removes")
    }

    private func itemViewsAcrossSwitch(
        _ root: (RoomModel, SubChatStripViewModel) -> AnyView
    ) async throws -> (before: [ObjectIdentifier], after: [ObjectIdentifier]) {
        let model = RoomModel()
        let strip = SubChatStripViewModel(chat: FakeChatForHoist(), parentConvoID: "p1")
        let host = NSHostingController(rootView: root(model, strip))
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = host
        window.orderFront(nil)
        defer { window.close() }

        await Self.spin(seconds: 1)
        let before = Self.itemViews(in: window)
        model.roomID = "room-b"
        await Self.spin(seconds: 1)
        return (before, Self.itemViews(in: window))
    }

    private static func itemViews(in window: NSWindow) -> [ObjectIdentifier] {
        (window.toolbar?.items ?? []).compactMap { $0.view }.map(ObjectIdentifier.init)
    }

    private static func spin(seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
#endif
