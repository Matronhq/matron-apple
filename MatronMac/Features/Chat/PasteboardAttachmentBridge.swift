import AppKit
import UniformTypeIdentifiers
import MatronViewModels

/// Bridges `NSPasteboard` into the `NSItemProvider` currency
/// `PastedAttachment` speaks, and answers the question AppKit asks *before*
/// it will even offer Paste.
///
/// The gate is the load-bearing part, and it is not what you'd guess. The
/// composer's text view is deliberately plain — `isRichText = false`,
/// `importsGraphics = false`, so pasted text can't drag a source font in —
/// and the side effect (measured 2026-08-07) is that its
/// `readablePasteboardTypes` carries no image flavour at all. AppKit then
/// *disables* the Edit ▸ Paste item for an image-only pasteboard, so ⌘V
/// beeps and `paste(_:)` is never called: the composer's attachment claim
/// never got a look in, and because nothing ran there was no error to show
/// either. Pasting a *file* worked the whole time because
/// `NSFilenamesPboardType` and `public.url` ARE readable.
///
/// iOS hit the identical gate in July — see
/// `ComposerPasteSupport.allowImagePasteMenu`, where a `UITextView` gates
/// Paste on `hasStrings || (allowsEditingTextAttributes && hasImages)`.
/// This is the AppKit half of the same bug.
enum PasteboardAttachmentBridge {
    /// Wraps one pasteboard item so `PastedAttachment` can classify it.
    ///
    /// Flavours without a `UTType` are skipped, and deliberately so. That
    /// looks like it would drop the legacy AppKit names
    /// (`Apple PNG pasteboard type`, `NeXT TIFF v4.0 pasteboard type`) that
    /// `ComposerTextView.legacyAttachmentFlavors` handles for drags — it
    /// doesn't, because those names never reach a pasteboard *item*. Probed
    /// on macOS 26: `NSPasteboardItem.setData` rejects them outright
    /// ("not a valid UTI string"), and the older `declareTypes` API
    /// translates them to `public.png` / `public.tiff` on the way in. They
    /// describe what a *view declares it can read*, not what a writer
    /// stores. The skipped flavours in practice are private ones nobody can
    /// attach anyway — `org.chromium.source-url` and friends.
    static func provider(for item: NSPasteboardItem) -> NSItemProvider {
        let provider = NSItemProvider()
        for type in item.types where UTType(type.rawValue) != nil {
            provider.registerDataRepresentation(
                forTypeIdentifier: type.rawValue, visibility: .all
            ) { completion in
                completion(item.data(forType: type), nil)
                return nil
            }
        }
        return provider
    }

    /// The items on `pasteboard` that should become attachments rather than
    /// text, in pasteboard order.
    ///
    /// Pure, and deliberately so: menu validation calls this every time the
    /// Edit menu opens, so staging anything here would attach files the user
    /// never pasted.
    static func attachments(on pasteboard: NSPasteboard) -> [NSItemProvider] {
        (pasteboard.pasteboardItems ?? [])
            .map(provider(for:))
            .filter { PastedAttachment.classify($0) != .text }
    }

    /// The flavours to add to the text view's `readablePasteboardTypes` so
    /// AppKit enables Paste for this pasteboard.
    ///
    /// Returns the pasteboard's own flavours rather than a fixed list, which
    /// is what keeps the gate honest for formats nobody enumerated — HEIC,
    /// WebP, GIF, a zip — instead of only the handful we thought to name.
    /// Empty when there's nothing to attach, so a text-only pasteboard
    /// validates exactly as it does today.
    static func readableTypesToOffer(on pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        guard !attachments(on: pasteboard).isEmpty else { return [] }
        return (pasteboard.pasteboardItems ?? []).flatMap(\.types)
    }
}
