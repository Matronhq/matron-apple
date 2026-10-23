import AppKit
import MatronDesignSystem
import UniformTypeIdentifiers

/// Download and drag-out for a file attachment on the Mac. Opening a file
/// hands a temp copy to another app, which is no way to keep it; these
/// put a copy where the user chooses.
@MainActor
enum MacAttachmentSaver {
    /// The standard Save panel for the downloaded file at `url`,
    /// suggesting `filename`; the saved copy is then shown in Finder.
    /// Returns a message to show when it failed, `nil` otherwise.
    static func save(_ url: URL, filename: String, contentType: UTType) async -> String? {
        // Read off the main actor: a large file would hold up the panel.
        guard let data = await Task.detached(operation: { try? Data(contentsOf: url) }).value else {
            return "Couldn't read \(filename)."
        }
        switch await SavePanel.save(data, filename: filename, contentType: contentType) {
        case .saved(let saved):
            NSWorkspace.shared.activateFileViewerSelecting([saved])
            return nil
        case .failed, .unavailable:
            return "Couldn't save \(filename)."
        case .cancelled:
            return nil
        }
    }

    /// A drag item Finder (or any app taking files) can drop as
    /// `filename`. `load` fetches the file only when a drop asks for it.
    static func dragProvider(filename: String, contentType: UTType,
                             load: @escaping @MainActor () async -> URL?) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = filename
        provider.registerFileRepresentation(forTypeIdentifier: contentType.identifier, fileOptions: [],
                                            visibility: .all) { completion in
            Task { @MainActor in
                if let url = await load() {
                    completion(url, false, nil)
                } else {
                    completion(nil, false, CocoaError(.fileReadUnknown))
                }
            }
            return nil
        }
        return provider
    }

    /// The type to save or drag a file as: its MIME type, else its
    /// extension, else plain data.
    static func contentType(mime: String?, filename: String) -> UTType {
        mime.flatMap { UTType(mimeType: $0) }
            ?? UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
    }
}
