import Foundation

/// The user's default model and effort for new chats (journal `GET`/`PUT
/// /defaults`, live as `{kind:"defaults", default_model, default_effort}`).
/// Every bridge applies them to a chat started without a choice of its own;
/// `nil` is "Box default": each box's own `MATRON_DEFAULT_*` setting.
public struct NewChatDefaults: Equatable, Sendable {
    /// The two settings, keyed as the journal names them.
    public enum Key: String, CaseIterable, Sendable {
        case model = "default_model"
        case effort = "default_effort"
    }

    public var model: String?
    public var effort: String?

    public init(model: String? = nil, effort: String? = nil) {
        self.model = model
        self.effort = effort
    }

    public subscript(key: Key) -> String? {
        get {
            switch key {
            case .model: return model
            case .effort: return effort
            }
        }
        set {
            switch key {
            case .model: model = newValue
            case .effort: effort = newValue
            }
        }
    }

    /// Decodes a `GET /defaults` answer, a `PUT /defaults` answer, or a live
    /// `defaults` frame (whose `kind` is ignored). A missing, null or empty
    /// value is "Box default"; any other non-string rejects the whole body,
    /// so a malformed frame never half-applies.
    public static func decode(_ obj: [String: Any]) -> NewChatDefaults? {
        guard let model = value(obj[Key.model.rawValue]),
              let effort = value(obj[Key.effort.rawValue]) else { return nil }
        return NewChatDefaults(model: model, effort: effort)
    }

    /// `.some(nil)` for box default, `nil` for a value that is not a string.
    private static func value(_ raw: Any?) -> String?? {
        switch raw {
        case nil, is NSNull: return .some(nil)
        case let string as String: return .some(string.isEmpty ? nil : string)
        default: return nil
        }
    }
}
