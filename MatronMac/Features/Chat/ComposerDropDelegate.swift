import SwiftUI
import UniformTypeIdentifiers
import MatronChat
import MatronViewModels

/// Drag-and-drop handler for the Mac composer. Plumbs dropped file URLs
/// (and image item providers) into the shared `ComposerViewModel.attachFiles(_:)`
/// pipeline — same as the iOS PhotosPicker / fileImporter sites.
///
/// We deliberately split URL extraction into a `static` helper so it's
/// testable without needing a real `DropInfo` (SwiftUI's `DropInfo` is a
/// struct with no public init, so unit tests can't construct one). The
/// `performDrop(info:)` body is then a thin wrapper around `loadURL` ×
/// `composer.attachFiles`.
@MainActor
struct ComposerDropDelegate: DropDelegate {
    let composer: ComposerViewModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.image, .fileURL])
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL, .image])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.loadURL(from: provider) {
                    urls.append(url)
                }
            }
            await composer.attachFiles(urls)
        }
        return true
    }

    /// Extracts a file URL from an `NSItemProvider`. Internal so the test
    /// target can exercise it directly. Falls back to `nil` when the
    /// provider doesn't carry a URL representation — callers (the
    /// `performDrop` loop) skip nil results so a partial-failure drop
    /// still attaches whatever URLs did resolve.
    static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                cont.resume(returning: url)
            }
        }
    }
}
