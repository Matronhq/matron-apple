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
    /// The subagent chat the hit is in, shown after the (parent) chat title.
    let subChatTitle: String?
    /// Who wrote the hit ("You", or an agent's box), shown before the
    /// snippet. `nil` renders the snippet alone.
    let senderLabel: String?
    /// Total matches in this chat when the row aggregates a whole
    /// conversation (grouped search results). `nil` or 1 renders no badge.
    let matchCount: Int?
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(hit: SearchHit, chatTitle: String,
                sessionShort: String? = nil, boxLetter: String? = nil,
                boxName: String? = nil, roomBoxNames: [String] = [],
                roomBoxShorts: [String] = [], subChatTitle: String? = nil,
                senderLabel: String? = nil, matchCount: Int? = nil,
                onTap: @escaping () -> Void) {
        self.hit = hit; self.chatTitle = chatTitle
        self.sessionShort = sessionShort; self.boxLetter = boxLetter
        self.boxName = boxName; self.roomBoxNames = roomBoxNames
        self.roomBoxShorts = roomBoxShorts; self.subChatTitle = subChatTitle
        self.senderLabel = senderLabel; self.matchCount = matchCount
        self.onTap = onTap
    }

    /// Same composition and fallbacks as the chat-list rows' titleLine.
    private var titleLine: Text {
        let line = SessionTagText.titleLine(
            title: chatTitle, boxLetter: boxLetter, boxName: boxName,
            sessionShort: sessionShort, roomBoxNames: roomBoxNames,
            roomBoxShorts: roomBoxShorts, colorScheme: colorScheme)
        guard let subChatTitle else { return line }
        return line + Text(" › \(subChatTitle)").foregroundColor(.secondary)
    }

    private var snippetLine: Text {
        let snippet = attributedSnippet(hit.snippet)
        guard let senderLabel else { return snippet }
        return Text("\(senderLabel): ").fontWeight(.medium) + snippet
    }

    public var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    titleLine.font(.callout).bold().lineLimit(2)
                    Spacer()
                    if let matchCount, matchCount > 1 {
                        // How many messages in this chat match — the row
                        // shows only the newest one's snippet.
                        Text("\(matchCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .accessibilityLabel("\(matchCount) matching messages")
                    }
                    // Minute-granularity, like the chat list — the built-in
                    // `.relative` style ticks every second, and the width
                    // churn made the whole results list jump each tick.
                    RelativeMinuteTimeView(hit.timestamp)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                snippetLine
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
