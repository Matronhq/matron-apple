#if os(macOS)
import XCTest
import SwiftUI
import UniformTypeIdentifiers
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

/// Local fake mirroring `FakeTimelineService` from
/// `MatronShared/Tests/ViewModelTests/`. The Mac test target is
/// self-contained — it doesn't pull the shared test fakes (those live in
/// the test target, not the shipped library).
private final class FakeTimelineForChat: TimelineService, @unchecked Sendable {
    var sentImages: [(filename: String, mime: String, sizeBytes: Int)] = []
    var sentFiles: [(filename: String, mime: String, sizeBytes: Int)] = []

    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String) async throws {
        sentImages.append((filename, mimeType, data.count))
    }
    func sendFile(_ data: Data, filename: String, mimeType: String) async throws {
        sentFiles.append((filename, mimeType, data.count))
    }
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}
}

private final class FakeMediaForChat: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

/// Minimal `ChatService` fake for building a `SubChatStripViewModel` in the
/// view-construction test. Only `children(of:)` is exercised; the rest are
/// inert stubs.
private final class FakeChatForSubStrip: ChatService, @unchecked Sendable {
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        AsyncStream { $0.finish() }
    }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

@MainActor
final class MacChatViewTests: XCTestCase {

    /// SwiftUI's `DropInfo` is a struct with no public init, so we can't
    /// drive `performDrop(info:)` from a unit test. Instead we cover the
    /// URL-handling logic the delegate factors out:
    /// `ComposerDropDelegate.loadURL(from:)`. That's the only branch with
    /// real logic — the `performDrop` body itself is `getProviders →
    /// loadURL × N → composer.attachFiles`.
    func test_loadURL_returnsURL_fromItemProvider() async {
        let url = URL(fileURLWithPath: "/tmp/test.png")
        let provider = NSItemProvider()
        provider.registerObject(url as NSURL, visibility: .all)
        let resolved = await ComposerDropDelegate.loadURL(from: provider)
        if case .success(let resolvedURL) = resolved {
            XCTAssertEqual(resolvedURL.lastPathComponent, "test.png")
        } else {
            XCTFail("Expected .success(URL), got \(resolved)")
        }
    }

    /// Empty provider → failure (QA finding #9). Previously the helper
    /// silently returned nil for both "no URL" and "load failed", so the
    /// composer banner never surfaced when a drop failed. Now an empty
    /// provider routes through the typed `ComposerDropError`.
    func test_loadURL_returnsFailure_forEmptyProvider() async {
        let provider = NSItemProvider()
        let resolved = await ComposerDropDelegate.loadURL(from: provider)
        if case .failure = resolved {
            // expected
        } else {
            XCTFail("Expected .failure, got \(resolved)")
        }
    }

    /// `⌘K` toggles the slash palette open without typing `/`. The view
    /// wires `palettePinnedOpen.toggle()` to a hidden button with
    /// `.keyboardShortcut("k", modifiers: .command)`; here we verify the
    /// model surface honours the toggle as `MacChatView` expects.
    func test_palettePinnedOpen_togglesPalette() {
        let composer = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineForChat(),
                                          commands: BotCommandCatalog.claudeBridge)
        XCTAssertFalse(composer.showPalette)
        composer.palettePinnedOpen = true
        XCTAssertTrue(composer.showPalette)
        composer.palettePinnedOpen = false
        XCTAssertFalse(composer.showPalette)
    }

    /// Task 16: right-click "View source" presents a `MacEventSourceSheet`
    /// whose body is `item.prettyJSON()`. Constructing the sheet here
    /// exercises the binding wiring; the underlying JSON shape is
    /// verified at the SPM level in `TimelineItemTests`.
    func test_macEventSourceSheet_compiles_andInvokesDismiss() {
        let item = TimelineItem(
            id: "$evt:mac:1",
            sender: "@bot:s",
            timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil),
            isOwn: false
        )
        var dismissals = 0
        let sheet = MacEventSourceSheet(item: item, onDismiss: { dismissals += 1 })
        XCTAssertEqual(sheet.item.id, "$evt:mac:1")
        // Invoke the dismiss closure directly to verify the binding is
        // plumbed through (the SwiftUI body itself isn't rendered here).
        sheet.onDismiss()
        XCTAssertEqual(dismissals, 1)
        XCTAssertTrue(item.prettyJSON().contains("$evt:mac:1"))
    }

    /// Constructing the view exercises the @State + binding wiring at
    /// compile time; the body itself isn't rendered in this unit test
    /// (no host scene).
    func test_view_compiles_withChatViewModel_andComposerViewModel() {
        let timeline = FakeTimelineForChat()
        let chatVM = ChatViewModel(roomID: "!r:s", timeline: timeline, media: FakeMediaForChat())
        let composerVM = ComposerViewModel(roomID: "!test:s", timeline: timeline, commands: [])
        let stripVM = SubChatStripViewModel(chat: FakeChatForSubStrip(), parentConvoID: "!r:s")
        let view = MacChatView(
            viewModel: chatVM,
            composerVM: composerVM,
            stripViewModel: stripVM,
            subChatProvider: { _ in (chatVM, stripVM) },
            chatTitle: "Hello"
        )
        XCTAssertEqual(view.chatTitle, "Hello")
    }

}
#endif
