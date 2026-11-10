import SwiftUI
import MatronModels

/// A project's files, newest first: three to a row on a wide page, two on
/// a narrow one. A picture is its thumbnail, a video the dark ▶ panel, and
/// anything else a tile naming its kind; each has its name and where it
/// was posted under it. A tile opens through `onOpenFile`; reaching the
/// end asks for more while `hasMore`.
public struct ProjectFilesGridView: View {
    let files: [ProjectFile]
    let images: [String: Image]
    let now: Date
    let hasMore: Bool
    let onOpenFile: (ProjectFile) -> Void
    let onLoadMore: () -> Void

    /// `images` are the loaded pictures by blob id; `now` dates each tile ("chat · 5d").
    public init(files: [ProjectFile], images: [String: Image], now: Date, hasMore: Bool,
                onOpenFile: @escaping (ProjectFile) -> Void, onLoadMore: @escaping () -> Void) {
        self.files = files; self.images = images; self.now = now; self.hasMore = hasMore
        self.onOpenFile = onOpenFile; self.onLoadMore = onLoadMore
    }

    private typealias M = ProjectPageMetrics

    /// Three tiles to a row on a wide page, two on a narrow one.
    static func columnCount(pageWidth: CGFloat) -> Int {
        pageWidth >= TimelinePage.wideWidth ? 3 : 2
    }

    /// Width over height of a tile's picture: `ProjectFileTile`'s.
    private static let tileAspectRatio: CGFloat = 4 / 3

    public var body: some View {
        // GeometryReader outside the scroll: the width is there on the first
        // layout, so a wide window never draws two columns first.
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    TimelineListHeader(title: TimelineFormat.sectionTitle(.files), lede: nil)
                    grid(columns: Self.columnCount(pageWidth: geo.size.width))
                    if hasMore {
                        // Keyed by the file count, so a page too short to
                        // scroll still asks for the one after it.
                        Color.clear.frame(height: 1).id(files.count).onAppear(perform: onLoadMore)
                    }
                }
                .frame(maxWidth: TimelineListHeader.maxWidth, alignment: .leading)
                .padding(TimelinePage.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("projects.files")
    }

    private func grid(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TimelinePage.cardSpacing, alignment: .top),
                                 count: columns),
                  alignment: .leading, spacing: TimelinePage.cardSpacing) {
            ForEach(files) { file in
                Button { onOpenFile(file) } label: { tile(file) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("projects.files.\(file.id)")
            }
        }
    }

    @ViewBuilder private func tile(_ file: ProjectFile) -> some View {
        if ProjectGallery.media(file).isVideo {
            videoTile(file)
        } else {
            ProjectFileTile(file: file, image: images[file.blobID], now: now,
                            nameFont: M.tileNameFont, metaFont: M.tileMetaFont)
        }
    }

    /// A video has no poster frame: the timeline's dark ▶ panel, in the
    /// shape and under the lines of a `ProjectFileTile`.
    private func videoTile(_ file: ProjectFile) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let meta = ProjectFeedFormat.fileMeta(file, now: now)
        return VStack(alignment: .leading, spacing: 4) {
            TimelineMediaView(media: ProjectGallery.media(file), image: nil, aspectRatio: Self.tileAspectRatio)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.10)))
            Text(ProjectFeedFormat.fileName(file)).font(M.tileNameFont).foregroundStyle(Color.primary).lineLimit(1)
            Text(meta).font(M.tileMetaFont.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video \(ProjectFeedFormat.fileName(file)), \(meta)")
    }
}
