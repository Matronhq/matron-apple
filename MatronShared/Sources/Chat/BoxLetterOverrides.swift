import Foundation

/// LEGACY store for user-chosen box tag characters, kept only so existing
/// installs can migrate. The journal owns the tag now (`devices.tag_char`,
/// synced to every client via snapshot + `device_meta`); this local
/// `UserDefaults` dictionary was the pre-sync home, which is exactly why a
/// letter chosen on one device never showed on the others.
///
/// `BoxLetterMigration` pushes these up to the journal once and deletes
/// them. Nothing writes here anymore.
///
/// The legacy dictionary is install-wide and keyed by agent device id
/// alone — it predates any notion of which account chose the letters, and
/// device ids repeat across journals. So the relics belong to exactly one
/// account: the first one signed in once this code runs (`claim`), which
/// on any real install is the account that wrote them (the session
/// survives the upgrade). Every other account on the install ignores them.
public enum BoxLetterOverrides {

    static let defaultsKey = "boxLetterOverrides"
    /// User id of the account that owns the legacy entries. Written by
    /// `claim` on first use, removed with the last entry.
    static let ownerKey = "boxLetterOverridesOwner"

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

    /// Drops one migrated entry; removes the whole key with the last one,
    /// so a fully migrated install carries no legacy residue.
    public static func remove(id: Int64, from defaults: UserDefaults = .standard) {
        var raw = (defaults.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        raw.removeValue(forKey: String(id))
        if raw.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
            defaults.removeObject(forKey: ownerKey)
        } else {
            defaults.set(raw, forKey: defaultsKey)
        }
    }

    /// Whether `userID` may migrate the legacy entries. The first account
    /// to ask while entries exist becomes their owner; afterwards only that
    /// account gets `true`. Agent device ids collide across journals, so
    /// without this a second account signing in on the same install would
    /// have account A's letter for id 1 seeded and pushed onto ITS box 1 —
    /// or A's relics dropped as "revoked" because B's roster lacks the id.
    /// The owner stamp disappears with the last entry (`remove`), so a
    /// fully migrated install carries no residue.
    ///
    /// Accepted edge: an install that was signed OUT across the upgrade
    /// has no owner on record, so whoever signs in first claims the relics.
    public static func claim(userID: String, in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.dictionary(forKey: defaultsKey) != nil else { return false }
        if let owner = defaults.string(forKey: ownerKey) { return owner == userID }
        defaults.set(userID, forKey: ownerKey)
        return true
    }

    /// The tag is one character by contract, but that character is the
    /// user's pick — a lowercase letter, a digit, an emoji all render fine.
    /// Trim, then keep the first grapheme; nothing left means no override.
    public static func sanitize(_ letter: String) -> String? {
        letter.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init)
    }
}

/// One-time push of legacy local letter overrides up to the journal, run at
/// app start once a session exists. Idempotent and interruption-safe: an
/// entry leaves `UserDefaults` only after its push succeeds, so a network
/// failure just retries on the next launch, and an empty legacy dictionary
/// makes the whole thing a no-op read.
public enum BoxLetterMigration {

    /// `serverTags` is the journal's current view (from `GET /devices`) —
    /// a box that already has a journal-held tag wins over the local relic,
    /// which is dropped without pushing. Overrides for ids the server no
    /// longer knows (revoked boxes) are dropped the same way.
    ///
    /// Known one-shot edges, accepted rather than engineered around:
    /// - A server nil can also mean "explicitly cleared on another device
    ///   after the sync feature shipped" — a pre-migration install that
    ///   only launches later will push its old letter back up once. The
    ///   user re-clears and it never recurs (the relic is gone).
    /// - The migrating launch can have its mirror seed overwritten by a
    ///   tag-aware snapshot issued before the push (`replaceAgents` takes
    ///   an explicit server nil as authoritative; only a PRE-tag snapshot
    ///   preserves — see `tagCharKnown`). The push's `device_meta` echo or
    ///   the next snapshot heals it; the journal row is correct.
    public static func run(
        defaults: UserDefaults = .standard,
        serverTags: [Int64: String?],
        push: (Int64, String) async throws -> Void
    ) async {
        for (id, letter) in BoxLetterOverrides.all(from: defaults) {
            guard case .some(.none) = serverTags[id] else {
                // Unknown id (revoked) or journal already has a tag.
                BoxLetterOverrides.remove(id: id, from: defaults)
                continue
            }
            if (try? await push(id, letter)) != nil {
                BoxLetterOverrides.remove(id: id, from: defaults)
            }
            // Push failed: keep the entry; the next launch retries.
        }
    }
}
