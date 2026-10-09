import SwiftUI

/// The images an item thread has loaded, by blob ref, for a host to hand
/// `ItemDetailView` through its `image` closure.
///
/// An observable object, not a `@State` dictionary, because of who reads
/// it. `ItemDetailView` reads an image where it is drawn, so with this
/// store an image arriving re-runs the thread's image views and nothing
/// else. A `@State` dictionary belongs to the host: each image that landed
/// re-ran the host's body, which rebuilt the whole thread, once per image,
/// while the reader was scrolling it. `ItemDetailImageIsolationTests`.
@MainActor
@Observable
public final class ItemImageStore {
    private var images: [String: Image] = [:]

    nonisolated public init() {}

    public subscript(blobRef: String) -> Image? {
        get { images[blobRef] }
        set { images[blobRef] = newValue }
    }
}
