import SwiftUI
import MatronModels

/// The row of attachments waiting above the composer, shown between picking
/// something and sending it.
///
/// Shared rather than written twice: the tray is the only place a user sees
/// what's about to leave, and iOS and Mac disagreeing about that — one
/// showing a thumbnail where the other shows a chip, or one offering a
/// remove button the other doesn't — would be a difference nobody chose. The
/// same reason `attachFiles(_:)` is a single choke point in the view model.
///
/// Empty by design when there's nothing staged: the caller can render it
/// unconditionally and it takes no space.
public struct AttachmentTray: View {
    private let attachments: [StagedAttachment]
    private let onRemove: (UUID) -> Void

    public init(attachments: [StagedAttachment], onRemove: @escaping (UUID) -> Void) {
        self.attachments = attachments
        self.onRemove = onRemove
    }

    public var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        StagedAttachmentChip(attachment: attachment) { onRemove(attachment.id) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            // The tray can only ever be one row tall, but a ScrollView will
            // happily claim the whole composer if left to size itself.
            .frame(height: StagedAttachmentChip.side + 16)
        }
    }
}

/// One staged attachment: an image preview, or a labelled chip for anything
/// else, with a remove button.
struct StagedAttachmentChip: View {
    let attachment: StagedAttachment
    let onRemove: () -> Void

    /// Square side for the preview. Big enough to recognise a photo at a
    /// glance, small enough that several fit without the tray dominating a
    /// phone's composer.
    static let side: CGFloat = 56

    var body: some View {
        content
            .frame(width: attachment.isImage ? Self.side : nil, height: Self.side)
            .background(Color.matronCodeBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) { removeButton }
            // The button hangs over the corner, so the chip needs room for
            // it or it clips against the neighbouring attachment.
            .padding(.top, 6)
            .padding(.trailing, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        if attachment.isImage, let preview = ImagePreview.load(attachment.url) {
            preview
                .resizable()
                .scaledToFill()
                .frame(width: Self.side, height: Self.side)
                .clipped()
        } else {
            HStack(spacing: 8) {
                Image(systemName: attachment.isImage ? "photo" : "doc")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .font(.caption)
                        .lineLimit(1)
                    Text(attachment.formattedSize)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            // Without a ceiling one long filename pushes every other
            // attachment off the side of the tray.
            .frame(maxWidth: 160)
        }
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark.circle.fill")
                .font(.body)
                .symbolRenderingMode(.palette)
                // Two-tone so the glyph stays legible against a photo of
                // any colour — a plain tinted ✕ vanishes on a busy image.
                .foregroundStyle(.white, .black.opacity(0.6))
        }
        .buttonStyle(.plain)
        .offset(x: 6, y: -6)
        .accessibilityLabel("Remove \(attachment.filename)")
    }

    private var accessibilityLabel: String {
        let kind = attachment.isImage ? "Image" : "File"
        return "\(kind) attachment, \(attachment.filename), \(attachment.formattedSize)"
    }
}

/// Loads a staged image off disk for the tray's preview.
///
/// Deliberately synchronous and uncached: the file is local, already read
/// once at stage time, and the tray holds a handful of items at most — the
/// bytes are in the page cache. An async loader here would flash a
/// placeholder for a picture the user just chose, which reads as a bug.
enum ImagePreview {
    static func load(_ url: URL) -> Image? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}
