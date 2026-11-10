import SwiftUI
import MatronModels

/// How a picture sits in the media area: cropped to fill it, or shown
/// whole when it is too wide or too tall for a crop to say anything.
public enum TimelineMediaFit: Equatable, Sendable {
    case fill, whole

    /// Width over height above which a picture is shown whole.
    static let widest: CGFloat = 3.6
    /// Width over height below which a picture is shown whole.
    static let tallest: CGFloat = 1.33

    /// `.whole` for a picture wider than 3.6 : 1 or taller than 1.33 : 1;
    /// `.fill` otherwise, and when the size isn't known.
    public static func of(pixelSize: CGSize?) -> TimelineMediaFit {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else { return .fill }
        let ratio = pixelSize.width / pixelSize.height
        return ratio > widest || ratio < tallest ? .whole : .fill
    }
}

/// A story's one picture or video, filling the card's width at a fixed
/// shape. A very wide or very tall picture is shown whole, on a blurred,
/// darkened copy of itself. An image the host is still loading is a quiet
/// placeholder of the same size; a video (no poster frames yet) is a dark
/// panel with ▶ and its name. Videos play from the project's page, through
/// its file opening.
public struct TimelineMediaView: View {
    /// Width over height: wide, so two cards side by side keep their words in view.
    public static let aspectRatio: CGFloat = 2.4
    /// How far the copy behind a whole picture is blurred.
    static let backdropBlur: CGFloat = 24
    /// The black laid over that copy.
    static let backdropWash = 0.25

    let media: TimelineMedia
    let image: Image?
    let pixelSize: CGSize?
    let aspectRatio: CGFloat

    /// `pixelSize` is the picture's own size, when the host knows it: a
    /// picture of unknown size fills. `aspectRatio` defaults to a story
    /// card's; a project's gallery tiles are squarer.
    public init(media: TimelineMedia, image: Image?, pixelSize: CGSize? = nil,
                aspectRatio: CGFloat = TimelineMediaView.aspectRatio) {
        self.media = media; self.image = image; self.pixelSize = pixelSize; self.aspectRatio = aspectRatio
    }

    public var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay { content }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(media.isVideo ? "Video \(media.name)" : "Picture \(media.name)")
    }

    @ViewBuilder private var content: some View {
        if media.isVideo {
            video
        } else if let image {
            switch TimelineMediaFit.of(pixelSize: pixelSize) {
            case .fill: image.resizable().scaledToFill()
            case .whole: whole(image)
            }
        } else {
            Color.primary.opacity(0.05)
        }
    }

    /// All of the picture, centred over itself filling the area, blurred
    /// and darkened: the bars either side are the picture's own colours.
    private func whole(_ image: Image) -> some View {
        image.resizable().scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { backdrop(image) }
    }

    /// The picture filling the area, blurred, under a black wash. Drawn in
    /// one pass on a canvas rather than with the `blur` modifier, whose
    /// layer filter a view captured off screen (a snapshot) doesn't draw.
    private func backdrop(_ image: Image) -> some View {
        Canvas { context, size in
            let picture = context.resolve(image)
            guard picture.size.width > 0, picture.size.height > 0 else { return }
            // Past every edge by twice the radius, so the blur draws on
            // picture all the way out instead of fading to clear.
            let reach = Self.backdropBlur * 2
            let scale = max((size.width + reach * 2) / picture.size.width, (size.height + reach * 2) / picture.size.height)
            let drawn = CGSize(width: picture.size.width * scale, height: picture.size.height * scale)
            var blurred = context
            blurred.addFilter(.blur(radius: Self.backdropBlur))
            blurred.draw(picture, in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                             width: drawn.width, height: drawn.height))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(Self.backdropWash)))
        }
    }

    private var video: some View {
        ZStack(alignment: .bottomLeading) {
            Color(white: 0.07)
            Image(systemName: "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.white)
                .offset(x: 2)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.18), in: Circle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(media.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(1)
                .padding(12)
        }
        .environment(\.colorScheme, .dark)
    }
}
