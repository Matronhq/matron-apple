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
    /// The colored `A:bc` / `A↔B:bc` tag halves, matching the chat-list
    /// rows (resolved by `SearchViewModel.hitTitle` so iOS and Mac agree).
    /// All defaulted — a hit from an unknown room renders untagged.
    let sessionShort: String?
    let boxLetter: String?
    let boxName: String?
    let roomBoxNames: [String]
    let roomBoxShorts: [String]
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(hit: SearchHit, chatTitle: String,
                sessionShort: String? = nil, boxLetter: String? = nil,
                boxName: String? = nil, roomBoxNames: [String] = [],
                roomBoxShorts: [String] = [], onTap: @escaping () -> Void) {
        self.hit = hit; self.chatTitle = chatTitle
        self.sessionShort = sessionShort; self.boxLetter = boxLetter
        self.boxName = boxName; self.roomBoxNames = roomBoxNames
        self.roomBoxShorts = roomBoxShorts; self.onTap = onTap
    }

    /// Same composition and fallbacks as the chat-list rows' titleLine.
    private var titleLine: Text {
        let tag = SessionTagText.room(
            letters: roomBoxShorts, names: roomBoxNames,
            sessionShort: sessionShort, colorScheme: colorScheme)
            ?? SessionTagText.run(
                boxLetter: boxLetter, boxName: boxName,
                sessionShort: sessionShort, colorScheme: colorScheme)
        guard let tag else { return Text(chatTitle) }
        return tag + Text(" ") + Text(chatTitle)
    }

    public var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    titleLine.font(.callout).bold()
                    Spacer()
                    // Minute-granularity, like the chat list — the built-in
                    // `.relative` style ticks every second, and the width
                    // churn made the whole results list jump each tick.
                    RelativeMinuteTimeView(hit.timestamp)
                        .font(.caption2).foregroundStyle(.secondary)
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
