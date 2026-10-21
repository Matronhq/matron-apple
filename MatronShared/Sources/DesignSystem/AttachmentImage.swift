import SwiftUI

/// Shared design-system primitive for an image attachment in the chat
/// timeline. Renders the supplied `Image` (or a placeholder when not yet
/// fetched), caps to a 280×280 box with rounded corners, and surfaces an
/// optional `meta` line (byte size and the like) underneath in small
/// secondary type.
///
/// A user-typed caption deliberately does NOT render here: the caption is
/// the message, so the timeline call sites render it themselves with the
/// platform's normal message-text view (`SelectableMessageText` /
/// `MarkdownText`) at full body size — it used to squeeze through this
/// slot as small gray `.caption2` text.
///
/// `onTap` was previously dropped (QA finding #12) because every Phase-2
/// call site passed `nil` and the fullscreen viewer that would consume it
/// hadn't shipped. Re-added now that the fullscreen viewer lands —
/// default `nil` so existing snapshot-test sites compile unchanged.
///
/// `pixelSize` (the journal's width/height for the attachment, when known)
/// fixes the box BEFORE the bytes arrive: placeholder and image both take
/// the image's aspect-fitted size inside the 280-pt cap, so a thread never
/// shifts as images load. Without it the placeholder is
/// the full 280 × 280 square and the image settles into its own shape when
/// it lands, as before.
///
/// `filename`, when given, leads the line under the image as
/// `name · meta`, truncated in the middle so the extension stays, with the
/// full name on hover (Mac) or long-press (iOS).
public struct AttachmentImage: View {
    let image: Image?
    let placeholder: String
    let filename: String?
    let meta: String?
    let onTap: (() -> Void)?
    let pixelSize: CGSize?

    public static let maxSide: CGFloat = 280

    public init(
        image: Image?,
        placeholder: String = "Image",
        filename: String? = nil,
        meta: String? = nil,
        pixelSize: CGSize? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.image = image
        self.placeholder = placeholder
        self.filename = filename?.isEmpty == true ? nil : filename
        self.meta = meta
        self.pixelSize = pixelSize
        self.onTap = onTap
    }

    /// The on-screen box for an image of `pixelSize`: its aspect ratio,
    /// scaled to fit `maxSide × maxSide` — exactly where `scaledToFit()`
    /// inside the 280 × 280 cap puts the loaded image, so swapping the
    /// placeholder for the image changes nothing around it. A degenerate
    /// sliver (a 1 × 4000 strip) still gets at least a tappable 24 pt.
    public static func displaySize(for pixelSize: CGSize?, maxSide: CGFloat = maxSide) -> CGSize? {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let scale = min(maxSide / pixelSize.width, maxSide / pixelSize.height)
        return CGSize(width: max(24, (pixelSize.width * scale).rounded()),
                      height: max(24, (pixelSize.height * scale).rounded()))
    }

    /// The width:height ratio the box keeps as it narrows: the image's own,
    /// unrounded (the loaded image is drawn by `scaledToFit()` at exactly
    /// that ratio), unless the 24-pt floor widened a sliver — then the
    /// floored box's ratio, so a 1 × 4000 strip stays inside 280 pt tall and
    /// a 4000 × 1 one stays 24 pt tall (the image letterboxes inside; the
    /// box is the same before and after it loads).
    public static func boxRatio(for pixelSize: CGSize?, maxSide: CGFloat = maxSide) -> CGFloat? {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0,
              let box = displaySize(for: pixelSize, maxSide: maxSide) else { return nil }
        let scale = min(maxSide / pixelSize.width, maxSide / pixelSize.height)
        let floored = pixelSize.width * scale < 24 || pixelSize.height * scale < 24
        return floored ? box.width / box.height : pixelSize.width / pixelSize.height
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let image {
                    image.resizable().scaledToFit()
                } else {
                    ZStack {
                        Rectangle().fill(.secondary.opacity(0.2))
                        VStack(spacing: 4) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                            Text(placeholder)
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .modifier(BoxFrame(ratio: Self.boxRatio(for: pixelSize), size: Self.displaySize(for: pixelSize)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // Tap forwards to `onTap` when wired. The placeholder
            // state still receives the gesture so the user can open
            // the (eventually-resolved) image even before the bytes
            // have rendered into the bubble — bypasses the dead-tap
            // window otherwise visible while the fetch is in flight.
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }

            if filename != nil || meta != nil {
                AttachmentNameLine(filename: filename, meta: meta)
                    // No wider than the image above it: a long name
                    // truncates rather than widening the card.
                    .frame(maxWidth: Self.displaySize(for: pixelSize)?.width ?? Self.maxSide, alignment: .leading)
            }
        }
    }
}

/// `name · meta` in small secondary type on one line. The name gives way
/// first, truncated in the middle so its extension stays visible; the meta
/// (a size) never truncates. The full name shows on hover (Mac) and on
/// long-press (iOS). Shared by `AttachmentImage` and `AttachmentFile`'s
/// name line.
struct AttachmentNameLine: View {
    let filename: String?
    let meta: String?

    var body: some View {
        HStack(spacing: 0) {
            if let filename {
                Text(verbatim: filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if meta != nil {
                    Text(verbatim: " · ").fixedSize()
                }
            }
            if let meta {
                Text(verbatim: meta).lineLimit(1).fixedSize()
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fullFilename(filename)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The full filename on hover (Mac tooltip) or long-press (iOS menu),
    /// for a name the layout may have truncated.
    @ViewBuilder
    func fullFilename(_ filename: String?) -> some View {
        if let filename {
            #if os(iOS)
            contextMenu { Text(verbatim: filename) }
            #else
            help(Text(verbatim: filename))
            #endif
        } else {
            self
        }
    }
}

/// The known box when there is one, else the old 280-pt cap. The known box
/// keeps its aspect ratio and is capped at its own size, not pinned to it:
/// on a card narrower than 280 pt (a small phone) it shrinks to the card,
/// and its height still follows from the width alone — the placeholder and
/// the loaded image take the same box either way.
///
/// `ratio` is `AttachmentImage.boxRatio` — see there for why it is not
/// taken from the rounded `size`.
private struct BoxFrame: ViewModifier {
    let ratio: CGFloat?
    let size: CGSize?
    func body(content: Content) -> some View {
        if let ratio, let size {
            content
                .aspectRatio(ratio, contentMode: .fit)
                .frame(maxWidth: size.width)
        } else {
            content.frame(maxWidth: AttachmentImage.maxSide, maxHeight: AttachmentImage.maxSide)
        }
    }
}
