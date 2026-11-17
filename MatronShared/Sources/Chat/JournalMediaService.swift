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
    /// Bytes already fetched, by blob id. Nil keeps every fetch on the
    /// network (tests, previews).
    private let cache: MediaDiskCache?

    public init(api: JournalAPI, cache: MediaDiskCache? = nil) {
        self.api = api
        self.cache = cache
    }

    /// Resolves a `serverURL/media/<ref>` URL to its raw bytes. Any URL not
    /// under that prefix (e.g. a legacy `mxc://` URL) returns `nil` without
    /// issuing a request.
    public func image(for url: URL) async -> Data? {
        guard let blobRef = Self.blobRef(for: url, serverURL: api.serverURL) else { return nil }
        if let cached = await cache?.data(for: blobRef) { return cached }
        guard let data = try? await api.mediaData(blobRef: blobRef) else { return nil }
        await cache?.store(data, for: blobRef)
        return data
    }

    /// Surfaces the server's 404 as `.notFound` so the file-tap path can
    /// mark a reaped blob permanently unavailable instead of treating every
    /// failure as retryable. A URL outside this journal's media namespace is
    /// `.failure`, not `.notFound` — we know nothing definitive about it.
    public func fetchOutcome(mxcURL: URL) async -> MediaFetchOutcome {
        guard let blobRef = Self.blobRef(for: mxcURL, serverURL: api.serverURL) else { return .failure }
        if let cached = await cache?.data(for: blobRef) { return .data(cached) }
        do {
            let data = try await api.mediaData(blobRef: blobRef)
            await cache?.store(data, for: blobRef)
            return .data(data)
        } catch JournalAPIError.notFound {
            return .notFound
        } catch {
            return .failure
        }
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
