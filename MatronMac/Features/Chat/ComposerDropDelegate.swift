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
    /// Hover state for the chat column's "Drop here to add" overlay.
    /// `dropEntered`/`dropExited` bracket the hover; `performDrop` also
    /// clears it because AppKit doesn't send `dropExited` after a drop
    /// lands.
    var isTargeted: Binding<Bool> = .constant(false)

    /// Every flavor the chat column accepts. Must stay a superset of what
    /// `ComposerTextView.isAttachmentDragType` makes the input field
    /// decline — a flavor declined there and not accepted here would go
    /// dead (bugbot, PR #86). Pinned by
    /// `test_columnAcceptsEverythingTheComposerDeclines`.
    static let acceptedTypes: [UTType] = [.fileURL, .image, .movie, .audio]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        isTargeted.wrappedValue = true
    }

    func dropExited(info: DropInfo) {
        isTargeted.wrappedValue = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted.wrappedValue = false
        let providers = info.itemProviders(for: Self.acceptedTypes)
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            var firstError: Error?
            for provider in providers {
                let result = await Self.loadURL(from: provider)
                switch result {
                case .success(let url):
                    urls.append(url)
                case .failure(let err):
                    // Hold the first error so a multi-provider drop with
                    // some good and some bad providers still attaches the
                    // good ones (QA finding #9). Surface the failure
                    // through the composer's existing send-error sink so
                    // the user sees a banner instead of a silent drop.
                    if firstError == nil { firstError = err }
                }
            }
            if !urls.isEmpty {
                await composer.attachFiles(urls)
            }
            if let err = firstError {
                composer.reportAttachmentError(err.localizedDescription)
            }
        }
        return true
    }

    /// Resolves an `NSItemProvider` to a local file URL the composer can
    /// attach. Internal so the test target can exercise it directly.
    /// Returns a `Result` so caller can distinguish "provider didn't
    /// carry a usable representation" from a real load error — the SDK
    /// callback's `Error?` parameter previously got dropped, hiding
    /// decode / permission failures.
    ///
    /// Finder-style drops carry a file URL and pass straight through.
    /// Providers without one — an image dragged off a web page, media
    /// carried as raw data — fall back to `PastedAttachment.stage`, the
    /// same probe-verified pipeline the paste path uses to write the
    /// provider's bytes to a temp file (bugbot, PR #86: the input field
    /// declines these flavors now, so the column must be able to land
    /// them).
    static func loadURL(from provider: NSItemProvider) async -> Result<URL, Error> {
        if provider.canLoadObject(ofClass: URL.self) {
            return await withCheckedContinuation { (cont: CheckedContinuation<Result<URL, Error>, Never>) in
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let url {
                        cont.resume(returning: .success(url))
                    } else if let error {
                        cont.resume(returning: .failure(error))
                    } else {
                        // Neither URL nor error — provider declined to
                        // deliver. Synthesise a generic error so the caller
                        // can route something into the banner.
                        cont.resume(returning: .failure(ComposerDropError.providerDeliveredNothing))
                    }
                }
            }
        }
        do {
            return .success(try await PastedAttachment.stage(provider))
        } catch {
            return .failure(error)
        }
    }
}

/// Drop-delegate-specific errors. Promoted to a typed enum (vs an
/// inline NSError) so future drop sources (e.g. NSPasteboard) can share
/// the surface and tests can match against specific cases.
enum ComposerDropError: LocalizedError {
    case providerDeliveredNothing

    var errorDescription: String? {
        switch self {
        case .providerDeliveredNothing:
            return "Couldn't read the dropped item."
        }
    }
}
