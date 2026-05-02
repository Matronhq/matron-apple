import SwiftUI

/// Shared design-system primitive for an image attachment in the chat
/// timeline. Renders the supplied `Image` (or a placeholder when not yet
/// fetched), caps to a 280×280 box with rounded corners, and surfaces an
/// optional caption underneath. Tap the image to invoke the `onTap`
/// callback (e.g. to present a fullscreen viewer).
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
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 280, maxHeight: 280)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { onTap?() }

            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
