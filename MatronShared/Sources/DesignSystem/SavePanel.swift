#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// The Mac's standard Save panel for bytes the app already holds.
///
/// SwiftUI's `fileExporter` shows an "Export As" panel, and it hides the
/// name's extension when Finder's "Show all filename extensions" is off,
/// so a Download looked like an export of a file with no extension. This
/// is the panel every Mac app shows for Save: "Save As", with the
/// extension visible and kept in step with the type.
@MainActor
public enum SavePanel {
    public enum Outcome: Equatable {
        case saved(URL)
        case cancelled
        case failed
    }

    /// Asks where to save `data`, suggesting `filename`, and writes it
    /// there.
    public static func save(_ data: Data, filename: String, contentType: UTType) async -> Outcome {
        let panel = makePanel(filename: filename, contentType: contentType)
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return .cancelled }
        // Written in place rather than `.atomic`, so nothing needs access
        // beyond the file the user chose.
        do {
            try data.write(to: url)
            return .saved(url)
        } catch {
            return .failed
        }
    }

    static func makePanel(filename: String, contentType: UTType) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = true
        panel.canCreateDirectories = true
        // Only a concrete type has an extension to keep; an abstract one
        // (`.image`, `.data`) would make the panel refuse every name.
        if contentType.preferredFilenameExtension != nil {
            panel.allowedContentTypes = [contentType]
            panel.allowsOtherFileTypes = true
        }
        return panel
    }
}
#endif
