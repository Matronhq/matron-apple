import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// Builds the `ImageGallery` the fullscreen viewer steps through, for the
/// two places an image can be opened from. Mirrors
/// `Matron/Features/Chat/ImageGalleries.swift` token-for-token — the two
/// app targets have separate `AppDependencies` types, so this cannot live
/// in a shared package.
enum ImageGalleries {
    /// Gallery for a chat-timeline tap: every image in the conversation,
    /// oldest → newest (so → means "newer", matching the direction the
    /// timeline reads), starting at the tapped one.
    ///
    /// The list comes straight from the journal store via the same
    /// mapping the media browser uses, so it covers the whole
    /// conversation rather than the loaded scrollback window. If the
    /// tapped URL isn't in the store yet (an outgoing image still
    /// uploading) or the environment is missing, the viewer falls back to
    /// just the tapped image.
    @MainActor
    static func conversation(
        tapped url: URL,
        image: Image,
        chatViewModel: ChatViewModel,
        deps: AppDependencies?,
        session: UserSession?
    ) -> ImageGallery {
        let initial = ViewerImage(image: image, pixelSize: chatViewModel.imagePixelSize(for: url))
        guard let deps, let session else { return .single(image, pixelSize: initial.pixelSize) }
        let stored = (try? MediaBrowserViewModel.imageEntries(
            store: deps.journalStore(for: session),
            convoID: chatViewModel.roomID,
            serverURL: session.homeserverURL
        )) ?? []
        // Store order is newest first; the timeline reads the other way.
        let entries = stored.reversed().map {
            ImageGallery.Entry(id: String($0.id), url: $0.url, expired: $0.expired)
        }
        guard let start = entries.firstIndex(where: { $0.url == url }) else {
            return .single(image, pixelSize: initial.pixelSize)
        }
        let media = deps.mediaService(for: session)
        return ImageGallery(entries: entries, startIndex: start, initial: initial) { url in
            // The timeline may already hold this neighbour's bytes.
            if let cached = chatViewModel.resolvedImage(for: url) {
                return ViewerImage(image: cached, pixelSize: chatViewModel.imagePixelSize(for: url))
            }
            guard let sized = await media.sizedImage(for: url) else { return nil }
            return ViewerImage(image: sized.image, pixelSize: sized.pixelSize)
        }
    }

    /// Gallery for a media-grid tap: the grid's own list in its own order
    /// (newest first), starting at the tapped cell, so "next" is the next
    /// cell on screen.
    @MainActor
    static func mediaGrid(
        items: [MediaBrowserViewModel.MediaEntry],
        tappedID: Int64,
        initial: ViewerImage,
        media: any MediaService
    ) -> ImageGallery {
        let entries = items.map {
            ImageGallery.Entry(id: String($0.id), url: $0.url, expired: $0.expired)
        }
        let start = items.firstIndex { $0.id == tappedID } ?? 0
        return ImageGallery(entries: entries, startIndex: start, initial: initial) { url in
            guard let sized = await media.sizedImage(for: url) else { return nil }
            return ViewerImage(image: sized.image, pixelSize: sized.pixelSize)
        }
    }
}
