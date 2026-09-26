import UIKit
import MatronDesignSystem

/// Every font and markdown metric one text row is rendered and measured
/// with, for one Dynamic Type size. Half of every measurement cache key —
/// a category change is a guaranteed miss (spec: cache key includes the
/// Dynamic Type size). `@unchecked Sendable`: a plain value; the category
/// is an immutable string wrapper.
struct TimelineTextStyle: Hashable, @unchecked Sendable {
    let sizeCategory: UIContentSizeCategory

    init(sizeCategory: UIContentSizeCategory) {
        self.sizeCategory = sizeCategory
    }

    private var traits: UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: sizeCategory)
    }

    /// The system body (17pt at `.large`), scaled — what MarkdownUI renders
    /// `Theme.matronMessage` at on the SwiftUI path.
    var bodySize: CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits)
    }

    var markdown: MarkdownAttributed.Style { .phoneChat(bodySize: bodySize) }

    /// Vertical gap between a message's prose / code / table segments.
    var segmentSpacing: CGFloat { markdown.paragraphSpacing }

    /// `MessageBubble`'s `.caption2` time.
    var timestampFont: UIFont { .preferredFont(forTextStyle: .caption2, compatibleWith: traits) }

    /// `CodeBlock`'s `.system(.callout, design: .monospaced)`.
    var codeFont: UIFont {
        .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .callout, compatibleWith: traits).pointSize,
                              weight: .regular)
    }

    /// `CodeBlock`'s language label (`.caption2`).
    var codeHeaderFont: UIFont { .preferredFont(forTextStyle: .caption2, compatibleWith: traits) }

    /// `CodeBlock`'s copy icon (`.caption`).
    var copyIconFont: UIFont { .preferredFont(forTextStyle: .caption1, compatibleWith: traits) }
}
