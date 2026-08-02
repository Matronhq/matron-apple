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
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {
        sentImages.append((filename, mimeType, data.count))
    }
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {
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

    /// The classification rule behind `ComposerTextView`'s drag-type
    /// filtering: file/image/media flavors fall through to the chat
    /// column's drop target ("Drop here to add"), text flavors stay with
    /// the text view so dragging text into the composer keeps working.
    func test_isAttachmentDragType_classifiesFileAndImageFlavors() {
        // Must fall through to the attachment drop target.
        XCTAssertTrue(ComposerTextView.isAttachmentDragType(.fileURL))
        XCTAssertTrue(ComposerTextView.isAttachmentDragType(.tiff))
        XCTAssertTrue(ComposerTextView.isAttachmentDragType(.png))
        XCTAssertTrue(ComposerTextView.isAttachmentDragType(
            .init("NSFilenamesPboardType")))
        XCTAssertTrue(ComposerTextView.isAttachmentDragType(
            .init("com.apple.pasteboard.promised-file-url")))
        XCTAssertTrue(ComposerTextView.isAttachmentDragType(
            .init("Apple PNG pasteboard type")))
        XCTAssertTrue(ComposerTextView.isAttachmentDragType(
            .init(UTType.mpeg4Movie.identifier)))
        // Must stay with the text view.
        XCTAssertFalse(ComposerTextView.isAttachmentDragType(.string))
        XCTAssertFalse(ComposerTextView.isAttachmentDragType(.rtf))
        XCTAssertFalse(ComposerTextView.isAttachmentDragType(
            .init(UTType.utf8PlainText.identifier)))
    }

    /// Pins the invariant behind bugbot's PR #86 finding: any modern
    /// flavor the input field declines must be one the chat column
    /// accepts — a flavor declined by `ComposerTextView` and rejected by
    /// `ComposerDropDelegate.acceptedTypes` would make the drag go dead
    /// (no insertion, no attachment, no overlay).
    func test_columnAcceptsEverythingTheComposerDeclines() {
        let modernFlavors: [UTType] = [
            .fileURL, .png, .tiff, .jpeg, .gif, .heic, .webP,
            .mpeg4Movie, .quickTimeMovie, .avi,
            .mp3, .wav, .mpeg4Audio,
            // The modern identities of the legacy flavors the composer
            // strips ("Apple PDF pasteboard type", "Apple PICT pasteboard
            // type", QuickTime 'moov') — legacy raw strings have no
            // UTType, so their modern equivalents stand in here.
            .pdf, .init("com.apple.pict")!, .init("com.apple.quicktime-movie")!,
        ]
        for flavor in modernFlavors {
            guard ComposerTextView.isAttachmentDragType(.init(flavor.identifier)) else { continue }
            XCTAssertTrue(
                ComposerDropDelegate.acceptedTypes.contains { flavor.conforms(to: $0) },
                "\(flavor.identifier) is declined by the composer but not accepted by the chat column")
        }
    }

    /// A provider with no URL representation — an image dragged off a web
    /// page arrives as raw data — must resolve through the
    /// `PastedAttachment.stage` fallback to a readable temp file rather
    /// than failing (bugbot, PR #86: the input field declines these
    /// flavors now, so the column has to land them).
    func test_loadURL_stagesDataOnlyProvider() async throws {
        let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier, visibility: .all
        ) { completion in
            completion(payload, nil)
            return nil
        }
        let resolved = await ComposerDropDelegate.loadURL(from: provider)
        switch resolved {
        case .success(let url):
            XCTAssertEqual(try Data(contentsOf: url), payload)
            try? FileManager.default.removeItem(at: url)
        case .failure(let error):
            XCTFail("Expected staged temp URL, got \(error)")
        }
    }

    /// A live `ComposerTextView` must not declare file/image drag
    /// flavors — any it declares get handled as a text insertion,
    /// swallowing drops over the input field before the chat column's
    /// `.onDrop` (and its "Drop here to add" overlay) could react.
    /// `acceptableDragTypes` is the surface AppKit's drag registration
    /// derives from (the modern text system leaves
    /// `registeredDraggedTypes` empty, so that's not assertable). Text
    /// flavors must survive so text drags still insert.
    func test_composerTextView_acceptsTextButNotFileDragTypes() {
        let textView = ComposerTextView()
        textView.isEditable = true
        let acceptable = textView.acceptableDragTypes
        XCTAssertFalse(acceptable.isEmpty,
                       "Text drags should still be accepted")
        let leaked = acceptable.filter { ComposerTextView.isAttachmentDragType($0) }
        XCTAssertTrue(leaked.isEmpty,
                      "File/image drag flavors leaked into acceptance: \(leaked)")
        XCTAssertTrue(
            acceptable.contains { $0.rawValue.contains("String")
                || UTType($0.rawValue)?.conforms(to: .text) == true },
            "Plain-text drags must keep working in the composer, got: \(acceptable)")
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
