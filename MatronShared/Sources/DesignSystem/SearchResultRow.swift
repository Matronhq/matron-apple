import SwiftUI
import MatronSearch

/// Shared rendering primitive for a single message search hit — used by both the
/// iOS `SearchView` and the Mac `MacSearchResultsView`. Renders the chat title +
/// relative timestamp and the FTS snippet with `<mark>…</mark>` spans bolded and
/// tinted. The `<mark>` parsing is platform-agnostic `Text` concatenation, so no
/// per-platform text rendering is needed.
public struct SearchResultRow: View {
    let hit: SearchHit
    let chatTitle: String
    let onTap: () -> Void

    public init(hit: SearchHit, chatTitle: String, onTap: @escaping () -> Void) {
        self.hit = hit; self.chatTitle = chatTitle; self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(chatTitle).font(.callout).bold()
                    Spacer()
                    Text(hit.timestamp, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
                attributedSnippet(hit.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .buttonStyle(.plain)
    }

    private func attributedSnippet(_ raw: String) -> Text {
        // Crude but effective: split on <mark>...</mark> and render highlighted parts bold.
        var result = Text("")
        var remaining = raw[...]
        while let openRange = remaining.range(of: "<mark>") {
            result = result + Text(remaining[..<openRange.lowerBound])
            remaining = remaining[openRange.upperBound...]
            if let closeRange = remaining.range(of: "</mark>") {
                result = result + Text(remaining[..<closeRange.lowerBound]).bold().foregroundColor(.accentColor)
                remaining = remaining[closeRange.upperBound...]
            } else {
                break
            }
        }
        result = result + Text(remaining)
        return result
    }
}
