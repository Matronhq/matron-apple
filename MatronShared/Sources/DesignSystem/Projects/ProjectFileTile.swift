import SwiftUI
import MatronModels

/// One tile of a project page's "Files and images": the image's thumbnail
/// (a grey placeholder until the host has loaded it), or a document tile
/// naming the extension; then the name and "#5008 · 1d" / "chat · 5d".
/// Hosts load the bytes (they hold the session's media service) and wrap
/// the tile in the button that opens it.
public struct ProjectFileTile: View {
    let file: ProjectFile
    let image: Image?
    let now: Date
    let nameFont: Font
    let metaFont: Font

    public init(file: ProjectFile, image: Image?, now: Date, nameFont: Font = .caption, metaFont: Font = .caption2) {
        self.file = file; self.image = image; self.now = now; self.nameFont = nameFont; self.metaFont = metaFont
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            thumbnail
            Text(ProjectFeedFormat.fileName(file)).font(nameFont).foregroundStyle(Color.primary).lineLimit(1)
            Text(ProjectFeedFormat.fileMeta(file, now: now)).font(metaFont.monospacedDigit())
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.isImage ? "Image" : "File") \(ProjectFeedFormat.fileName(file)), "
                            + ProjectFeedFormat.fileMeta(file, now: now))
    }

    /// 4:3, rounded, filled edge to edge: an image is cropped to fit.
    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay { content }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
    }

    @ViewBuilder private var content: some View {
        if let image {
            image.resizable().scaledToFill()
        } else if file.isImage {
            Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
        } else {
            Text(ProjectFeedFormat.fileExtension(file))
                .font(.system(size: 13, weight: .bold).monospaced())
                .foregroundStyle(Color.red)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.red, lineWidth: 1.5))
        }
    }
}
