import Foundation
import OSLog
import UniformTypeIdentifiers

/// Turns an `NSItemProvider` handed over by a paste into a temporary file URL
/// that `ComposerViewModel.attachFiles(_:)` can read.
///
/// Shared because both app shells receive the same `NSItemProvider` currency
/// from very different plumbing — iOS via a `UITextPasteDelegate` on the text
/// field's backing view, Mac via `onPasteCommand` — and the rule for what
/// counts as an attachment must not drift between them. Mac drag-and-drop
/// (`ComposerDropDelegate`) resolves file URLs itself but falls back to
/// `stage(_:)` for providers that carry only data (an image dragged off a
/// web page), so drops and pastes of the same payload land identically.
public enum PastedAttachment {
    private static let logger = Logger(subsystem: "chat.matron", category: "paste")

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

    /// The largest file a paste will stage, matching the server's upload
    /// limit. Checked before the bytes are read, so an oversized file is
    /// refused instead of being pulled into memory.
    public static let maxBytes = 50 * 1024 * 1024

    /// Where pasted and picked files wait before the tray takes them over.
    static var stagingRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("incoming-attachments", isDirectory: true)
    }

    /// Builds a unique temporary URL for a pasted or picked item, and is the
    /// single implementation behind `ComposerView.stagedTempURL(for:)`.
    ///
    /// The uniqueness lives in a per-item directory, not in the file name:
    /// the name is what the tray shows and what the agent is told the file
    /// is called, so `report.zip` must stay `report.zip`. A UUID prefix on
    /// the name itself used to travel all the way to the message.
    public static func stagingURL(forName name: String) -> URL {
        let directory = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name.isEmpty ? "attachment" : name)
    }

    /// Removes a file made at a `stagingURL(forName:)` location together
    /// with its per-item directory. Safe for any other URL: only the file
    /// itself is removed then. Also fine when the file has already been
    /// moved away.
    public static func removeStagingFile(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        if directory.deletingLastPathComponent().standardizedFileURL == stagingRoot.standardizedFileURL {
            try? FileManager.default.removeItem(at: directory)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
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
        let name = source.lastPathComponent
        do {
            return try copyFile(at: source, named: name)
        } catch let error as PastedAttachmentError {
            throw error
        } catch {
            // The URL names a file we may not be allowed to open: a file
            // copied in another app can sit in that app's container, and a
            // URL that came through the pasteboard carries no permission to
            // read it. The item's own bytes do come through, so take those.
            guard let typeIdentifier = inlineFileType(of: provider) else { throw error }
            return try await stageRepresentation(provider, typeIdentifier: typeIdentifier, name: name)
        }
    }

    /// Copies the file at `source` to a staging URL. The security scope is
    /// opened around the read, the same reason `ComposerView.stageAndAttach`
    /// brackets its `fileImporter` URLs.
    private static func copyFile(at source: URL, named name: String) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        if let size = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? Int,
           size > maxBytes {
            throw PastedAttachmentError.tooLarge(name: name)
        }
        let destination = stagingURL(forName: name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            removeStagingFile(destination)
            throw error
        }
        return destination
    }

    /// The flavour that holds a file item's own bytes, when it carries one
    /// beside its URL: the first data type that is not itself a URL. Types
    /// the file was merely rendered as (text, for a text file) come last.
    static func inlineFileType(of provider: NSItemProvider) -> String? {
        let candidates = provider.registeredTypeIdentifiers.filter { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .url)
        }
        return candidates.first { UTType($0)?.conforms(to: .text) == false } ?? candidates.first
    }

    /// Asks the provider for the item's bytes and writes them somewhere with a
    /// lifetime we control.
    ///
    /// Deliberately `loadDataRepresentation`, not `loadFileRepresentation`: a
    /// pasteboard-backed provider has no file to hand over, and asking for one
    /// fails with "Cannot load representation of type public.png" (measured on
    /// a real paste, 2026-07-16 — it left the user with a Paste button that
    /// silently did nothing). Data works for both pasteboard and file-backed
    /// providers, at the cost of naming the file ourselves.
    private static func stageRepresentation(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        name fixedName: String? = nil
    ) async throws -> URL {
        // Worked out before the closure: the provider isn't `Sendable`, and
        // the name is the only thing the callback needs from it.
        let name: String
        if let fixedName {
            name = fixedName
        } else {
            name = filename(
                suggestedName: await carriedName(of: provider, typeIdentifier: typeIdentifier),
                typeIdentifier: typeIdentifier
            )
        }
        // Flavour identifiers only, never the name or the contents: this is
        // what shows which apps hand over a name and which don't.
        logger.info("""
            staging \(typeIdentifier, privacy: .public) from \
            \(provider.registeredTypeIdentifiers, privacy: .public), \
            suggested name: \(provider.suggestedName != nil, privacy: .public)
            """)
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                guard let data else {
                    continuation.resume(throwing: error ?? PastedAttachmentError.unreadableItem)
                    return
                }
                guard data.count <= maxBytes else {
                    continuation.resume(throwing: PastedAttachmentError.tooLarge(name: name))
                    return
                }
                let destination = stagingURL(forName: name)
                do {
                    try data.write(to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    removeStagingFile(destination)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The name an inline item came with, when it carries one: the name the
    /// platform suggests, else the name in the address a copied image came
    /// from. Safari puts that address in a URL flavour, Chromium in an
    /// `<img src>` in its HTML flavour.
    private static func carriedName(of provider: NSItemProvider, typeIdentifier: String) async -> String? {
        if let suggested = provider.suggestedName, !suggested.isEmpty { return suggested }
        if provider.canLoadObject(ofClass: URL.self),
           let url = await loadURL(from: provider),
           let name = name(fromAddress: url, typeIdentifier: typeIdentifier) {
            return name
        }
        guard UTType(typeIdentifier)?.conforms(to: .image) == true,
              provider.hasItemConformingToTypeIdentifier(UTType.html.identifier),
              let data = await loadData(from: provider, typeIdentifier: UTType.html.identifier),
              let source = imageSource(inHTML: String(decoding: data, as: UTF8.self)),
              let url = URL(string: source) else { return nil }
        return name(fromAddress: url, typeIdentifier: typeIdentifier)
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// The `src` of the only `<img>` in `html`. With several, nothing says
    /// which of them the pasted bytes are.
    static func imageSource(inHTML html: String) -> String? {
        let matches = html.matches(of: #/(?i)<img\b[^>]*?\ssrc\s*=\s*(?:"([^"]+)"|'([^']+)')/#)
        guard matches.count == 1, let match = matches.first else { return nil }
        return (match.1 ?? match.2).map(String.init)
    }

    /// The file name in an address, if the address names a file of this kind.
    /// A linked image carries the link, which names a page (`article.html`,
    /// `/gallery`) rather than the image, so anything else is refused.
    ///
    /// Browsers re-encode what they copy, so a `.jpg` address can arrive as
    /// PNG bytes. That gives back the bare stem for `filename` to extend,
    /// not `photo.jpg.png`.
    static func name(fromAddress url: URL, typeIdentifier: String) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme),
              let type = UTType(typeIdentifier),
              !url.pathExtension.isEmpty,
              let named = UTType(filenameExtension: url.pathExtension) else { return nil }
        if named.conforms(to: type) { return url.lastPathComponent }
        guard named.conforms(to: .image), type.conforms(to: .image) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Names a staged inline item. The extension is the load-bearing part —
    /// `attachFiles(_:)` derives the MIME type from it, and that's what decides
    /// `sendImage` vs `sendFile` — so it always comes from the type identifier
    /// itself.
    ///
    /// A suggested name that already ends in an extension of that type keeps
    /// it as written (`photo.jpg` stays `.jpg`, not `.jpeg`), and one with
    /// dots in it (`build-1.2`) is not cut short.
    ///
    /// A pasted screenshot has no name to keep, so it is named for what it is
    /// and when it was pasted. That name reaches the agent, and one fixed
    /// name turned every paste into `pasted-file-N.png` there.
    static func filename(suggestedName: String?, typeIdentifier: String, now: Date = Date()) -> String {
        let type = UTType(typeIdentifier)
        guard let name = suggestedName.flatMap(safeFilename) else {
            let kind = type?.conforms(to: .image) == true ? "pasted-image" : "pasted-file"
            let stem = "\(kind)-\(fallbackTimestamp.string(from: now))"
            return type?.preferredFilenameExtension.map { "\(stem).\($0)" } ?? stem
        }
        let existing = (name as NSString).pathExtension
        if !existing.isEmpty, let type,
           UTType(filenameExtension: existing)?.conforms(to: type) == true {
            return name
        }
        guard let ext = type?.preferredFilenameExtension else { return name }
        return existing.lowercased() == ext ? name : "\(name).\(ext)"
    }

    private static let fallbackTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    /// The longest name kept, in bytes. File systems stop at 255, and the
    /// bridge may yet add `-N` to it.
    private static let maxNameBytes = 200

    /// Makes a carried name usable as one file name, or nil if nothing of it
    /// is. A name from a pasteboard or an address is outside data: a slash
    /// would make the staging write fail, and a line break would split the
    /// line the agent is told about the file on.
    static func safeFilename(_ name: String) -> String? {
        let lastComponent = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = lastComponent
            .replacing(#/[\p{Cc}\p{Zl}\p{Zp}\s]+/#, with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, !cleaned.allSatisfy({ $0 == "." }) else { return nil }
        guard cleaned.utf8.count > maxNameBytes else { return cleaned }
        let ext = (cleaned as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : ".\(ext)"
        var stem = suffix.isEmpty ? cleaned : (cleaned as NSString).deletingPathExtension
        while stem.utf8.count + suffix.utf8.count > maxNameBytes { stem.removeLast() }
        return stem + suffix
    }
}

/// Paste-staging failures, surfaced through the composer's existing
/// `sendError` banner rather than dropped.
public enum PastedAttachmentError: LocalizedError, Equatable {
    /// The item is text — the text field pastes those itself.
    case notAnAttachment
    /// The provider delivered neither a file nor an error.
    case unreadableItem
    /// The file is over `PastedAttachment.maxBytes`.
    case tooLarge(name: String)

    public var errorDescription: String? {
        switch self {
        case .notAnAttachment:
            return "That doesn't look like a file we can attach."
        case .unreadableItem:
            return "Couldn't read the pasted item."
        case .tooLarge(let name):
            let limit = ByteCountFormatter.string(
                fromByteCount: Int64(PastedAttachment.maxBytes), countStyle: .file)
            return "\(name) is too large to attach. The limit is \(limit)."
        }
    }
}
