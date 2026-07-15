import Foundation
import UniformTypeIdentifiers

/// Turns an `NSItemProvider` handed over by a paste into a temporary file URL
/// that `ComposerViewModel.attachFiles(_:)` can read.
///
/// Shared because both app shells receive the same `NSItemProvider` currency
/// from very different plumbing — iOS via a `UITextPasteDelegate` on the text
/// field's backing view, Mac via `onPasteCommand` — and the rule for what
/// counts as an attachment must not drift between them. `ComposerDropDelegate`
/// stays on its own `loadURL` path: a drop only ever carries file URLs, and it
/// has no text branch to get wrong.
public enum PastedAttachment {
    /// What a pasted item should become.
    public enum Kind: Equatable {
        /// A file to attach, carried inline under this type identifier.
        case attachment(typeIdentifier: String)
        /// A file to attach, carried as a `public.file-url` reference.
        case fileReference
        /// Not ours — the text field should paste it itself.
        case text
    }

    /// Decides whether a pasted item is an attachment or text.
    ///
    /// The order matters, and each rule is here because a real pasteboard
    /// shape demanded it (identifiers verified against the platform, not
    /// assumed):
    ///
    /// 1. A file URL wins outright. A Files-app copy registers
    ///    `["public.plain-text", "public.file-url", "public.url"]` for a text
    ///    file — pasting its *contents* when the user copied the *file* would
    ///    be the wrong call.
    /// 2. Then images, so a photo copied out of Photos or a web page attaches
    ///    even when an HTML flavour rides along with it.
    /// 3. Then any text flavour wins. `public.html` and `public.rtf` both
    ///    conform to `public.text`, so styled text pastes as text; and a
    ///    webarchive (which does NOT conform to `public.text`) is always
    ///    accompanied by a plain-text flavour, so this rule is what stops a
    ///    copied paragraph arriving as a mystery attachment.
    /// 4. Only then does other data — a PDF, a zip — count as a file.
    public static func classify(_ provider: NSItemProvider) -> Kind {
        let identifiers = provider.registeredTypeIdentifiers
        let types = identifiers.compactMap { UTType($0) }

        if types.contains(where: { $0.conforms(to: .fileURL) }) {
            return .fileReference
        }
        if let image = identifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            return .attachment(typeIdentifier: image)
        }
        if types.contains(where: { $0.conforms(to: .text) }) {
            return .text
        }
        let file = identifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .url)
        }
        return file.map { .attachment(typeIdentifier: $0) } ?? .text
    }

    /// Materialises a pasted attachment into a temporary file.
    ///
    /// Throws `PastedAttachmentError.notAnAttachment` for text items — callers
    /// are expected to have consulted `classify(_:)` first and let the field
    /// handle those; this is a backstop, not a routing decision.
    public static func stage(_ provider: NSItemProvider) async throws -> URL {
        switch classify(provider) {
        case .text:
            throw PastedAttachmentError.notAnAttachment
        case .fileReference:
            return try await stageFileReference(provider)
        case .attachment(let typeIdentifier):
            return try await stageRepresentation(provider, typeIdentifier: typeIdentifier)
        }
    }

    /// Builds a unique temporary URL for a pasted item. Mirrors — and is now
    /// the single implementation behind — `ComposerView.stagedTempURL(for:)`:
    /// the `UUID` prefix is what keeps two pastes of the same filename from
    /// clobbering each other before `attachFiles(_:)` has read the first.
    public static func stagingURL(forName name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    /// Resolves a `public.file-url` item and copies its bytes somewhere we own.
    private static func stageFileReference(_ provider: NSItemProvider) async throws -> URL {
        let source: URL = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? PastedAttachmentError.unreadableItem)
                }
            }
        }
        // A pasted file URL can point into another app's container, which
        // needs the security scope opened around the read — the same reason
        // `ComposerView.stageAndAttach` brackets its `fileImporter` URLs.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        let destination = stagingURL(forName: source.lastPathComponent)
        try data.write(to: destination)
        return destination
    }

    /// Asks the provider to write its bytes to disk and copies the result
    /// somewhere with a lifetime we control.
    private static func stageRepresentation(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> URL {
        // Read off the provider before the closure: it isn't `Sendable`, and
        // the suggested name is the only thing the callback needs from it.
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? PastedAttachmentError.unreadableItem)
                    return
                }
                // The provider deletes its temporary file as soon as this
                // callback returns, so the copy has to happen here — not
                // after an await.
                do {
                    let name = filename(
                        suggestedName: suggestedName,
                        typeIdentifier: typeIdentifier,
                        loaded: url
                    )
                    let destination = stagingURL(forName: name)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Names the staged file. The extension is the load-bearing part —
    /// `attachFiles(_:)` derives the MIME type from it, which is what decides
    /// `sendImage` vs `sendFile` — so a provider that hands back an
    /// extensionless file falls back to the type's own preferred extension.
    private static func filename(
        suggestedName: String?,
        typeIdentifier: String,
        loaded: URL
    ) -> String {
        if !loaded.pathExtension.isEmpty { return loaded.lastPathComponent }
        let base = suggestedName ?? "pasted-file"
        guard let ext = UTType(typeIdentifier)?.preferredFilenameExtension else { return base }
        return "\(base).\(ext)"
    }
}

/// Paste-staging failures, surfaced through the composer's existing
/// `sendError` banner rather than dropped.
public enum PastedAttachmentError: LocalizedError, Equatable {
    /// The item is text — the text field pastes those itself.
    case notAnAttachment
    /// The provider delivered neither a file nor an error.
    case unreadableItem

    public var errorDescription: String? {
        switch self {
        case .notAnAttachment:
            return "That doesn't look like a file we can attach."
        case .unreadableItem:
            return "Couldn't read the pasted item."
        }
    }
}
