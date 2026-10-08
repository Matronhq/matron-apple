import Foundation
import MatronModels

/// The box (machine) filter on the conversation chooser — Coordinator,
/// Settings → Pinned chats → Add and Move pin… — beside its search. The
/// boxes are the names the rows already carry (`ChatSummary.boxName`,
/// gated upstream to users with two or more boxes), so a single-box user
/// never sees the filter. Counted and ordered like the project page's
/// "Sessions on it now" filter (`ProjectPageSections`), whose chips the
/// Mac chooser reuses.
public enum ChatBoxFilter {
    /// The boxes `chat` runs on: every box of a multi-agent room, else its
    /// own box, else none.
    public static func boxes(of chat: ChatSummary) -> [String] {
        var seen = Set<String>()
        return (chat.roomBoxNames + [chat.boxName].compactMap { $0 }).filter { seen.insert($0).inserted }
    }

    /// The filter's boxes with how many of `chats` each one holds, most
    /// first, then by name. A room counts once on each of its boxes.
    public static func counts(_ chats: [ChatSummary]) -> [ProjectBoxCount] {
        var counts: [String: Int] = [:]
        for chat in chats { for box in boxes(of: chat) { counts[box, default: 0] += 1 } }
        return counts.map { ProjectBoxCount(box: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.box < $1.box }
    }

    /// Whether the filter is worth showing: two or more boxes to tell apart.
    public static func shows(_ counts: [ProjectBoxCount]) -> Bool {
        ProjectPageSections.showsBoxFilter(counts)
    }

    /// The box in force: `selected` while it still holds a chat, else none.
    public static func activeBox(_ selected: String?, in counts: [ProjectBoxCount]) -> String? {
        ProjectPageSections.activeBox(selected, in: counts)
    }

    /// `chats` whose title contains `query` (case-insensitive, trimmed; an
    /// empty query keeps all) and that run on `box` (nil keeps all).
    public static func filtered(_ chats: [ChatSummary], query: String, box: String? = nil) -> [ChatSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return chats.filter { chat in
            (q.isEmpty || chat.title.localizedCaseInsensitiveContains(q))
                && (box.map { boxes(of: chat).contains($0) } ?? true)
        }
    }
}
