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

public extension MediaService {
    /// Convenience wrapper that decodes the resolved bytes into a SwiftUI
    /// `Image`. Cross-platform: iOS uses `UIImage`, macOS uses `NSImage`.
    /// Returns `nil` if the bytes don't decode as a known image format.
    func swiftUIImage(for mxc: URL) async -> Image? {
        guard let data = await image(for: mxc) else { return nil }
        #if canImport(UIKit) && !os(macOS)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #elseif os(macOS)
        guard let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
        #else
        return nil
        #endif
    }
}
