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
/// slot as small gray `.caption2` text (Dan, 2026-08-02).
///
/// `onTap` was previously dropped (QA finding #12) because every Phase-2
/// call site passed `nil` and the fullscreen viewer that would consume it
/// hadn't shipped. Re-added now that the fullscreen viewer lands —
/// default `nil` so existing snapshot-test sites compile unchanged.
///
/// `pixelSize` (the journal's width/height for the attachment, when known)
/// fixes the box BEFORE the bytes arrive: placeholder and image both take
/// the image's aspect-fitted size inside the 280-pt cap, so a thread never
/// shifts as images load (Dan, 2026-10-01). Without it the placeholder is
/// the full 280 × 280 square and the image settles into its own shape when
/// it lands, as before.
public struct AttachmentImage: View {
    let image: Image?
    let placeholder: String
    let meta: String?
    let onTap: (() -> Void)?
    let pixelSize: CGSize?

    public static let maxSide: CGFloat = 280

    public init(
        image: Image?,
        placeholder: String = "Image",
        meta: String? = nil,
        pixelSize: CGSize? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.image = image
        self.placeholder = placeholder
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
            .modifier(BoxFrame(size: Self.displaySize(for: pixelSize)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // Tap forwards to `onTap` when wired. The placeholder
            // state still receives the gesture so the user can open
            // the (eventually-resolved) image even before the bytes
            // have rendered into the bubble — bypasses the dead-tap
            // window otherwise visible while the fetch is in flight.
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }

            if let meta {
                Text(meta).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// The known box when there is one, else the old 280-pt cap.
private struct BoxFrame: ViewModifier {
    let size: CGSize?
    func body(content: Content) -> some View {
        if let size {
            content.frame(width: size.width, height: size.height)
        } else {
            content.frame(maxWidth: AttachmentImage.maxSide, maxHeight: AttachmentImage.maxSide)
        }
    }
}
