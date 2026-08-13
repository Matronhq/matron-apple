import Foundation
import SwiftUI

/// Resolves `mxc://` URLs (the only kind Matrix events carry for image and
/// file attachments) into raw bytes the UI can decode. Image attachments
/// in `TimelineItem.image(url:…)` carry an `mxc://` URL that must be
/// downloaded through the SDK's authenticated-media endpoint — the bytes
/// can't be fetched with a plain `URLSession`.
///
/// Lives in `MatronChat` (next to `TimelineService`) rather than its own
/// SPM target so the protocol-and-fake pattern matches the rest of Phase 1.
public protocol MediaService: Sendable {
    /// Resolve an `mxc://` URL to image data. Returns `nil` if the URL is
    /// not an `mxc://` URL or if the SDK cannot fetch it (network error,
    /// missing media, decryption failure).
    func image(for mxc: URL) async -> Data?

    /// Like `fetchBytes(mxcURL:)` but distinguishes a definitive "this blob
    /// no longer exists" (HTTP 404 — permanent: blob ids are immutable, and
    /// the journal's media reaper deletes blobs for over-quota users) from a
    /// transient failure worth retrying. A protocol requirement (with a
    /// default) rather than extension-only so existentials dispatch to the
    /// live service's override, not statically to the default.
    func fetchOutcome(mxcURL: URL) async -> MediaFetchOutcome
}

/// Outcome of a media fetch where the caller needs to tell "gone forever"
/// from "try again" — the file-attachment tap path uses `.notFound` to flip
/// the chip to its Expired state.
public enum MediaFetchOutcome: Sendable {
    case data(Data)
    /// The server definitively reports the blob missing (404). Permanent.
    case notFound
    /// Anything else — network error, auth failure, decode problem.
    case failure
}

public extension MediaService {
    /// Default: no status information available, so a nil byte result is a
    /// plain (retryable) failure. Fakes and the SDK-backed service get this
    /// for free; `JournalMediaService` overrides it to surface the 404.
    func fetchOutcome(mxcURL: URL) async -> MediaFetchOutcome {
        if let data = await image(for: mxcURL) { return .data(data) }
        return .failure
    }
}

public extension MediaService {
    /// Generic bytes accessor used by the fullscreen-attachment
    /// preview path (file attachments → temp-file → QuickLook /
    /// ShareLink). The underlying SDK call (`getMediaContent`) is
    /// kind-agnostic; the existing `image(for:)` already returns the
    /// raw bytes — `fetchBytes(mxcURL:)` exists as a clearer name
    /// for non-image call sites so the public surface signals intent
    /// without needing two parallel implementations on the live
    /// service. Default implementation forwards to `image(for:)`.
    func fetchBytes(mxcURL: URL) async -> Data? {
        await image(for: mxcURL)
    }
}

/// A decoded chat image together with its native bitmap dimensions.
/// The pixel size exists because SwiftUI's `Image` is opaque — once
/// wrapped, the bitmap's resolution is unrecoverable, and the Mac
/// fullscreen viewer needs it to size its sheet without stretching the
/// bitmap past 1:1 (the "small and pixelated" preview bug).
public struct SizedImage {
    public let image: Image
    /// Native bitmap size in pixels — NOT the DPI-scaled point size
    /// `NSImage.size` reports (a 144-DPI screenshot's point size is half
    /// its pixel size).
    public let pixelSize: CGSize

    public init(image: Image, pixelSize: CGSize) {
        self.image = image
        self.pixelSize = pixelSize
    }
}

public extension MediaService {
    /// Convenience wrapper that decodes the resolved bytes into a SwiftUI
    /// `Image`. Cross-platform: iOS uses `UIImage`, macOS uses `NSImage`.
    /// Returns `nil` if the bytes don't decode as a known image format.
    func swiftUIImage(for mxc: URL) async -> Image? {
        await sizedImage(for: mxc)?.image
    }

    /// `swiftUIImage(for:)` plus the decoded bitmap's pixel dimensions.
    /// Protocol-extension so every implementation (live and fakes) gets
    /// it from the existing `image(for:)` bytes.
    func sizedImage(for mxc: URL) async -> SizedImage? {
        guard let data = await image(for: mxc) else { return nil }
        return SizedImage.decode(data)
    }
}

public extension SizedImage {
    /// Decodes raw bytes into a `SizedImage`. Extracted from
    /// `sizedImage(for:)` so callers that fetch through
    /// `fetchOutcome(mxcURL:)` (which must see the 404, not just nil
    /// bytes) can reuse the exact same decode.
    static func decode(_ data: Data) -> SizedImage? {
        #if canImport(UIKit) && !os(macOS)
        guard let ui = UIImage(data: data) else { return nil }
        // `UIImage(data:)` always decodes at scale 1, but multiply anyway
        // so a future scale-aware decode keeps the pixel math right.
        let pixels = CGSize(width: ui.size.width * ui.scale,
                            height: ui.size.height * ui.scale)
        return SizedImage(image: Image(uiImage: ui), pixelSize: pixels)
        #elseif os(macOS)
        guard let ns = NSImage(data: data) else { return nil }
        // `NSImage.size` is DPI-scaled points; the real resolution lives
        // on the bitmap reps. Take the largest rep (HEIC containers also
        // carry an embedded thumbnail rep). Vector reps report 0 pixels —
        // fall back to the point size for those.
        let repSizes: [CGSize] = ns.representations.compactMap { rep in
            let size = CGSize(width: CGFloat(rep.pixelsWide),
                              height: CGFloat(rep.pixelsHigh))
            return size.width > 0 && size.height > 0 ? size : nil
        }
        let largest = repSizes.max { a, b in
            a.width * a.height < b.width * b.height
        }
        let pixels = largest ?? ns.size
        return SizedImage(image: Image(nsImage: ns), pixelSize: pixels)
        #else
        return nil
        #endif
    }
}
