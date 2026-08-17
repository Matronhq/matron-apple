import Foundation

/// User-chosen tag characters for agent boxes, overriding the letters
/// `SessionTag.boxLetters` derives from the box names. Stored locally in
/// `UserDefaults` (per app install, not synced through the journal — the
/// tag is a reading aid, and one person may well want different characters
/// on different devices). Keyed by the box's device id, the same id the
/// summaries pipeline already resolves names and colors by.
public enum BoxLetterOverrides {

    static let defaultsKey = "boxLetterOverrides"

    /// Posted after every mutation so the summaries stream can re-derive
    /// letters — a settings edit writes no journal record, so nothing else
    /// would wake the chat list.
    public static let didChange = Notification.Name("matron.boxLetterOverridesDidChange")

    /// Every stored override, sanitized. Unparseable keys are skipped
    /// rather than crashing on a hand-edited plist.
    public static func all(from defaults: UserDefaults = .standard) -> [Int64: String] {
        guard let raw = defaults.dictionary(forKey: defaultsKey) as? [String: String] else { return [:] }
        var overrides: [Int64: String] = [:]
        for (key, value) in raw {
            guard let id = Int64(key), let letter = sanitize(value) else { continue }
            overrides[id] = letter
        }
        return overrides
    }

    public static func letter(for id: Int64, from defaults: UserDefaults = .standard) -> String? {
        all(from: defaults)[id]
    }

    /// Stores one override, or removes it when `letter` is nil/blank so an
    /// emptied field means "back to automatic".
    public static func set(_ letter: String?, for id: Int64, in defaults: UserDefaults = .standard) {
        var raw = (defaults.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        if let sanitized = letter.flatMap(sanitize) {
            raw[String(id)] = sanitized
        } else {
            raw.removeValue(forKey: String(id))
        }
        if raw.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(raw, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The tag is one character by contract, but that character is the
    /// user's pick — a lowercase letter, a digit, an emoji all render fine.
    /// Trim, then keep the first grapheme; nothing left means no override.
    static func sanitize(_ letter: String) -> String? {
        letter.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init)
    }
}
