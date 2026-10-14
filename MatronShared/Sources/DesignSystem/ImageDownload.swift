import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The fullscreen viewer's Download: the original file's bytes, the type
/// they actually are, and the name to suggest for them.
public struct ImageDownload: Identifiable {
    public let id = UUID()
    public let data: Data
    public let contentType: UTType
    public let filename: String

    public init(data: Data, name: String?) {
        self.data = data
        let sniffed = Self.sniffedType(of: data)
        self.contentType = sniffed ?? name.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) } ?? .image
        self.filename = Self.suggestedFilename(name: name, type: sniffed)
    }

    /// The bytes' own image type, read from their header — chat images
    /// carry no file name, and a tracker attachment's name may lack an
    /// extension.
    static func sniffedType(of data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String? else { return nil }
        return UTType(identifier)
    }

    /// `name` when it has an extension; otherwise `name` (or "Image") with
    /// the sniffed type's preferred extension added. Path separators are
    /// dropped so a hostile name can't point the save anywhere else.
    static func suggestedFilename(name: String?, type: UTType?) -> String {
        let cleaned = (name ?? "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Image" : cleaned
        if !(base as NSString).pathExtension.isEmpty { return base }
        guard let ext = type?.preferredFilenameExtension else { return base }
        return "\(base).\(ext)"
    }

    /// Writes the bytes to a fresh temp directory under `filename`, for
    /// the iOS share sheet (which shares files, not data).
    func writeTemporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-download-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// `fileExporter` payload for a downloaded image: the original bytes,
/// written as they are.
struct ImageFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.image] }
    /// The concrete types `ImageDownload` sniffs, so the Save panel keeps
    /// the file's real type and extension instead of falling back to the
    /// abstract `.image`.
    static var writableContentTypes: [UTType] {
        [.png, .jpeg, .heic, .heif, .gif, .tiff, .bmp, .webP, .image]
    }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Copy Image: the original bytes under their own type, plus a decoded
/// bitmap for apps that only read the generic image types.
@MainActor
enum ImagePasteboard {
    static func copy(_ file: ImageDownload) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(file.data, forType: NSPasteboard.PasteboardType(file.contentType.identifier))
        if file.contentType != .tiff, let tiff = NSImage(data: file.data)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.writeObjects([item])
        #else
        var item: [String: Any] = [file.contentType.identifier: file.data]
        if let image = UIImage(data: file.data), let png = image.pngData(),
           file.contentType != .png {
            item[UTType.png.identifier] = png
        }
        UIPasteboard.general.setItems([item])
        #endif
    }
}
