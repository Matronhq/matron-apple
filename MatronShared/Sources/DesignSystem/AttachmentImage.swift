import SwiftUI

/// Shared design-system primitive for an image attachment in the chat
/// timeline. Renders the supplied `Image` (or a placeholder when not yet
/// fetched), caps to a 280×280 box with rounded corners, and surfaces an
/// optional caption underneath.
///
/// QA finding #12 dropped the `onTap` parameter — every Phase-2 call site
/// (`TimelineItemView`, `MacTimelineItemView`) passed `nil`, and the
/// fullscreen viewer that would consume the callback hasn't shipped. Re-add
/// when that lands so the parameter doesn't sit unused on the public API.
public struct AttachmentImage: View {
    let image: Image?
    let placeholder: String
    let caption: String?

    public init(
        image: Image?,
        placeholder: String = "Image",
        caption: String? = nil
    ) {
        self.image = image
        self.placeholder = placeholder
        self.caption = caption
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

            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
