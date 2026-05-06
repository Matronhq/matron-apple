import SwiftUI

/// Shared design-system primitive for an image attachment in the chat
/// timeline. Renders the supplied `Image` (or a placeholder when not yet
/// fetched), caps to a 280×280 box with rounded corners, and surfaces an
/// optional caption underneath.
///
/// `onTap` was previously dropped (QA finding #12) because every Phase-2
/// call site passed `nil` and the fullscreen viewer that would consume it
/// hadn't shipped. Re-added now that the fullscreen viewer lands —
/// default `nil` so existing snapshot-test sites compile unchanged.
public struct AttachmentImage: View {
    let image: Image?
    let placeholder: String
    let caption: String?
    let onTap: (() -> Void)?

    public init(
        image: Image?,
        placeholder: String = "Image",
        caption: String? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.image = image
        self.placeholder = placeholder
        self.caption = caption
        self.onTap = onTap
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
            .frame(maxWidth: 280, maxHeight: 280)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // Tap forwards to `onTap` when wired. The placeholder
            // state still receives the gesture so the user can open
            // the (eventually-resolved) image even before the bytes
            // have rendered into the bubble — bypasses the dead-tap
            // window otherwise visible while the fetch is in flight.
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }

            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
