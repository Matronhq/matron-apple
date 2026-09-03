import Foundation
import SwiftUI
import ImageIO
import MatronChat
import MatronJournal
#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The two JournalStore reads the media browser needs, as a protocol so
/// tests fake the store. Conformance for the real store is declared here
/// (MatronJournal cannot import this module).
public protocol MediaBrowserStoreReading {
    func attachmentEvents(convoID: String) throws -> [JournalEvent]
    func linkCandidateEvents(convoID: String) throws -> [JournalEvent]
}

extension JournalStore: MediaBrowserStoreReading {}

/// Backs the per-chat "Media, Files and Links" sheet. Reads the FULL local
/// event history (the timeline's `ChatViewModel.items` is a 120-row window —
/// it cannot see a chat's older attachments), maps attachments through the
/// same payload contract the timeline uses (`JournalTimelineMapper`), and
/// extracts links with `LinkExtractor`.
///
/// Store reads run on the main actor: both queries are single indexed GRDB
/// reads returning at most a few thousand small rows (the LIKE prefilter
/// bounds the text set), measured in low milliseconds — not worth an
/// unchecked-Sendable retrofit on JournalStore.
@MainActor @Observable
public final class MediaBrowserViewModel {
    public struct MediaEntry: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let url: URL?
        public let caption: String?
        public var expired: Bool
    }
    public struct FileEntry: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let url: URL?
        public let name: String
        public let sizeBytes: Int64?
        public let caption: String?
        public var expired: Bool
    }
    public struct LinkEntry: Identifiable, Equatable, Sendable {
        public let id: String        // absoluteString — unique post-dedup
        public let url: URL
        public let context: String   // first line of the containing message
        public let timestamp: Date
    }

    public private(set) var mediaItems: [MediaEntry] = []
    public private(set) var fileItems: [FileEntry] = []
    public private(set) var links: [LinkEntry] = []
    public private(set) var loadFailed = false

    private let store: MediaBrowserStoreReading
    private let convoID: String
    private let serverURL: URL
    private let media: any MediaService

    /// Downscaled thumbnails, small LRU — a 12 MB original must not live
    /// once per grid cell. ~200 pt cells → 400 px covers 2× displays.
    private var thumbnails: [URL: Image] = [:]
    private var thumbnailOrder: [URL] = []
    private var unavailable: Set<URL> = []
    private var inFlight: [URL: Task<Image?, Never>] = [:]
    private static let thumbnailCacheLimit = 64
    public static let thumbnailMaxPixel: CGFloat = 400

    public init(store: MediaBrowserStoreReading, convoID: String,
                serverURL: URL, media: any MediaService) {
        self.store = store
        self.convoID = convoID
        self.serverURL = serverURL
        self.media = media
    }

    public func load() async {
        do {
            let attachments = try store.attachmentEvents(convoID: convoID)
            let candidates = try store.linkCandidateEvents(convoID: convoID)
            let (mediaAcc, fileAcc) = Self.partition(attachments, serverURL: serverURL)
            var seen = Set<String>()
            var linkAcc: [LinkEntry] = []
            for event in candidates {   // newest first → first sighting IS the newest
                guard let body = event.payload["body"] as? String else { continue }
                let context = String(
                    (body.split(whereSeparator: \.isNewline).first ?? "").prefix(200))
                for url in LinkExtractor.links(in: body)
                where seen.insert(url.absoluteString).inserted {
                    linkAcc.append(LinkEntry(id: url.absoluteString, url: url,
                                             context: context, timestamp: event.ts))
                }
            }
            mediaItems = mediaAcc
            fileItems = fileAcc
            links = linkAcc
            loadFailed = false
        } catch {
            loadFailed = true
            mediaItems = []; fileItems = []; links = []
        }
    }

    /// The conversation's images as the media grid lists them — store
    /// order (newest first), tombstones kept. This is the list the
    /// fullscreen viewer's previous/next stepping walks, and a chat tap
    /// builds it straight from the store without a browser view model,
    /// so it goes through the same mapping as `load()` and can never
    /// disagree with the grid.
    nonisolated public static func imageEntries(
        store: MediaBrowserStoreReading, convoID: String, serverURL: URL
    ) throws -> [MediaEntry] {
        partition(try store.attachmentEvents(convoID: convoID), serverURL: serverURL).media
    }

    /// Splits attachment events into the grid's media and file lists via
    /// the timeline mapper, so the browser shows exactly what the chat
    /// rendered (same payload contract, same expiry/tombstone handling).
    nonisolated private static func partition(
        _ events: [JournalEvent], serverURL: URL
    ) -> (media: [MediaEntry], files: [FileEntry]) {
        var mediaAcc: [MediaEntry] = []
        var fileAcc: [FileEntry] = []
        for event in events {
            guard let item = JournalTimelineMapper.timelineItem(
                from: event, ownSender: "", serverURL: serverURL) else { continue }
            switch item.kind {
            case let .image(url, caption, _, expired):
                mediaAcc.append(MediaEntry(id: event.seq, url: url,
                                           caption: caption, expired: expired))
            case let .file(url, name, caption, size, expired):
                fileAcc.append(FileEntry(id: event.seq, url: url, name: name,
                                         sizeBytes: size, caption: caption,
                                         expired: expired))
            default:
                continue
            }
        }
        return (mediaAcc, fileAcc)
    }

    public func isUnavailable(_ url: URL) -> Bool { unavailable.contains(url) }

    private enum ThumbOutcome {
        case image(Image), gone, failed
    }

    /// Fetch + downscale one grid thumbnail. A 404 is permanent (blob ids
    /// are immutable; the journal reaper deletes over-quota blobs) — the
    /// entry flips to expired and is never re-fetched. In-flight requests
    /// coalesce onto a SINGLE shared `Task` that both issues the one
    /// `fetchOutcome` call and applies the cache/expire side effects itself
    /// — a joiner's `await task.value` cannot resume until those side
    /// effects have already run, so there is no window where a joiner
    /// observes `.gone` as a plain `nil` with `isUnavailable == false`.
    public func thumbnail(for url: URL) async -> Image? {
        if let cached = thumbnails[url] { return cached }
        guard !unavailable.contains(url) else { return nil }
        if let running = inFlight[url] { return await running.value }
        let task = Task<Image?, Never> { @MainActor [weak self, media] in
            guard let self else { return nil }
            let outcome: ThumbOutcome
            switch await media.fetchOutcome(mxcURL: url) {
            case .notFound:
                outcome = .gone
            case .failure:
                outcome = .failed
            case .data(let data):
                if let image = Self.downscaled(data, maxPixel: Self.thumbnailMaxPixel) {
                    outcome = .image(image)
                } else {
                    outcome = .failed
                }
            }
            let result: Image?
            switch outcome {
            case .image(let image):
                self.cacheThumbnail(image, for: url)
                result = image
            case .gone:
                self.markExpired(url)
                result = nil
            case .failed:
                result = nil
            }
            // Clear before returning: no `await` follows, so this happens
            // atomically (on the serial MainActor) before any awaiter of
            // `task.value` — owner or joiner — resumes.
            self.inFlight[url] = nil
            return result
        }
        inFlight[url] = task
        return await task.value
    }

    private func cacheThumbnail(_ image: Image, for url: URL) {
        thumbnails[url] = image
        thumbnailOrder.removeAll { $0 == url }
        thumbnailOrder.append(url)
        if thumbnailOrder.count > Self.thumbnailCacheLimit,
           let evicted = thumbnailOrder.first {
            thumbnailOrder.removeFirst()
            thumbnails.removeValue(forKey: evicted)
        }
    }

    private func markExpired(_ url: URL) {
        unavailable.insert(url)
        for index in mediaItems.indices where mediaItems[index].url == url {
            mediaItems[index].expired = true
        }
        for index in fileItems.indices where fileItems[index].url == url {
            fileItems[index].expired = true
        }
    }

    private static func downscaled(_ data: Data, maxPixel: CGFloat) -> Image? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        #if canImport(UIKit) && !os(macOS)
        return Image(uiImage: UIImage(cgImage: cg))
        #elseif os(macOS)
        return Image(nsImage: NSImage(cgImage: cg, size: .zero))
        #else
        return nil
        #endif
    }
}
