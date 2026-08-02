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

    /// Timestamp of the latest drag event over the column — the stuck-
    /// overlay watchdog in `MacChatView` clears `isTargeted` when this
    /// goes stale (see `dragWatchdogGrace`).
    var activity: DragActivityBox = DragActivityBox()

    /// How long the overlay survives without a single drag event before
    /// the watchdog assumes the session died. A cancelled drag (Esc, or
    /// released elsewhere) can end WITHOUT `dropExited` (bugbot, PR #86),
    /// which would pin the overlay forever. The trade-off at 3s: a hand
    /// held perfectly still over the column that long loses the overlay —
    /// and the next 1px of movement fires `dropUpdated`, which re-raises
    /// it.
    static let dragWatchdogGrace: Duration = .seconds(3)

    /// Every flavor the chat column accepts. Must stay a superset of what
    /// `ComposerTextView.isAttachmentDragType` makes the input field
    /// decline — a flavor declined there and not accepted here would go
    /// dead (bugbot, PR #86). `.pdf` is here for exactly that reason: the
    /// text view declines the legacy `Apple PDF pasteboard type`, and PDF
    /// conforms to none of file-url/image/movie/audio (the other legacy
    /// flavors map into `.image`/`.movie`). Pinned by
    /// `test_columnAcceptsEverythingTheComposerDeclines`.
    static let acceptedTypes: [UTType] = [.fileURL, .image, .movie, .audio, .pdf]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        activity.dropCompleted = false
        activity.lastEvent = ContinuousClock.now
        isTargeted.wrappedValue = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        activity.lastEvent = ContinuousClock.now
        // Self-heal after a watchdog false-positive: any drag movement
        // proves the session is alive, so re-raise the overlay. The
        // `dropCompleted` guard is load-bearing: AppKit delivers a
        // trailing `dropUpdated` AFTER `performDrop`, and without the
        // guard that update resurrected the overlay for a few seconds
        // post-drop until the watchdog cleared it (Dan, 2026-08-02).
        if !activity.dropCompleted, !isTargeted.wrappedValue {
            isTargeted.wrappedValue = true
        }
        return nil
    }

    func dropExited(info: DropInfo) {
        isTargeted.wrappedValue = false
    }

    func performDrop(info: DropInfo) -> Bool {
        activity.dropCompleted = true
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

/// Reference box for the drag-session heartbeat. A class, not `@State`
/// value semantics: `dropUpdated` fires on every mouse move and a value
/// write per tick would re-evaluate the whole chat column body — same
/// pattern as `MacChatView.VisibleRowsBox`.
@MainActor
final class DragActivityBox {
    var lastEvent: ContinuousClock.Instant = .now
    /// Set by `performDrop`, reset by the next `dropEntered` — blocks the
    /// trailing `dropUpdated` AppKit sends after a landed drop from
    /// re-raising the overlay (see `dropUpdated`).
    var dropCompleted = false
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
