import Foundation
import UniformTypeIdentifiers

/// A file handed to the share sheet, copied somewhere this process owns.
public struct SharedFile: Identifiable, Equatable, Sendable {
    public let id: UUID
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

    /// Decides the wire kind (`image` or `file`), the same rule the
    /// composer's tray uses.
    public var isImage: Bool { mimeType.hasPrefix("image/") }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

/// What one shared item turned out to be.
public enum SharedContent: Equatable, Sendable {
    case file(SharedFile)
    /// Text or a web link: it joins the message rather than being attached.
    case text(String)
}

public enum ShareLoadError: LocalizedError, Equatable {
    case tooLarge(name: String)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let name):
            let limit = ByteCountFormatter.string(
                fromByteCount: Int64(ShareItemLoader.maxBytes), countStyle: .file)
            return "\(name) is too large to send. The limit is \(limit)."
        case .unreadable:
            return "Couldn't read one of the shared items."
        }
    }
}

/// Turns the `NSItemProvider`s a share sheet hands over into files on disk
/// and text.
///
/// Files are copied, never loaded: a share extension is ended by the system
/// at a memory footprint far below the size of a large attachment, so the
/// bytes go from the provider's file to ours without passing through memory.
public enum ShareItemLoader {
    /// The server's upload limit.
    public static let maxBytes = 50 * 1024 * 1024

    enum Kind: Equatable {
        /// A file, carried under this type identifier.
        case file(typeIdentifier: String)
        /// A file named by a `public.file-url`. `inlineType` is the type its
        /// bytes also travel under, when the item carries them.
        case fileReference(inlineType: String?)
        case text
        case webLink
        case unsupported
    }

    /// The order follows what the user meant by sharing the item:
    ///
    /// 1. A file URL means a file was shared, even a text file whose
    ///    contents ride along as plain text.
    /// 2. An image is a file even with a web address beside it (a picture
    ///    shared from a web page).
    /// 3. Text is text, and a web address is a link: both belong in the
    ///    message.
    /// 4. Any other data is a file.
    static func classify(_ provider: NSItemProvider) -> Kind {
        let identifiers = provider.registeredTypeIdentifiers
        func conforming(_ parent: UTType) -> String? {
            identifiers.first { UTType($0)?.conforms(to: parent) == true }
        }
        if conforming(.fileURL) != nil {
            return .fileReference(inlineType: fileType(in: identifiers))
        }
        if let image = conforming(.image) { return .file(typeIdentifier: image) }
        if conforming(.text) != nil { return .text }
        if conforming(.url) != nil { return .webLink }
        return fileType(in: identifiers).map { .file(typeIdentifier: $0) } ?? .unsupported
    }

    /// The type that holds a file's own bytes: the first data type that is
    /// not a URL, preferring one that is not a text rendering.
    private static func fileType(in identifiers: [String]) -> String? {
        let candidates = identifiers.filter { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .url)
        }
        return candidates.first { UTType($0)?.conforms(to: .text) == false } ?? candidates.first
    }

    /// Loads one shared item. Files land in a directory of their own under
    /// `directory`, under the name they were shared with.
    public static func load(_ provider: NSItemProvider, into directory: URL) async throws -> SharedContent? {
        switch classify(provider) {
        case .file(let typeIdentifier):
            return .file(try await loadFile(provider, typeIdentifier: typeIdentifier,
                                            named: nil, into: directory))
        case .fileReference(let inlineType):
            // The URL is the file itself, under its real name, so it is
            // tried first. One this process may not open still names the
            // file, and the item's own bytes are copied under that name.
            let source = try await loadURL(provider)
            let name = source.lastPathComponent
            do {
                return .file(try copy(source, named: name, into: directory))
            } catch let error as ShareLoadError {
                throw error
            } catch {
                guard let inlineType else { throw error }
                return .file(try await loadFile(provider, typeIdentifier: inlineType,
                                                named: name, into: directory))
            }
        case .text:
            let text = try await loadString(provider)
            return text.isEmpty ? nil : .text(text)
        case .webLink:
            return .text(try await loadURL(provider).absoluteString)
        case .unsupported:
            return nil
        }
    }

    private static func loadFile(
        _ provider: NSItemProvider, typeIdentifier: String, named fixedName: String?, into directory: URL
    ) async throws -> SharedFile {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            // The URL is only valid inside this callback, so the copy
            // happens here.
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ShareLoadError.unreadable)
                    return
                }
                let name = fixedName
                    ?? filename(for: url, suggestedName: suggestedName, typeIdentifier: typeIdentifier)
                continuation.resume(with: Result { try copy(url, named: name, into: directory) })
            }
        }
    }

    /// The name to send a file under when the item carries no file URL: the
    /// name of the temporary file the provider handed over, which it names
    /// from the item's suggested name. A name that arrives without an
    /// extension is given the type's.
    static func filename(for url: URL, suggestedName: String?, typeIdentifier: String) -> String {
        var name = url.lastPathComponent
        if name.isEmpty { name = suggestedName ?? "" }
        if name.isEmpty { name = "attachment" }
        if (name as NSString).pathExtension.isEmpty,
           let ext = UTType(typeIdentifier)?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        return name
    }

    static func copy(_ source: URL, named name: String, into directory: URL) throws -> SharedFile {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        // Refused before the copy when the size is known up front, which
        // saves copying a file only to throw it away.
        if let size = fileSize(of: source), size > maxBytes {
            throw ShareLoadError.tooLarge(name: name)
        }
        let id = UUID()
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name.isEmpty ? "attachment" : name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        // The copy is what gets sent, so its size is the one that counts.
        // A source that could not say how big it was is measured here.
        guard let size = fileSize(of: destination) else {
            try? FileManager.default.removeItem(at: folder)
            throw ShareLoadError.unreadable
        }
        guard size <= maxBytes else {
            try? FileManager.default.removeItem(at: folder)
            throw ShareLoadError.tooLarge(name: name)
        }
        let ext = destination.pathExtension
        return SharedFile(
            id: id, url: destination, filename: destination.lastPathComponent,
            mimeType: UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream",
            sizeBytes: size)
    }

    private static func fileSize(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    private static func loadURL(_ provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? ShareLoadError.unreadable)
                }
            }
        }
    }

    private static func loadString(_ provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, error in
                if let text {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: error ?? ShareLoadError.unreadable)
                }
            }
        }
    }
}
