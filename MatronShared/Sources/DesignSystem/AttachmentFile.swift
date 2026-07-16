import SwiftUI

/// Shared design-system primitive for a non-image file attachment in the
/// chat timeline. Renders a generic doc icon, the filename, and (optionally)
/// the size formatted via `ByteCountFormatter.file`. Tap to invoke `onTap`
/// (e.g. to share/export the file).
///
/// An optional `caption` — what the user typed when they attached it —
/// renders underneath, mirroring `AttachmentImage`. Captions aren't
/// image-only: a PDF sent with "review this before Friday" has to show the
/// sentence too.
public struct AttachmentFile: View {
    let filename: String
    let sizeBytes: Int64?
    let caption: String?
    let onTap: (() -> Void)?

    public init(
        filename: String,
        sizeBytes: Int64?,
        caption: String? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.caption = caption
        self.onTap = onTap
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: "doc")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(filename).font(.callout).lineLimit(1)
                    if let sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            // `Color.matronCodeBg` is the cross-platform alias defined in
            // MarkdownText.swift — `Color(.systemGray6)` is iOS-only and would
            // break the Mac build.
            .background(Color.matronCodeBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { onTap?() }

            // Outside the tappable chip: the caption is the message, not a
            // handle for opening the file.
            if let caption, !caption.isEmpty {
                Text(caption).font(.callout)
            }
        }
    }
}
