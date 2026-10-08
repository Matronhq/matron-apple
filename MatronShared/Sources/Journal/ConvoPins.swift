import Foundation

/// "New session on this box — move pin here?" (journal "Pinned desk chats"):
/// the newest top-level conversation on the pinned conversation's box,
/// created after the pin and the pinned conversation's last message.
public struct ConvoPinSuccessor: Equatable, Hashable, Sendable {
    public var convoID: String
    public var title: String
    public var createdAt: Date?

    public init(convoID: String, title: String, createdAt: Date? = nil) {
        self.convoID = convoID
        self.title = title
        self.createdAt = createdAt
    }
}

/// One of the user's pinned desk chats (journal "Pinned desk chats"): a
/// conversation the user named and placed under the Coordinator, synced to
/// every device. A pin points at a conversation, never a box; nothing moves
/// it but the user.
public struct ConvoPin: Equatable, Hashable, Identifiable, Sendable {
    /// The journal's cap when a response does not say.
    public static let defaultLimit = 5
    /// A label is one line of 1–24 characters (code points).
    public static let labelMax = 24
    public static let labelFallback = "Pinned chat"

    public var convoID: String
    public var label: String
    /// `""` draws the label's first letter instead.
    public var emoji: String
    public var position: Int
    /// The box the pinned conversation runs on.
    public var deviceID: Int64?
    /// The conversation row is gone (deleted, or the user left it): the apps
    /// grey the entry and offer only Move pin… and Unpin.
    public var missing: Bool
    public var successor: ConvoPinSuccessor?

    public var id: String { convoID }

    public init(convoID: String, label: String, emoji: String = "", position: Int = 0,
                deviceID: Int64? = nil, missing: Bool = false, successor: ConvoPinSuccessor? = nil) {
        self.convoID = convoID
        self.label = label
        self.emoji = emoji
        self.position = position
        self.deviceID = deviceID
        self.missing = missing
        self.successor = successor
    }

    /// What the entry leads with: the emoji, else the label's first letter
    /// upper-cased.
    public var glyph: String {
        let emoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        if !emoji.isEmpty { return emoji }
        return label.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    }

    /// One pin row, or `nil` when it lacks what the sidebar needs (an id and
    /// a label).
    public static func decode(_ obj: [String: Any]) -> ConvoPin? {
        guard let id = obj["convo_id"] as? String, !id.isEmpty,
              let label = obj["label"] as? String,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var successor: ConvoPinSuccessor?
        if let raw = obj["successor"] as? [String: Any], let sid = raw["convo_id"] as? String, !sid.isEmpty {
            successor = ConvoPinSuccessor(convoID: sid, title: raw["title"] as? String ?? "",
                                          createdAt: (raw["created_at"] as? NSNumber).map {
                                              Date(timeIntervalSince1970: $0.doubleValue / 1000)
                                          })
        }
        return ConvoPin(convoID: id, label: label, emoji: obj["emoji"] as? String ?? "",
                        position: (obj["position"] as? NSNumber)?.intValue ?? 0,
                        deviceID: (obj["device_id"] as? NSNumber)?.int64Value,
                        missing: obj["missing"] as? Bool ?? false, successor: successor)
    }

    /// A pin array in `position` order, malformed and repeated rows dropped;
    /// `nil` when `raw` is not an array.
    public static func decodeList(_ raw: Any?) -> [ConvoPin]? {
        guard let rows = raw as? [Any] else { return nil }
        var seen = Set<String>()
        var pins: [ConvoPin] = []
        for row in rows {
            guard let obj = row as? [String: Any], let pin = decode(obj), seen.insert(pin.convoID).inserted else { continue }
            pins.append(pin)
        }
        // Stable: equal positions keep the journal's order.
        return pins.enumerated().sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }.map(\.element)
    }

    /// A label fitting the journal's rule: one line, trimmed, at most 24
    /// characters (code points).
    public static func clampLabel(_ text: String) -> String {
        let line = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let scalars = line.unicodeScalars.prefix(labelMax)
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    /// An emoji fitting the journal's rule: no whitespace, at most 16 UTF-16
    /// units. Anything longer keeps its first character.
    public static func clampEmoji(_ text: String) -> String {
        let token = text.filter { !$0.isWhitespace && !$0.isNewline }
        if token.utf16.count <= 16 { return token }
        return token.first.map(String.init) ?? ""
    }

    /// The full order after moving `convoID` one step; `nil` when it cannot
    /// move that way.
    public static func movedOrder(_ pins: [ConvoPin], _ convoID: String, up: Bool) -> [String]? {
        var order = pins.map(\.convoID)
        guard let index = order.firstIndex(of: convoID) else { return nil }
        let target = up ? index - 1 : index + 1
        guard order.indices.contains(target) else { return nil }
        order.swapAt(index, target)
        return order
    }
}

/// A `{pins, limit}` answer from any `/pins` route.
public struct ConvoPinList: Equatable, Sendable {
    public var pins: [ConvoPin]
    public var limit: Int

    public init(pins: [ConvoPin], limit: Int = ConvoPin.defaultLimit) {
        self.pins = pins
        self.limit = limit
    }

    public static func decode(_ obj: [String: Any]) -> ConvoPinList? {
        guard let pins = ConvoPin.decodeList(obj["pins"]) else { return nil }
        let limit = (obj["limit"] as? NSNumber)?.intValue ?? 0
        return ConvoPinList(pins: pins, limit: limit > 0 ? limit : ConvoPin.defaultLimit)
    }
}

/// A refused pin write, in the user's words.
public enum ConvoPinError: Error, Equatable, Sendable {
    /// 409 `pin_limit`.
    case limit(Int)
    /// 409 `already_pinned` (a move onto a pinned conversation).
    case alreadyPinned
    /// 404: the pin, or the conversation, is not there any more.
    case notFound
    /// 400: a bad label, emoji or order.
    case invalid(String)
}

extension ConvoPinError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .limit(let limit): return "You can pin up to \(limit) chats."
        case .alreadyPinned: return "That chat is already pinned."
        case .notFound: return "That chat isn't pinned any more."
        case .invalid(let message): return message.isEmpty ? "The journal refused that pin." : message
        }
    }
}

/// The `/pins` routes (journal "Pinned desk chats"). Every write returns the
/// whole list as stored. A protocol so `PinsStore` tests fake it.
public protocol PinsProviding: Sendable {
    func pins() async throws -> ConvoPinList
    /// Pins `convoID` (a new pin needs `label`; it goes last) or renames it.
    func setPin(_ convoID: String, label: String?, emoji: String?) async throws -> ConvoPinList
    func reorderPins(_ order: [String]) async throws -> ConvoPinList
    func unpin(_ convoID: String) async throws -> ConvoPinList
    /// Re-points the pin at `to`, keeping its label, emoji and place.
    func movePin(_ convoID: String, to: String) async throws -> ConvoPinList
    /// Hides the successor hint `successorID` until a newer session starts.
    func dismissPinSuccessor(_ convoID: String, successorID: String) async throws -> ConvoPinList
}

extension JournalAPI: PinsProviding {
    public func pins() async throws -> ConvoPinList {
        try await pinsRequest(path: "/pins")
    }

    public func setPin(_ convoID: String, label: String?, emoji: String?) async throws -> ConvoPinList {
        var body: [String: Any] = [:]
        if let label { body["label"] = label }
        if let emoji { body["emoji"] = emoji }
        return try await pinsRequest(path: "/pins/\(Self.pinPathComponent(convoID))", method: "PUT", body: body)
    }

    public func reorderPins(_ order: [String]) async throws -> ConvoPinList {
        try await pinsRequest(path: "/pins", method: "PUT", body: ["order": order])
    }

    public func unpin(_ convoID: String) async throws -> ConvoPinList {
        try await pinsRequest(path: "/pins/\(Self.pinPathComponent(convoID))", method: "DELETE")
    }

    public func movePin(_ convoID: String, to: String) async throws -> ConvoPinList {
        try await pinsRequest(path: "/pins/\(Self.pinPathComponent(convoID))/move", method: "POST",
                              body: ["to_convo_id": to])
    }

    public func dismissPinSuccessor(_ convoID: String, successorID: String) async throws -> ConvoPinList {
        try await pinsRequest(path: "/pins/\(Self.pinPathComponent(convoID))/dismiss", method: "POST",
                              body: ["successor_id": successorID])
    }

    static func pinPathComponent(_ convoID: String) -> String {
        convoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? convoID
    }

    /// The shared request: 409 and 400 keep their `detail` (the generic
    /// `request` folds every 409 into `.conflict`).
    private func pinsRequest(path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> ConvoPinList {
        let (data, response) = try await rawRequest(path: path, method: method, body: body)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch response.statusCode {
        case 200:
            guard let obj, let list = ConvoPinList.decode(obj) else {
                throw JournalAPIError.transport("malformed /pins response")
            }
            return list
        case 409:
            if obj?["detail"] as? String == "already_pinned" { throw ConvoPinError.alreadyPinned }
            let limit = (obj?["limit"] as? NSNumber)?.intValue ?? 0
            throw ConvoPinError.limit(limit > 0 ? limit : ConvoPin.defaultLimit)
        case 400:
            throw ConvoPinError.invalid(obj?["message"] as? String ?? "")
        case 404 where method != "GET":
            throw ConvoPinError.notFound
        default:
            throw Self.error(status: response.statusCode, data: data)
        }
    }
}
