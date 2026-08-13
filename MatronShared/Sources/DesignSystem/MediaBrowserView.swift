import SwiftUI

/// Per-chat "Media, Files and Links" browser body — WhatsApp's media
/// browser, Matron-shaped. Pure data + closures (this module cannot see
/// view models); the platform sheets in Matron/ and MatronMac/ own the
/// MediaBrowserViewModel and map its entries into the row/cell structs.
public struct MediaBrowserView: View {
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case media = "Media", files = "Files", links = "Links"
        public var id: String { rawValue }
    }

    public struct MediaCell: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let url: URL?
        public let expired: Bool
        /// Whether this cell's full-size image fetch is currently in
        /// flight — mirrors `FileRow.isLoading`'s spinner. Defaults to
        /// `false` so existing call sites (and snapshot fixtures) keep
        /// compiling unchanged.
        public let isLoading: Bool
        public init(id: Int64, url: URL?, expired: Bool, isLoading: Bool = false) {
            self.id = id
            self.url = url
            self.expired = expired
            self.isLoading = isLoading
        }
    }

    public struct FileRow: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let url: URL?
        public let name: String
        public let sizeBytes: Int64?
        public let expired: Bool
        public let isLoading: Bool
        public init(id: Int64, url: URL?, name: String, sizeBytes: Int64?, expired: Bool, isLoading: Bool) {
            self.id = id
            self.url = url
            self.name = name
            self.sizeBytes = sizeBytes
            self.expired = expired
            self.isLoading = isLoading
        }
    }

    public struct LinkRow: Identifiable, Equatable, Sendable {
        public let id: String
        public let url: URL
        public let context: String
        public let date: Date
        public init(id: String, url: URL, context: String, date: Date) {
            self.id = id
            self.url = url
            self.context = context
            self.date = date
        }
    }

    let media: [MediaCell]
    let files: [FileRow]
    let links: [LinkRow]
    let loadFailed: Bool
    let thumbnail: (URL) async -> Image?
    let onMediaTap: (MediaCell) -> Void
    let onFileTap: (FileRow) -> Void
    let onLinkTap: (LinkRow) -> Void
    @State private var tab: Tab

    public init(
        media: [MediaCell], files: [FileRow], links: [LinkRow],
        loadFailed: Bool = false,
        initialTab: Tab = .media,
        thumbnail: @escaping (URL) async -> Image? = { _ in nil },
        onMediaTap: @escaping (MediaCell) -> Void = { _ in },
        onFileTap: @escaping (FileRow) -> Void = { _ in },
        onLinkTap: @escaping (LinkRow) -> Void = { _ in }
    ) {
        self.media = media
        self.files = files
        self.links = links
        self.loadFailed = loadFailed
        self.thumbnail = thumbnail
        self.onMediaTap = onMediaTap
        self.onFileTap = onFileTap
        self.onLinkTap = onLinkTap
        _tab = State(initialValue: initialTab)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $tab) {
                ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            if loadFailed {
                ContentUnavailableView("Couldn't load",
                                       systemImage: "exclamationmark.triangle")
                    .frame(maxHeight: .infinity)
            } else {
                switch tab {
                case .media: mediaGrid
                case .files: fileList
                case .links: linkList
                }
            }
        }
    }

    @ViewBuilder private var mediaGrid: some View {
        if media.isEmpty {
            ContentUnavailableView("No media yet",
                                   systemImage: "photo.on.rectangle.angled")
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)],
                          spacing: 2) {
                    ForEach(media) { cell in
                        MediaThumbCell(cell: cell, thumbnail: thumbnail,
                                       onTap: { onMediaTap(cell) })
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // `List` (NSTableView-backed on macOS) doesn't populate its rows when
    // snapshotted via `NSHostingView.fittingSize` + `cacheDisplay` — the
    // table view's lazy reload only fires once it's actually appeared in a
    // window, so recorded baselines came back with the picker but a blank
    // body below it. A plain `ScrollView`/`LazyVStack` (same pattern as
    // `mediaGrid`'s `LazyVGrid`) is pure SwiftUI and renders deterministically
    // in that harness, so both row lists use it instead.
    @ViewBuilder private var fileList: some View {
        if files.isEmpty {
            ContentUnavailableView("No files yet", systemImage: "doc")
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(files) { row in
                        AttachmentFile(filename: row.name, sizeBytes: row.sizeBytes,
                                       isLoading: row.isLoading, isExpired: row.expired,
                                       onTap: { onFileTap(row) })
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    @ViewBuilder private var linkList: some View {
        if links.isEmpty {
            ContentUnavailableView("No links yet", systemImage: "link")
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(links) { row in
                        Button { onLinkTap(row) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.url.absoluteString)
                                    .font(.callout)
                                    .foregroundStyle(.tint)
                                    .lineLimit(1)
                                Text(row.context)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(row.date, format: .relative(presentation: .named))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Link, \(row.url.absoluteString)")
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        Divider().padding(.leading)
                    }
                }
            }
        }
    }
}

/// One grid cell: async thumbnail with a placeholder; expired renders the
/// dimmed clock-photo treatment (mirrors AttachmentFile's doc.badge.clock).
private struct MediaThumbCell: View {
    let cell: MediaBrowserView.MediaCell
    let thumbnail: (URL) async -> Image?
    let onTap: () -> Void
    @State private var image: Image?

    var body: some View {
        Button(action: { if !cell.expired && !cell.isLoading { onTap() } }) {
            ZStack {
                Rectangle().fill(.quaternary)
                if cell.expired {
                    // "photo.badge.clock" fails to resolve on this SDK
                    // (renders blank) — substitute per the media-browser
                    // spec's documented fallback.
                    Image(systemName: "clock.badge.xmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else if let image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
                // While the full-size fetch is in flight, mirror
                // AttachmentFile's spinner so a re-tap reads as "hold on"
                // rather than a dead tap.
                if cell.isLoading {
                    Rectangle().fill(.black.opacity(0.35))
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(minWidth: 110, minHeight: 110)
            .aspectRatio(1, contentMode: .fill)
            .clipped()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cell.expired ? "Image, expired" : (cell.isLoading ? "Image, loading" : "Image"))
        .task(id: cell.url) {
            guard !cell.expired, let url = cell.url, image == nil else { return }
            image = await thumbnail(url)
        }
    }
}
