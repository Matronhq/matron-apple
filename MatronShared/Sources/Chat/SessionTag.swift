import Foundation

/// The compact per-conversation tag rendered ahead of chat titles:
/// `A:bc` — one colored letter for the box, two characters of the agent's
/// session id. Replaces the trailing `BoxChip` in list rows, which put the
/// machine at the END of the eye scan and spent a full capsule on it
/// (Dan, 2026-08-16).
///
/// The two halves travel differently:
/// - The session short arrives INSIDE the title text as a `[bc] ` prefix —
///   the bridge bakes it into every earned title (matron-bridge#224).
///   `splitTitle` peels it off so views can restyle it and show the clean
///   title; clients that never port just show the raw prefix, which still
///   reads.
/// - The box letter is derived client-side from the box-name registry
///   (`boxLetters`), so it can be colored with the box's `BoxChip` tint and
///   stays consistent with the chips everywhere else.
public enum SessionTag {

    /// The bridge's multi-agent room marker, leading every agent-chat room
    /// title (`🔗 [ab] mac ↔ dev-z`, matron-bridge#225).
    static let roomMarker = "🔗 "

    /// Peels the bridge's `[bc] ` session-short prefix off a published
    /// title. Returns the short (without brackets) and the remaining title.
    /// Titles without the prefix come back unchanged with a nil short —
    /// including bracketed text that isn't a short (wrong length, spaces,
    /// no trailing separator), which stays part of the visible title.
    /// Agent-chat room titles carry the short BEHIND the 🔗 room marker;
    /// the short is peeled from there and the marker stays with the title,
    /// so a room keeps its 🔗 even for users who get no styled tag.
    public static func splitTitle(_ raw: String) -> (sessionShort: String?, title: String) {
        if raw.hasPrefix(roomMarker) {
            let (short, rest) = splitTitle(String(raw.dropFirst(roomMarker.count)))
            guard short != nil else { return (nil, raw) }
            return (short, roomMarker + rest)
        }
        guard raw.hasPrefix("["),
              let close = raw.firstIndex(of: "]") else { return (nil, raw) }
        let short = raw[raw.index(after: raw.startIndex)..<close]
        guard short.count == 2, short.allSatisfy({ $0.isLetter || $0.isNumber }) else { return (nil, raw) }
        let rest = raw[raw.index(after: close)...]
        guard rest.first == " " else { return (nil, raw) }
        let title = String(rest.dropFirst())
        guard !title.isEmpty else { return (nil, raw) }
        return (String(short), title)
    }

    /// The title to render NEXT TO a colored `A↔B` room tag: the tag
    /// already says "multi-agent room", so the bridge's 🔗 marker is
    /// dropped. Rows that show no room tag (single-box users, unresolved
    /// participants) keep the marker.
    public static func titleBesideRoomTag(_ title: String) -> String {
        title.hasPrefix(roomMarker) ? String(title.dropFirst(roomMarker.count)) : title
    }

    /// One display letter per box, derived from the box names: strip the
    /// prefix common to ALL names, then take the first letter/digit of what
    /// remains, uppercased. `dev-y` / `dev-z` therefore come out as `Y` and
    /// `Z`, not both `D` (the colleague-with-two-DEV-boxes problem), while
    /// unrelated names keep their initials (`mac-mini` / `dev-3` → `M` /
    /// `D`). A name that IS the common prefix (`dev` next to `dev-2`) falls
    /// back to its own initial. Deterministic — same names, same letters,
    /// every platform — and renaming a box (already supported) is how you
    /// change its letter. Collisions are tolerated: the letter is an aid,
    /// the color and session short still disambiguate.
    public static func boxLetters(for names: [Int64: String]) -> [Int64: String] {
        guard !names.isEmpty else { return [:] }
        let values = Array(names.values)
        let prefix = values.count >= 2 ? commonPrefix(of: values) : ""
        var letters: [Int64: String] = [:]
        for (id, name) in names {
            let remainder = String(name.dropFirst(prefix.count))
            letters[id] = firstAlphanumeric(remainder) ?? firstAlphanumeric(name) ?? "?"
        }
        return letters
    }

    private static func firstAlphanumeric(_ s: String) -> String? {
        s.first(where: { $0.isLetter || $0.isNumber }).map {
            // Uppercasing can EXPAND some letters (ß → SS); the tag is one
            // character by contract, so keep the original when it does.
            let uppercased = String($0).uppercased()
            return uppercased.count == 1 ? uppercased : String($0)
        }
    }

    /// Case-insensitive longest common prefix, returned at the length it
    /// holds for every name. Case-insensitive so `Dev-y` / `dev-z` still
    /// strip to `Y` / `Z`.
    private static func commonPrefix(of names: [String]) -> String {
        guard var shortest = names.min(by: { $0.count < $1.count }) else { return "" }
        while !shortest.isEmpty {
            if names.allSatisfy({ $0.lowercased().hasPrefix(shortest.lowercased()) }) { return shortest }
            shortest = String(shortest.dropLast())
        }
        return ""
    }
}
