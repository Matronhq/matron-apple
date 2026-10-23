#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// The Mac's standard Save panel.
///
/// SwiftUI's `fileExporter` shows an "Export As" panel, and it hides the
/// name's extension when Finder's "Show all filename extensions" is off,
/// so a Download looked like an export of a file with no extension. This
/// is the panel every Mac app shows for Save: "Save As", with the
/// extension visible and kept in step with the type. It drops down as a
/// sheet on the window the user is working in, like any document Save.
@MainActor
public enum SavePanel {
    public enum Outcome: Equatable {
        case saved(URL)
        case cancelled
        /// Writing to the chosen file failed.
        case failed
        /// The bytes never arrived (a fetch that failed).
        case unavailable
    }

    /// Asks where to save `data`, suggesting `filename`, and writes it
    /// there.
    public static func save(_ data: Data, filename: String, contentType: UTType,
                            over window: NSWindow? = nil) async -> Outcome {
        await save(filename: filename, contentType: contentType, over: window) { data }
    }

    /// Shows the panel at once and writes what `data` produces to the
    /// chosen file. `data` starts as the panel opens, so a slow fetch runs
    /// while the user picks a place instead of holding the panel back.
    ///
    /// - Parameters:
    ///   - window: the window to drop the sheet from; the key window when
    ///     `nil`. With neither, the panel opens on its own.
    ///   - refine: a better name and type worked out from the bytes (an
    ///     image's real format). Applied when the bytes arrive while the
    ///     name field still holds the suggestion, so a name the user typed
    ///     is never replaced.
    public static func save(filename: String, contentType: UTType, over window: NSWindow? = nil,
                            refine: (@MainActor (Data) -> (filename: String, contentType: UTType))? = nil,
                            data: @escaping @MainActor () async -> Data?) async -> Outcome {
        let panel = makePanel(filename: filename, contentType: contentType)
        let bytes = Task { @MainActor () -> Data? in
            guard let data = await data(), !data.isEmpty else { return nil }
            if let refine, panel.nameFieldStringValue == filename {
                let better = refine(data)
                configure(panel, filename: better.filename, contentType: better.contentType)
            }
            return data
        }
        let response = await present(panel, over: window ?? NSApp.keyWindow)
        guard response == .OK, let url = panel.url else {
            bytes.cancel()
            return .cancelled
        }
        guard let data = await bytes.value else { return .unavailable }
        // Written in place rather than `.atomic`, so nothing needs access
        // beyond the file the user chose.
        do {
            try data.write(to: url)
            return .saved(url)
        } catch {
            return .failed
        }
    }

    private static func present(_ panel: NSSavePanel, over window: NSWindow?) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            if let window, window.isVisible, window.attachedSheet == nil {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
    }

    static func makePanel(filename: String, contentType: UTType) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = true
        panel.canCreateDirectories = true
        configure(panel, filename: filename, contentType: contentType)
        return panel
    }

    static func configure(_ panel: NSSavePanel, filename: String, contentType: UTType) {
        panel.nameFieldStringValue = filename
        // Only a concrete type has an extension to keep; an abstract one
        // (`.image`, `.data`) would make the panel refuse every name.
        if contentType.preferredFilenameExtension != nil {
            panel.allowedContentTypes = [contentType]
            panel.allowsOtherFileTypes = true
        } else {
            panel.allowedContentTypes = []
        }
    }
}
#endif
