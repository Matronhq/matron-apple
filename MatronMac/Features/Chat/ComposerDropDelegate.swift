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

    /// Extracts a file URL from an `NSItemProvider`. Internal so the test
    /// target can exercise it directly. Returns a `Result` so caller can
    /// distinguish "provider didn't carry a URL representation" (success
    /// with nil pre-QA-#9) from a real load error — the SDK callback's
    /// `Error?` parameter previously got dropped, hiding decode /
    /// permission failures.
    static func loadURL(from provider: NSItemProvider) async -> Result<URL, Error> {
        await withCheckedContinuation { (cont: CheckedContinuation<Result<URL, Error>, Never>) in
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
