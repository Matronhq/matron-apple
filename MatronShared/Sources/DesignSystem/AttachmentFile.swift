import SwiftUI
import MatronModels

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
/// On the Mac, audio and video the app plays itself (`MediaPlayback`) show
/// a play glyph and a Play button beside Download, so a clip reads as
/// something to watch in place rather than a file to fetch first. A video
/// also gets a 16:9 poster above the row: `poster` once the host has a
/// frame, a dark placeholder until then, at the same size so the row's
/// height never changes when the frame lands.
///
/// The user-typed caption deliberately does NOT render here (it did until
/// 2026-08-02): the caption is the message, so the timeline call sites
/// render it themselves with the platform's normal message-text view at
/// full body size — same treatment as `AttachmentImage`.
public struct AttachmentFile: View {
    let filename: String
    let sizeBytes: Int64?
    let contentType: String?
    let poster: Image?
    let isLoading: Bool
    let isExpired: Bool
    let onTap: (() -> Void)?
    let onDownload: (() -> Void)?
    let dragItem: (() -> NSItemProvider)?

    public init(
        filename: String,
        sizeBytes: Int64?,
        contentType: String? = nil,
        poster: Image? = nil,
        isLoading: Bool = false,
        isExpired: Bool = false,
        onTap: (() -> Void)? = nil,
        onDownload: (() -> Void)? = nil,
        dragItem: (() -> NSItemProvider)? = nil
    ) {
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.contentType = contentType
        self.poster = poster
        self.isLoading = isLoading
        self.isExpired = isExpired
        self.onTap = onTap
        self.onDownload = onDownload
        self.dragItem = dragItem
    }

    /// Download is offered while the file can still be fetched.
    private var download: (() -> Void)? { isExpired ? nil : onDownload }

    /// How the Mac plays this file in place; `nil` elsewhere (iOS opens
    /// every file in QuickLook, with no separate Play).
    private var playback: MediaPlayback? {
        #if os(macOS)
        MediaPlayback.engine(filename: filename, mime: contentType)
        #else
        nil
        #endif
    }

    private var play: (() -> Void)? { isExpired || playback == nil ? nil : onTap }

    private var iconName: String {
        guard let playback else { return "doc" }
        return playback.isVideo ? "play.rectangle.fill" : "play.circle.fill"
    }

    static let posterSize = CGSize(width: 320, height: 180)

    public var body: some View {
        if !isExpired, playback?.isVideo == true {
            VStack(alignment: .leading, spacing: 0) {
                posterView
                chip
            }
            .background(Color.matronCodeBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            chip
                .background(Color.matronCodeBg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// The frame (or its placeholder) with a play glyph. A button, so it
    /// plays like the row's Play; hidden from VoiceOver, which has that one.
    private var posterView: some View {
        Button { onTap?() } label: {
            ZStack {
                Color.black
                if let poster {
                    poster
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .shadow(radius: 4)
            }
            .frame(width: Self.posterSize.width, height: Self.posterSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .padding([.top, .horizontal], 8)
        .accessibilityHidden(true)
    }

    private var chip: some View {
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
                    Image(systemName: iconName)
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: AttachmentOpenPolicy.visibleFilename(filename)).font(.callout).lineLimit(1)
                    // Middle, so a long name keeps its extension.
                    .truncationMode(.middle)
                    .foregroundStyle(isExpired ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fullFilename(AttachmentOpenPolicy.visibleFilename(filename))
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
            if let play {
                Button(action: play) {
                    Label("Play", systemImage: "play.fill")
                }
                .controlSize(.small)
                .disabled(isLoading)
                .help("Play \(filename)")
                .accessibilityLabel("Play \(filename)")
                .accessibilityIdentifier("attachment-play")
            }
            if let download {
                downloadButton(download)
                    .disabled(isLoading)
                    .help("Download \(filename)")
                    .accessibilityLabel("Download \(filename)")
                .accessibilityIdentifier("attachment-download")
            }
        }
        .padding(8)
        // The background (`Color.matronCodeBg`, the cross-platform alias in
        // MarkdownText.swift) and the corner clip are applied in `body`,
        // around the poster too when there is one.
        // No tap affordance on an expired chip — there is nothing to fetch,
        // and a silent no-op tap is the exact bug this chip family exists
        // to avoid (PR #138).
        .onTapGesture { if !isExpired { onTap?() } }
        .contextMenu {
            if let download {
                if let onTap { Button(play == nil ? "Open" : "Play", action: onTap) }
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
