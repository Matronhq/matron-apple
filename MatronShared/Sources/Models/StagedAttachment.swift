import Foundation
import UniformTypeIdentifiers

/// A file the user has attached but not yet sent.
///
/// Attachments used to upload the instant they were picked, pasted or
/// dropped, which meant a photo reached claude as its own context-free turn
/// — the user's explanation arrived afterwards as a separate message, and
/// claude could (and did) start answering the bare image before it landed.
/// Staging holds attachments in the composer so they leave with the text
/// that explains them, as one turn.
///
/// The bytes are copied into `stagingDirectory` at attach time rather than
/// read at send time. Three of the six attach routes hand over a URL we
/// don't own — a security-scoped `fileImporter` result, a drag-and-drop
/// promise, a pasteboard temp file — and none of them guarantee the URL is
/// still readable once the user has typed a sentence and hit send. Copying
/// up front also means an unreadable file fails while the user is still
/// looking at the picker, not after they've composed a message.
public struct StagedAttachment: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Location of OUR copy, inside `stagingDirectory`. Deleted when the
    /// attachment is removed, sent, or discarded.
    public let url: URL
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int

    public init(id: UUID = UUID(), url: URL, filename: String, mimeType: String, sizeBytes: Int) {
        self.id = id
        self.url = url
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
    }

    /// Drives both the tray (thumbnail vs. file chip) and the send path
    /// (`sendImage` vs. `sendFile`), so the two can never disagree about
    /// what a given attachment is.
    public var isImage: Bool { mimeType.hasPrefix("image/") }

    /// Human-readable size for the tray's file chips.
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    /// Our own subdirectory of tmp, so `discardAll()` can empty it without
    /// touching temp files other parts of the app (or the OS) put there.
    public static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("staged-attachments", isDirectory: true)
    }

    /// Copies `source` into the staging directory and describes the result.
    ///
    /// The `UUID` directory (rather than a UUID filename prefix) keeps the
    /// user-visible filename intact — it's what the tray shows, what the
    /// journal event carries, and what claude sees in the upload annotation
    /// — while still letting two attachments with the same name coexist.
    public static func stage(copying source: URL) throws -> StagedAttachment {
        let data = try Data(contentsOf: source)
        let id = UUID()
        let directory = stagingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = source.lastPathComponent.isEmpty ? "attachment" : source.lastPathComponent
        let destination = directory.appendingPathComponent(name)
        try data.write(to: destination)
        return StagedAttachment(
            id: id,
            url: destination,
            filename: name,
            mimeType: mimeType(forExtension: source.pathExtension),
            sizeBytes: data.count
        )
    }

    /// Best-effort removal of this attachment's staged copy. Failures are
    /// ignored: a temp file we couldn't delete is litter the OS clears, not
    /// something worth surfacing to the user mid-compose.
    public func deleteStagedCopy() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Same rule `attachFiles(_:)` used before staging existed: the MIME
    /// type comes from the path extension, and an unmappable extension
    /// falls back to a generic binary rather than guessing.
    static func mimeType(forExtension ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}
