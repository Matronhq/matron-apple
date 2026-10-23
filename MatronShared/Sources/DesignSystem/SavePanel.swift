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
    /// while the user picks a place instead of holding the panel back;
    /// `nil` from it means the bytes never came. The name and type are
    /// fixed when the panel opens, so the caller must already know them.
    ///
    /// - Parameter window: the window to drop the sheet from; the key
    ///   window when `nil`. With neither, the panel opens on its own.
    public static func save(filename: String, contentType: UTType, over window: NSWindow? = nil,
                            data: @escaping @MainActor () async -> Data?) async -> Outcome {
        let panel = makePanel(filename: filename, contentType: contentType)
        let bytes = Task { @MainActor in await data() }
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
            // Ordered out before resuming: the sheet can still be on screen
            // in its handler, and a failure alert must not open behind it.
            if let window, window.isVisible, window.attachedSheet == nil {
                panel.beginSheetModal(for: window) { response in
                    panel.orderOut(nil)
                    continuation.resume(returning: response)
                }
            } else {
                panel.begin { response in
                    panel.orderOut(nil)
                    continuation.resume(returning: response)
                }
            }
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
