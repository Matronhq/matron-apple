import SwiftUI
import MarkdownUI

/// Images written into markdown text (`![alt](https://…)`) are never
/// fetched when the text is shown. Message, item and mission text often
/// comes from other people and agents, and loading an image from any URL
/// it names would reach out to that server the moment the text is on
/// screen. `MarkdownText` installs these providers by default, so every
/// MarkdownUI render in the app draws a placeholder instead.
///
/// Attachments placed in an item body (`![caption](attachment:ref)`) are
/// not affected: `ItemDetailView` splits them out before the text reaches
/// the renderer and draws them through the authenticated media path.
enum MarkdownImagePolicy {
    /// The block image provider `MarkdownText` installs.
    static let blockImageProvider = PlaceholderImageProvider()
    /// The inline image provider `MarkdownText` installs.
    static let inlineImageProvider = PlaceholderInlineImageProvider()

    /// A tappable placeholder only for web links; tapping goes through the
    /// view's `openURL` (the in-app link policy), never a fetch.
    static func opensOnTap(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The placeholder's text: "Image", plus where it points for a web
    /// link ("Image · example.com/cat.png").
    static func caption(for url: URL?) -> String {
        guard let url, opensOnTap(url), let host = url.host, !host.isEmpty else { return "Image" }
        let name = url.lastPathComponent
        let place = (name.isEmpty || name == "/") ? host : host + "/" + name
        return "Image · " + place
    }
}

/// A block image (an image on its own line) drawn as a small "Image" chip
/// with where it points, opening the link in the browser when tapped.
struct PlaceholderImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        MarkdownImagePlaceholder(url: url)
    }
}

/// An image inside a line of text drawn as a photo glyph. Nothing is loaded.
struct PlaceholderInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        Image(systemName: "photo")
    }
}

struct MarkdownImagePlaceholder: View {
    let url: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url, MarkdownImagePolicy.opensOnTap(url) {
            Button {
                openURL(url)
            } label: {
                chip
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the image in the browser")
        } else {
            chip
        }
    }

    private var chip: some View {
        Label {
            Text(MarkdownImagePolicy.caption(for: url))
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: "photo")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}
