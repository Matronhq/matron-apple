import SwiftUI
import MatronChat

/// The timeline's pictures by blob id, loaded once each through the
/// session's authenticated media service, as the project page loads its
/// own. Only the current page's stay decoded, each with its pixel size so
/// a view can tell a very wide or very tall picture from one that fills.
@MainActor @Observable
public final class TimelineImages {
    public private(set) var images: [String: Image] = [:]
    /// Each loaded picture's size in pixels, by blob id.
    public private(set) var sizes: [String: CGSize] = [:]

    public init() {}

    public func load(_ blobIDs: [String], media: any MediaService, base: URL) async {
        let wanted = Set(blobIDs)
        images = images.filter { wanted.contains($0.key) }
        sizes = sizes.filter { wanted.contains($0.key) }
        for blobID in blobIDs where images[blobID] == nil {
            let url = base.appendingPathComponent("media").appendingPathComponent(blobID)
            guard let sized = await media.sizedImage(for: url) else { continue }
            // A newer page restarted the load: keep the old page's bitmap out.
            guard !Task.isCancelled else { return }
            images[blobID] = sized.image
            sizes[blobID] = sized.pixelSize
        }
    }
}
