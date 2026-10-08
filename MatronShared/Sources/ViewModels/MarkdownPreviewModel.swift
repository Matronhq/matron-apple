import Foundation
import Observation
import MatronChat
import MatronModels

/// Decoded markdown previews for this run of the app, per media URL (one
/// blob on one journal). In memory only; the OS may evict under pressure.
public final class MarkdownPreviewTextCache: @unchecked Sendable {
    public static let shared = MarkdownPreviewTextCache()

    private final class Box {
        let document: MarkdownPreviewDocument
        /// The bytes as fetched, so a Share file written from the cache is
        /// the file itself — not the decoded text, which has lost its
        /// byte-order mark and any invalid bytes.
        let data: Data
        init(_ document: MarkdownPreviewDocument, data: Data) {
            self.document = document
            self.data = data
        }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        // Cost is the bytes plus the text's UTF-8 size; a dozen big files
        // at most.
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    public init() {}

    public func document(for key: String) -> MarkdownPreviewDocument? {
        cache.object(forKey: key as NSString)?.document
    }

    /// The cached document and the bytes it was decoded from.
    public func entry(for key: String) -> (document: MarkdownPreviewDocument, data: Data)? {
        cache.object(forKey: key as NSString).map { ($0.document, $0.data) }
    }

    public func store(_ document: MarkdownPreviewDocument, data: Data, for key: String) {
        cache.setObject(Box(document, data: data), forKey: key as NSString,
                        cost: data.count + document.text.utf8.count)
    }

    public func removeAll() { cache.removeAllObjects() }
}

/// State of the markdown preview panel (Mac) or sheet (iPhone): which file
/// is open, whether its text has loaded, and the Source toggle. Opening a
/// second file replaces the first; closing drops everything but the text
/// cache.
@MainActor @Observable
public final class MarkdownPreviewModel {
    /// Fetches the bytes behind a media URL through the app's authenticated
    /// media path (`MediaService.fetchOutcome(mxcURL:)`).
    public typealias Fetch = @Sendable (URL) async -> MediaFetchOutcome

    public private(set) var request: MarkdownPreviewRequest?
    public private(set) var phase: MarkdownPreviewPhase = .idle
    /// Rendered (`false`) or the raw text in monospace (`true`).
    public var showsSource = false
    /// The file on disk for Share, once the text has loaded.
    public private(set) var shareURL: URL?

    public var isOpen: Bool { request != nil }

    /// Views elsewhere in the window that bind Esc themselves while they
    /// are up (the Mac chat's search bar). Two `.cancelAction` buttons in
    /// one window make Esc ambiguous, so the panel gives Esc up while any
    /// holder is registered and keeps only its close button.
    public private(set) var escapeHolders: Set<String> = []
    public var closesOnEscape: Bool { escapeHolders.isEmpty }

    public func holdEscape(_ holder: String, _ holds: Bool) {
        if holds {
            escapeHolders.insert(holder)
        } else {
            escapeHolders.remove(holder)
        }
    }

    /// The host's own download/open path for the open file — what a tap
    /// did before the preview existed. Offered when the preview can't show
    /// the file.
    @ObservationIgnored public private(set) var download: (() -> Void)?

    @ObservationIgnored private var fetch: Fetch?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let cache: MarkdownPreviewTextCache
    @ObservationIgnored private let writeShareFile: (Data, MarkdownPreviewRequest) -> URL?

    public init(cache: MarkdownPreviewTextCache = .shared,
                writeShareFile: @escaping (Data, MarkdownPreviewRequest) -> URL? = MarkdownPreviewModel.tempFile) {
        self.cache = cache
        self.writeShareFile = writeShareFile
    }

    /// Shows `request`, replacing whatever was open. Re-opening the file
    /// already on screen keeps its state (and the Source toggle) unless it
    /// failed, when it tries again.
    public func open(_ request: MarkdownPreviewRequest, fetch: @escaping Fetch, download: (() -> Void)? = nil) {
        self.fetch = fetch
        self.download = download
        if request == self.request, !isFailed { return }
        self.request = request
        showsSource = false
        shareURL = nil
        load()
    }

    public func close() {
        loadTask?.cancel()
        loadTask = nil
        request = nil
        fetch = nil
        download = nil
        phase = .idle
        showsSource = false
        shareURL = nil
    }

    public func retry() {
        guard request != nil else { return }
        load()
    }

    /// Waits for the fetch in flight, if any (tests).
    public func waitForLoad() async {
        await loadTask?.value
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func load() {
        loadTask?.cancel()
        loadTask = nil
        guard let request, let fetch else { return }
        if let entry = cache.entry(for: request.id) {
            phase = .loaded(entry.document)
            shareURL = writeShareFile(entry.data, request)
            return
        }
        phase = .loading
        loadTask = Task { [weak self, cache, writeShareFile] in
            let outcome = await fetch(request.mediaURL)
            guard !Task.isCancelled else { return }
            let next: MarkdownPreviewPhase
            var share: URL?
            switch outcome {
            case .data(let data) where Int64(data.count) > MarkdownPreview.maxBytes:
                next = .failed(.tooLarge)
            case .data(let data):
                let document = await Task.detached(priority: .userInitiated) {
                    MarkdownPreviewDocument(data: data)
                }.value
                cache.store(document, data: data, for: request.id)
                next = .loaded(document)
                share = writeShareFile(data, request)
            case .notFound:
                next = .failed(.expired)
            case .failure:
                next = .failed(.unavailable)
            }
            guard let self, !Task.isCancelled, self.request == request else { return }
            self.phase = next
            self.shareURL = share
        }
    }

    /// The default Share file: the attachment's own temp file, the same
    /// one a download of it writes.
    public nonisolated static func tempFile(_ data: Data, _ request: MarkdownPreviewRequest) -> URL? {
        if let existing = AttachmentTempFiles.existingFile(name: request.name, blobRef: request.blobRef) {
            return existing
        }
        return try? AttachmentTempFiles.write(data, name: request.name, blobRef: request.blobRef)
    }
}
