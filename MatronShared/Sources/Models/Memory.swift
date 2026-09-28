import Foundation

/// What kind of memory it is — the Claude Code memory-file types the
/// journal stores (`memories.type` CHECK). The user-facing labels are the
/// web tracker's (matron-web PR #38).
public enum MemoryType: String, Codable, Sendable, CaseIterable {
    case user, feedback, project, reference

    /// The picker order: `feedback` (the journal's default on create)
    /// first, then the rest as web lists them.
    public static let pickerOrder: [MemoryType] = [.feedback, .user, .project, .reference]

    public var label: String {
        switch self {
        case .user: return "About you"
        case .feedback: return "How to work"
        case .project: return "Project"
        case .reference: return "Reference"
        }
    }
}

/// One memory (journal `GET /memories`, spec 2026-09-27 memories): a
/// standing rule or fact any of the user's agents may save and every one
/// of them may read. `name` is the key — kebab-case, unique per user — and
/// `PUT /memories/:name` overwrites the whole memory.
public struct Memory: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: MemoryType
    /// One line, at most 200 characters — the line the Coordinator sees at spawn.
    public let description: String
    /// Markdown notes, at most 8192 UTF-8 bytes, may be empty.
    public let body: String
    public let createdBy: ItemAuthor
    public let updatedBy: ItemAuthor
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String, name: String, type: MemoryType, description: String, body: String = "",
                createdBy: ItemAuthor = .agent, updatedBy: ItemAuthor = .agent,
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.name = name; self.type = type; self.description = description; self.body = body
        self.createdBy = createdBy; self.updatedBy = updatedBy; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// `nil` when a field the list needs is missing or unknown (a type this
    /// build doesn't know, say) — the caller drops the row rather than
    /// guessing.
    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty,
              let name = json["name"] as? String, !name.isEmpty,
              let type = (json["type"] as? String).flatMap(MemoryType.init(rawValue:)),
              let description = json["description"] as? String,
              let createdAt = (json["created_at"] as? NSNumber).map({ Date(timeIntervalSince1970: $0.doubleValue / 1000) }),
              let updatedAt = (json["updated_at"] as? NSNumber).map({ Date(timeIntervalSince1970: $0.doubleValue / 1000) })
        else { return nil }
        self.init(id: id, name: name, type: type, description: description,
                  body: json["body"] as? String ?? "",
                  createdBy: (json["created_by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent,
                  updatedBy: (json["updated_by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent,
                  createdAt: createdAt, updatedAt: updatedAt)
    }

    /// "you" / "an agent", for "updated 5 min ago by you".
    public static func authorPhrase(_ author: ItemAuthor) -> String {
        author == .user ? "you" : "an agent"
    }
}

/// The journal's memory rules (`src/memories.js`), restated so the editor
/// refuses a bad value with a reason before any request goes out.
public enum MemoryRules {
    public static let nameMaxLength = 64
    public static let descriptionMaxLength = 200
    public static let bodyMaxBytes = 8192
    /// At most this many memories per user; a create past it is 409 `too_many`.
    public static let maxMemories = 200

    /// `^[a-z0-9][a-z0-9-]{0,63}$`, ASCII only.
    public static func isValidName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard (1...nameMaxLength).contains(scalars.count) else { return false }
        func isLowerAlnum(_ s: Unicode.Scalar) -> Bool { ("a"..."z").contains(s) || ("0"..."9").contains(s) }
        guard isLowerAlnum(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { isLowerAlnum($0) || $0 == "-" }
    }

    /// The description as the journal stores it: trimmed.
    public static func normalizedDescription(_ description: String) -> String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// C0/C1 controls (so `\n`, `\r`, `\t` too) and U+2028/U+2029 — the
    /// journal's `LINE_BAD_CHARS`.
    static func isLineBreaking(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v <= 0x1F || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029
    }

    /// The first thing wrong with a memory form, or `nil` when the journal
    /// would accept it. The same checks, in the same order, as the web
    /// editor's `memoryFormError`, with the journal's full single-line rule.
    public static func formError(name: String, description: String, body: String) -> String? {
        if !isValidName(name) {
            return "Name must be lowercase letters, digits and dashes (up to 64), starting with a letter or digit."
        }
        let trimmed = normalizedDescription(description)
        if trimmed.isEmpty { return "Description is required." }
        // The journal counts JavaScript string length: UTF-16 code units.
        if trimmed.utf16.count > descriptionMaxLength {
            return "Description must be at most \(descriptionMaxLength) characters."
        }
        if trimmed.unicodeScalars.contains(where: isLineBreaking) { return "Description must be a single line." }
        if body.utf8.count > bodyMaxBytes { return "Notes must be at most 8 KB." }
        return nil
    }
}
