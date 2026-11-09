import SwiftUI
import MatronModels

/// A story's one picture or video, filling the card's width at a fixed
/// shape. An image the host is still loading is a quiet placeholder of the
/// same size; a video (no poster frames yet) is a dark panel with ▶ and its
/// name. Videos play from the project's page, through its file opening.
public struct TimelineMediaView: View {
    /// Width over height: wide, so two cards side by side keep their words in view.
    public static let aspectRatio: CGFloat = 2.4

    let media: TimelineMedia
    let image: Image?
    let aspectRatio: CGFloat

    /// `aspectRatio` defaults to a story card's; a project's gallery tiles
    /// are squarer.
    public init(media: TimelineMedia, image: Image?, aspectRatio: CGFloat = TimelineMediaView.aspectRatio) {
        self.media = media; self.image = image; self.aspectRatio = aspectRatio
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
            image.resizable().scaledToFill()
        } else {
            Color.primary.opacity(0.05)
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
