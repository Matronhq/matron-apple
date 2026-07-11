import Foundation
import MatronJournal

/// Live `MediaService` backed by the journal server's `GET /media/:id`
/// endpoint. The endpoint is live server-side (not dormant) — an unknown or
/// expired blob ref currently returns an error body from the server, which
/// `JournalAPI.mediaData(blobRef:)` maps to a thrown `JournalAPIError`; this
/// service maps that (and any other failure) to `nil`, and the UI already
/// renders placeholders for `nil` image results.
public final class JournalMediaService: MediaService, @unchecked Sendable {
    private let api: JournalAPI

    public init(api: JournalAPI) {
        self.api = api
    }

    /// Resolves a `serverURL/media/<ref>` URL to its raw bytes. Any URL not
    /// under that prefix (e.g. a legacy `mxc://` URL) returns `nil` without
    /// issuing a request.
    public func image(for url: URL) async -> Data? {
        guard let blobRef = Self.blobRef(for: url, serverURL: api.serverURL) else { return nil }
        return try? await api.mediaData(blobRef: blobRef)
    }

    /// Extracts the blob reference from a URL of the form
    /// `serverURL/media/<ref>`. `internal` so the extraction logic itself
    /// can be pinned by a direct test if the URL-matching rules ever grow
    /// more edge cases than the two covered by `JournalMediaServiceTests`.
    static func blobRef(for url: URL, serverURL: URL) -> String? {
        guard url.scheme == serverURL.scheme,
              url.host == serverURL.host,
              url.port == serverURL.port
        else { return nil }

        let mediaPrefix = "/media/"
        guard url.path.hasPrefix(mediaPrefix) else { return nil }
        let ref = String(url.path.dropFirst(mediaPrefix.count))
        return ref.isEmpty ? nil : ref
    }
}
