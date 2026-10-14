import SwiftUI

/// One resolved image for the fullscreen viewer: the SwiftUI `Image` plus
/// its native bitmap size when known (Mac uses the aspect ratio to lay
/// the image out at an exact fitted rect for zoom/pan; see
/// `AttachmentFullscreenViewer`).
public struct ViewerImage {
    public let image: Image
    public let pixelSize: CGSize?

    public init(image: Image, pixelSize: CGSize? = nil) {
        self.image = image
        self.pixelSize = pixelSize
    }
}

/// What the fullscreen viewer steps through with ←/→ (Mac) or a
/// horizontal swipe (iOS): an ordered list of image entries and where
/// to start. Entries are resolved lazily through `load`, a closure so
/// `MatronDesignSystem` never has to import the media service — the
/// call site decides how bytes become an `Image` (and can consult its
/// own cache first).
///
/// Order is the presenting context's display order: the media grid
/// passes its newest-first list, a chat tap passes the conversation's
/// images oldest-first, so "next" always means "the one after this on
/// screen".
public struct ImageGallery {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: String
        /// `nil` for a tombstone (the bytes were reaped) — shown as
        /// unavailable rather than skipped, so the counter matches the
        /// grid the user came from.
        public let url: URL?
        public let expired: Bool
        /// The file's own name, when the source knows one (tracker
        /// attachments do) — the suggested name for Download.
        public let name: String?

        public init(id: String, url: URL?, expired: Bool, name: String? = nil) {
            self.id = id
            self.url = url
            self.expired = expired
            self.name = name
        }
    }

    public let entries: [Entry]
    public let startIndex: Int
    /// The tapped image, already resolved by the call site, so the viewer
    /// opens on it instantly instead of re-fetching.
    public let initial: ViewerImage?
    public let load: @MainActor (URL) async -> ViewerImage?
    /// The original file's bytes, untouched (no decode, no downscale), for
    /// the viewer's Download button. `nil` hides the button.
    public let fetchOriginal: (@MainActor (URL) async -> Data?)?

    /// - Parameters:
    ///   - entries: at least one; an empty list is replaced by a single
    ///     placeholder entry so the viewer never has nothing to show.
    ///   - startIndex: clamped into `entries`.
    public init(
        entries: [Entry],
        startIndex: Int,
        initial: ViewerImage?,
        fetchOriginal: (@MainActor (URL) async -> Data?)? = nil,
        load: @escaping @MainActor (URL) async -> ViewerImage?
    ) {
        let safeEntries = entries.isEmpty
            ? [Entry(id: "placeholder", url: nil, expired: false)]
            : entries
        self.entries = safeEntries
        self.startIndex = min(max(startIndex, 0), safeEntries.count - 1)
        self.initial = initial
        self.load = load
        self.fetchOriginal = fetchOriginal
    }

    /// A gallery of exactly one already-resolved image — no stepping, no
    /// loading. What the legacy single-image call sites present. Pass the
    /// image's `url` and a `fetchOriginal` to offer Download.
    public static func single(
        _ image: Image,
        pixelSize: CGSize? = nil,
        url: URL? = nil,
        name: String? = nil,
        fetchOriginal: (@MainActor (URL) async -> Data?)? = nil
    ) -> ImageGallery {
        ImageGallery(
            entries: [Entry(id: "single", url: url, expired: false, name: name)],
            startIndex: 0,
            initial: ViewerImage(image: image, pixelSize: pixelSize),
            fetchOriginal: fetchOriginal,
            load: { _ in nil }
        )
    }
}
