import SwiftUI
import MatronModels

/// The images an item thread has loaded, by blob ref, for a host to hand
/// `ItemDetailView` through its `image` closure.
///
/// An observable object, not a `@State` dictionary, because of who reads
/// it. `ItemDetailView` reads an image where it is drawn, so with this
/// store an image arriving re-runs that one image view and nothing else.
/// A `@State` dictionary belongs to the host: each image that landed
/// re-ran the host's body, which rebuilt the whole thread, once per image,
/// while the reader was scrolling it. `ItemDetailImageIsolationTests`.
@MainActor
public final class ItemImageStore {
    /// One blob's image, observed on its own: a view that read one ref is
    /// not re-run when another's image arrives.
    @Observable
    final class Slot {
        var image: Image?
        var animation: AnimatedImageSource?
    }

    private var slots: [String: Slot] = [:]

    nonisolated public init() {}

    public subscript(blobRef: String) -> Image? {
        get { slot(blobRef).image }
        set { slot(blobRef).image = newValue }
    }

    /// The frames of a blob whose file is animated (GIF, APNG, WebP).
    public func animation(_ blobRef: String) -> AnimatedImageSource? {
        slot(blobRef).animation
    }

    /// Stores a decoded image and its frames together, so a view never
    /// sees one without the other.
    public func store(_ blobRef: String, image: Image, animation: AnimatedImageSource?) {
        let slot = slot(blobRef)
        slot.animation = animation
        slot.image = image
    }

    /// Made on first read as well as first write: a view that read "not
    /// loaded yet" must be watching the slot the image later lands in.
    private func slot(_ blobRef: String) -> Slot {
        if let slot = slots[blobRef] { return slot }
        let slot = Slot()
        slots[blobRef] = slot
        return slot
    }
}
