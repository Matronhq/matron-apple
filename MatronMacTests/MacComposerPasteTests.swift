#if os(macOS)
import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import MatronMac
import MatronViewModels

/// Pins the ⌘V-to-attachment path, which shipped broken because nothing
/// covered it: an image-only pasteboard left AppKit's Paste item disabled, so
/// ⌘V beeped and the composer's claim never ran.
///
/// Every test uses a uniquely-named private `NSPasteboard`. Never
/// `NSPasteboard.general` — these run on a developer's machine and would
/// destroy the clipboard they're working with.
final class MacComposerPasteTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []

    override func tearDown() {
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards = []
        super.tearDown()
    }

    private func makePasteboard(
        _ flavours: [(NSPasteboard.PasteboardType, Data)],
        function: String = #function
    ) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MatronTest-\(function)-\(UUID())"))
        pasteboards.append(pasteboard)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in flavours { item.setData(data, forType: type) }
        pasteboard.writeObjects([item])
        return pasteboard
    }

    /// A 1×1 PNG — real bytes, so `UTType` conformance and data reads behave
    /// as they do for a Slack copy.
    private var pngData: Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }

    // MARK: - Classification

    /// The shape Slack (and any Chromium app) writes: a modern PNG flavour
    /// alongside private `org.chromium.*` flavours that have no `UTType`.
    func test_chromiumImageCopy_classifiesAsAttachment() {
        let pasteboard = makePasteboard([
            (.png, pngData),
            (NSPasteboard.PasteboardType("org.chromium.source-url"), Data("https://x".utf8)),
        ])

        let attachments = PasteboardAttachmentBridge.attachments(on: pasteboard)

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.registeredTypeIdentifiers, [UTType.png.identifier])
    }

    /// The bytes of a copied image beside a file promise: the promise's
    /// flavour has no `UTType`, so the name has to be read off the item.
    func test_filePromiseName_becomesTheSuggestedName() async throws {
        let pasteboard = makePasteboard([
            (.png, pngData),
            (NSPasteboard.PasteboardType("com.apple.pasteboard.promised-suggested-file-name"),
             Data("Holiday photo.png".utf8)),
        ])

        let provider = try XCTUnwrap(PasteboardAttachmentBridge.attachments(on: pasteboard).first)
        XCTAssertEqual(provider.suggestedName, "Holiday photo.png")

        let staged = try await PastedAttachment.stage(provider)
        addTeardownBlock { PastedAttachment.removeStagingFile(staged) }
        XCTAssertEqual(staged.lastPathComponent, "Holiday photo.png")
    }

    /// What a copy in Finder puts on the pasteboard, down to the
    /// `file:///.file/id=` reference form that holds no name of its own.
    func test_finderFileCopy_keepsTheFilesName() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Quarterly report v2.pdf")
        try Data("%PDF-1.4".utf8).write(to: file)
        let reference = try XCTUnwrap((file as NSURL).fileReferenceURL())
        let pasteboard = makePasteboard([(.fileURL, Data(reference.absoluteString.utf8))])

        let provider = try XCTUnwrap(PasteboardAttachmentBridge.attachments(on: pasteboard).first)
        let staged = try await PastedAttachment.stage(provider)

        addTeardownBlock { PastedAttachment.removeStagingFile(staged) }
        XCTAssertEqual(staged.lastPathComponent, "Quarterly report v2.pdf")
        XCTAssertEqual(try Data(contentsOf: staged), Data("%PDF-1.4".utf8))
    }

    /// A file dragged from Finder, through SwiftUI's real drop handling. For a
    /// PDF or an image, SwiftUI offers only the content type and no file URL,
    /// so the drop reaches the staging path with no name in sight.
    func test_droppedFinderFile_keepsItsName() async throws {
        for name in ["Sample cover.pdf", "Team photo.png"] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent(name)
            try Data("bytes".utf8).write(to: file)
            let pasteboard = makePasteboard([(.fileURL, Data(file.absoluteString.utf8))])

            let providers = try await droppedProviders(from: pasteboard)
            let provider = try XCTUnwrap(providers.first)
            XCTAssertFalse(provider.canLoadObject(ofClass: URL.self),
                           "SwiftUI now hands over a file URL: this path may no longer be needed")

            let loaded = try await ComposerDropDelegate.loadAttachment(from: provider).get()
            addTeardownBlock { PastedAttachment.removeStagingFile(loaded.url) }
            XCTAssertEqual(loaded.url.lastPathComponent, name)
            XCTAssertEqual(try Data(contentsOf: loaded.url), Data("bytes".utf8))
        }
    }

    /// Runs a drag on `pasteboard` through a real `.onDrop` and returns what
    /// SwiftUI hands the app. No mouse and no system drag pasteboard involved.
    @MainActor
    private func droppedProviders(from pasteboard: NSPasteboard) async throws -> [NSItemProvider] {
        var received: [NSItemProvider] = []
        let host = NSHostingView(rootView: Color.clear.frame(width: 100, height: 100)
            .contentShape(Rectangle())
            .onDrop(of: ComposerDropDelegate.acceptedTypes, isTargeted: nil) { providers in
                received = providers
                return true
            })
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))

        func destination(in view: NSView) -> NSView? {
            if !view.registeredDraggedTypes.isEmpty { return view }
            return view.subviews.lazy.compactMap(destination(in:)).first
        }
        let target = try XCTUnwrap(destination(in: host))
        let drag = FakeDrag(pasteboard: pasteboard, window: window)
        _ = target.draggingEntered(drag)
        _ = target.draggingUpdated(drag)
        _ = target.prepareForDragOperation(drag)
        _ = target.performDragOperation(drag)
        try await Task.sleep(for: .milliseconds(100))
        return received
    }

    /// Pins why the bridge needs no legacy-flavour mapping, which otherwise
    /// looks like an omission next to `ComposerTextView.legacyAttachmentFlavors`.
    ///
    /// A legacy name has no `UTType` and can't be written to a modern
    /// pasteboard item at all; the old `declareTypes` API translates it to
    /// the modern UTI on the way in. So an app copying via the legacy API
    /// still lands as `public.png`, and the bridge claims it.
    func test_legacyFlavourNames_areTranslatedByTheSystem_soNoMappingIsNeeded() {
        XCTAssertNil(UTType("Apple PNG pasteboard type"))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MatronTest-legacy-\(UUID())"))
        pasteboards.append(pasteboard)
        pasteboard.declareTypes([NSPasteboard.PasteboardType("Apple PNG pasteboard type")], owner: nil)
        pasteboard.setData(pngData, forType: NSPasteboard.PasteboardType("Apple PNG pasteboard type"))

        XCTAssertEqual(
            (pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) },
            [UTType.png.identifier],
            "the system stores the modern UTI, not the legacy name"
        )
        XCTAssertEqual(PasteboardAttachmentBridge.attachments(on: pasteboard).count, 1)
    }

    func test_textPasteboard_claimsNothing() {
        let pasteboard = makePasteboard([(.string, Data("hello".utf8))])

        XCTAssertTrue(PasteboardAttachmentBridge.attachments(on: pasteboard).isEmpty)
        XCTAssertTrue(PasteboardAttachmentBridge.readableTypesToOffer(on: pasteboard).isEmpty)
    }

    // MARK: - The AppKit Paste gate

    /// The actual bug: with the composer's configuration a PNG-only
    /// pasteboard matches nothing readable, so AppKit disables Paste and ⌘V
    /// beeps without ever calling `paste(_:)`.
    func test_imagePasteboard_isUnreadableByAPlainTextView() {
        let pasteboard = makePasteboard([(.png, pngData)])
        let textView = NSTextView(frame: .zero)
        textView.isRichText = false
        textView.importsGraphics = false

        XCTAssertNil(
            pasteboard.availableType(from: textView.readablePasteboardTypes),
            "a stock plain text view offers no image flavour — this is what disabled Paste"
        )
    }

    /// …and offering the pasteboard's own flavours is what re-enables it.
    func test_offeredTypes_makeTheImagePasteboardReadable() {
        let pasteboard = makePasteboard([(.png, pngData)])
        let textView = ComposerTextView(frame: .zero)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.attachablePasteboardTypes = {
            PasteboardAttachmentBridge.readableTypesToOffer(on: pasteboard)
        }

        XCTAssertEqual(
            pasteboard.availableType(from: textView.readablePasteboardTypes),
            .png
        )
    }

    /// A text-only pasteboard must validate exactly as before — the fix adds
    /// nothing, so ordinary text paste is untouched.
    func test_offeredTypes_leaveATextPasteboardUnchanged() {
        let pasteboard = makePasteboard([(.string, Data("hello".utf8))])
        let textView = ComposerTextView(frame: .zero)
        let stock = NSTextView(frame: .zero)
        textView.attachablePasteboardTypes = {
            PasteboardAttachmentBridge.readableTypesToOffer(on: pasteboard)
        }

        XCTAssertEqual(
            textView.readablePasteboardTypes.map(\.rawValue),
            stock.readablePasteboardTypes.map(\.rawValue)
        )
    }

    /// Widening `readablePasteboardTypes` also widens what AppKit derives for
    /// drags, so pin that images still fall through to the chat column's drop
    /// target and its "Drop here to add" overlay (PR #86).
    func test_wideningReadableTypes_doesNotStealImageDrags() {
        let pasteboard = makePasteboard([(.png, pngData)])
        let textView = ComposerTextView(frame: .zero)
        textView.attachablePasteboardTypes = {
            PasteboardAttachmentBridge.readableTypesToOffer(on: pasteboard)
        }

        XCTAssertFalse(textView.acceptableDragTypes.contains(.png))
        XCTAssertFalse(textView.acceptableDragTypes.contains(.fileURL))
    }
}
/// Stands in for AppKit's drag so a test can drive a real drop destination.
private final class FakeDrag: NSObject, NSDraggingInfo {
    private let pasteboard: NSPasteboard
    private let window: NSWindow

    init(pasteboard: NSPasteboard, window: NSWindow) {
        self.pasteboard = pasteboard
        self.window = window
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggingLocation: NSPoint { NSPoint(x: 50, y: 50) }
    var draggedImageLocation: NSPoint { NSPoint(x: 50, y: 50) }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 1 } set {} }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

#endif
