import Foundation
import MatronJournal

/// The words and choices Settings → New chats offers, in one place so the
/// iPhone, the Mac and the web app (matron-web SettingsSheet) say the same
/// thing.
public extension NewChatDefaults {
    /// One option of a picker. `value` `nil` is "Box default".
    struct Choice: Equatable, Hashable, Sendable {
        public let value: String?
        public let label: String

        public init(value: String?, label: String) {
            self.value = value
            self.label = label
        }
    }

    static let helpText = "Used when a new chat starts without a choice of its own. Box default uses each box's setting."
    static let unsupportedText = "This journal does not support default settings yet."

    static let modelChoices: [Choice] = [
        Choice(value: nil, label: "Box default"),
        Choice(value: "opus", label: "Opus"),
        Choice(value: "opus[1m]", label: "Opus 1M"),
        Choice(value: "sonnet", label: "Sonnet"),
        Choice(value: "sonnet[1m]", label: "Sonnet 1M"),
        Choice(value: "haiku", label: "Haiku"),
        Choice(value: "opusplan", label: "Opus Plan"),
        Choice(value: "fable", label: "Fable"),
    ]

    static let effortChoices: [Choice] = [
        Choice(value: nil, label: "Box default"),
        Choice(value: "low", label: "Low"),
        Choice(value: "medium", label: "Medium"),
        Choice(value: "high", label: "High"),
        Choice(value: "xhigh", label: "X-High"),
        Choice(value: "max", label: "Max"),
    ]
}

public extension NewChatDefaults.Key {
    /// The picker's label.
    var title: String {
        switch self {
        case .model: return "Default model"
        case .effort: return "Default effort"
        }
    }

    /// The setting's name inside an error message.
    var errorName: String {
        switch self {
        case .model: return "default model"
        case .effort: return "default effort"
        }
    }

    /// The picker's options for a stored `value`. One outside the list (a
    /// full claude-* name another app or an agent wrote) is added under its
    /// own name, so the picker shows what is really set.
    func choices(stored value: String?) -> [NewChatDefaults.Choice] {
        let base = self == .model ? NewChatDefaults.modelChoices : NewChatDefaults.effortChoices
        guard !base.contains(where: { $0.value == value }), let value else { return base }
        return base + [NewChatDefaults.Choice(value: value, label: value)]
    }
}
