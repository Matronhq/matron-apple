import SwiftUI

/// Shared design-system primitive for a non-image file attachment in the
/// chat timeline. Renders a generic doc icon, the filename, and (optionally)
/// the size formatted via `ByteCountFormatter.file`. Tap to invoke `onTap`
/// (e.g. to share/export the file).
///
/// The user-typed caption deliberately does NOT render here (it did until
/// 2026-08-02): the caption is the message, so the timeline call sites
/// render it themselves with the platform's normal message-text view at
/// full body size — same treatment as `AttachmentImage`.
public struct AttachmentFile: View {
    let filename: String
    let sizeBytes: Int64?
    let isLoading: Bool
    let onTap: (() -> Void)?

    public init(
        filename: String,
        sizeBytes: Int64?,
        isLoading: Bool = false,
        onTap: (() -> Void)? = nil
    ) {
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.isLoading = isLoading
        self.onTap = onTap
    }

    public var body: some View {
        HStack(spacing: 12) {
            // While the blob download runs, the doc icon becomes a
            // spinner — a large attachment takes double-digit seconds to
            // pull through the journal server, and a tap with no visible
            // reaction reads as a dead tap. The frame matches the icon's
            // so the chip doesn't reflow when the state flips.
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "doc")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(filename).font(.callout).lineLimit(1)
                if isLoading {
                    Text("Downloading…")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let sizeBytes {
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
    }
}
