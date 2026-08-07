#if os(macOS)
import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import MatronMac

/// Pins the ⌘V-to-attachment path, which shipped broken because nothing
/// covered it: an image-only pasteboard left AppKit's Paste item disabled, so
/// ⌘V beeped and the composer's claim never ran (Dan, 2026-08-07).
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
#endif
