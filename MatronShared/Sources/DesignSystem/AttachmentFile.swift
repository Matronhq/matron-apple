import SwiftUI

/// Shared design-system primitive for a non-image file attachment in the
/// chat timeline. Renders a generic doc icon, the filename, and (optionally)
/// the size formatted via `ByteCountFormatter.file`. Tap to invoke `onTap`
/// (e.g. to share/export the file).
///
/// A host that passes `onDownload` gets a Download button at the chip's
/// trailing edge and a context menu (Open, Download…), so a file can be
/// kept rather than only opened. `dragItem` makes the chip draggable, e.g.
/// out to Finder on the Mac.
///
/// The user-typed caption deliberately does NOT render here (it did until
/// 2026-08-02): the caption is the message, so the timeline call sites
/// render it themselves with the platform's normal message-text view at
/// full body size — same treatment as `AttachmentImage`.
public struct AttachmentFile: View {
    let filename: String
    let sizeBytes: Int64?
    let isLoading: Bool
    let isExpired: Bool
    let onTap: (() -> Void)?
    let onDownload: (() -> Void)?
    let dragItem: (() -> NSItemProvider)?

    public init(
        filename: String,
        sizeBytes: Int64?,
        isLoading: Bool = false,
        isExpired: Bool = false,
        onTap: (() -> Void)? = nil,
        onDownload: (() -> Void)? = nil,
        dragItem: (() -> NSItemProvider)? = nil
    ) {
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.isLoading = isLoading
        self.isExpired = isExpired
        self.onTap = onTap
        self.onDownload = onDownload
        self.dragItem = dragItem
    }

    /// Download is offered while the file can still be fetched.
    private var download: (() -> Void)? { isExpired ? nil : onDownload }

    public var body: some View {
        HStack(spacing: 12) {
            // While the blob download runs, the doc icon becomes a
            // spinner — a large attachment takes double-digit seconds to
            // pull through the journal server, and a tap with no visible
            // reaction reads as a dead tap. The frame matches the icon's
            // so the chip doesn't reflow when the state flips.
            Group {
                if isExpired {
                    // The blob was reaped server-side (journal media
                    // reaper) — permanently gone, nothing to download.
                    Image(systemName: "doc.badge.clock")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else if isLoading {
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
                Text(verbatim: filename).font(.callout).lineLimit(1)
                    // Middle, so a long name keeps its extension.
                    .truncationMode(.middle)
                    .foregroundStyle(isExpired ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fullFilename(filename)
                if isExpired {
                    Text("Expired")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if isLoading {
                    Text("Downloading…")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let download {
                downloadButton(download)
                    .disabled(isLoading)
                    .help("Download \(filename)")
                    .accessibilityLabel("Download \(filename)")
                .accessibilityIdentifier("attachment-download")
            }
        }
        .padding(8)
        // `Color.matronCodeBg` is the cross-platform alias defined in
        // MarkdownText.swift — `Color(.systemGray6)` is iOS-only and would
        // break the Mac build.
        .background(Color.matronCodeBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // No tap affordance on an expired chip — there is nothing to fetch,
        // and a silent no-op tap is the exact bug this chip family exists
        // to avoid (PR #138).
        .onTapGesture { if !isExpired { onTap?() } }
        .contextMenu {
            if let download {
                if let onTap { Button("Open", action: onTap) }
                Button(Self.downloadMenuTitle, action: download)
            }
        }
        .modifier(DragOut(item: isExpired ? nil : dragItem))
    }

    /// A labelled button on the Mac, where the chip has room and a lone
    /// glyph at its far edge is easy to miss; the glyph alone on iOS.
    @ViewBuilder
    private func downloadButton(_ download: @escaping () -> Void) -> some View {
        #if os(macOS)
        Button(action: download) {
            Label("Download", systemImage: "arrow.down.circle")
        }
        .controlSize(.small)
        #else
        Button(action: download) {
            Image(systemName: "square.and.arrow.down")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #endif
    }

    /// The Mac asks where to save (a Save panel); iOS hands the file to
    /// the share sheet, whose Save to Files is the download.
    static var downloadMenuTitle: String {
        #if os(macOS)
        "Download…"
        #else
        "Save or Share…"
        #endif
    }
}

/// `onDrag` only when there is something to drag, so a chip without one
/// keeps no drag gesture competing with its tap.
private struct DragOut: ViewModifier {
    let item: (() -> NSItemProvider)?

    func body(content: Content) -> some View {
        if let item {
            content.onDrag(item)
        } else {
            content
        }
    }
}
