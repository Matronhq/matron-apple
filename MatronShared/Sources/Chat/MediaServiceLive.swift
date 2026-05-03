import Foundation
import MatrixRustSDK
import MatronModels
import MatronSync

/// Live `MediaService` backed by the Matrix Rust SDK's authenticated-media
/// endpoint (`Client.getMediaContent`). Resolved bytes are cached in an
/// `NSCache` keyed by the original `mxc://` URL string. `NSCache` evicts
/// under memory pressure for free; we set a 64 MB ceiling to bound steady-
/// state usage on iOS without paging the system.
public final class MediaServiceLive: MediaService, @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession

    private let cache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.totalCostLimit = 64 * 1024 * 1024  // 64 MB ceiling
        return c
    }()

    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
    }

    public func image(for mxc: URL) async -> Data? {
        guard mxc.scheme == "mxc" else { return nil }
        let key = mxc.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }
        do {
            let client = try await provider.client(for: session)
            let source = try MediaSource.fromUrl(url: mxc.absoluteString)
            let data = try await client.getMediaContent(mediaSource: source)
            let nsdata = NSData(data: data)
            cache.setObject(nsdata, forKey: key, cost: nsdata.length)
            return data
        } catch {
            return nil
        }
    }
}
