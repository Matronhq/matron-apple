import Foundation
import MatronJournal

/// The words and choices Settings ▸ Devices ▸ New sessions offers for one
/// agent box, in one place so the iPhone and the Mac say the same thing.
/// Model and effort choices follow the box's agent: Claude gets Settings ▸
/// New chats' lists, Codex a free-text model id and its own effort levels.
public extension BoxDefaults {
    typealias Choice = NewChatDefaults.Choice

    static let helpText = "What a session started on this box gets when nobody names an agent, model or effort. Box default uses the box's own setting; for Claude, your New chats default comes first."
    static let codexModelHelp = "A Codex model id, e.g. gpt-5.1-codex. Leave empty for Codex's own default."

    static let agentChoices: [Choice] = [
        Choice(value: nil, label: "Box default"),
        Choice(value: "claude", label: "Claude"),
        Choice(value: "codex", label: "Codex"),
    ]

    /// Codex's own reasoning levels (`minimal` is Codex-only; `max` is
    /// Claude-only and not offered here).
    static let codexEffortChoices: [Choice] = [
        Choice(value: nil, label: "Codex default"),
        Choice(value: "minimal", label: "Minimal"),
        Choice(value: "low", label: "Low"),
        Choice(value: "medium", label: "Medium"),
        Choice(value: "high", label: "High"),
        Choice(value: "xhigh", label: "X-High"),
    ]

    /// The model picker's options on a Claude box. Codex boxes take a typed
    /// id instead (`codexModel(fromDraft:)`).
    var modelChoices: [Choice] {
        Self.including(model, in: NewChatDefaults.modelChoices)
    }

    var effortChoices: [Choice] {
        Self.including(effort, in: agent == "codex" ? Self.codexEffortChoices : NewChatDefaults.effortChoices)
    }

    /// One line for the Devices row: "Claude · Opus · High", "Codex ·
    /// Codex's own model". With no agent set, the model and effort are not
    /// applied by the bridge, so they are not shown.
    var summary: String {
        guard let agent else { return "Box default" }
        var parts: [String]
        switch agent {
        case "claude":
            parts = ["Claude", model.map { Self.label($0, in: NewChatDefaults.modelChoices) } ?? "Your default model"]
        case "codex":
            parts = ["Codex", model ?? "Codex's own model"]
        default:
            parts = [agent, model].compactMap { $0 }
        }
        if let effort {
            parts.append(Self.label(effort, in: NewChatDefaults.effortChoices + Self.codexEffortChoices))
        }
        return parts.joined(separator: " · ")
    }

    /// A typed Codex model id, checked the way the journal checks it
    /// (trimmed, lowercased, ≤64, `^[a-z0-9][a-z0-9.-]*(\[1m\])?$`), so a
    /// typo is caught before the round-trip. Blank is Codex's own default.
    enum ModelDraft: Equatable, Sendable {
        case valid(String?)
        case invalid
    }

    static func codexModel(fromDraft draft: String) -> ModelDraft {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return .valid(nil) }
        guard value.count <= 64,
              value.range(of: #"^[a-z0-9][a-z0-9.-]*(\[1m\])?$"#, options: .regularExpression) != nil
        else { return .invalid }
        return .valid(value)
    }

    /// What leaving the Codex model field should do with `draft` — on
    /// Return, on focus moving away, and when the editor closes, so a typed
    /// id is never dropped. `.unchanged` when it says what is stored.
    enum ModelSave: Equatable, Sendable {
        case unchanged
        case save(String?)
        case invalid
    }

    func codexModelSave(draft: String) -> ModelSave {
        switch Self.codexModel(fromDraft: draft) {
        case .invalid: return .invalid
        case .valid(let value): return value == model ? .unchanged : .save(value)
        }
    }

    /// `base`, plus a stored value outside it under its own name, so the
    /// picker shows what is really set (one another app or the Coordinator
    /// wrote).
    private static func including(_ value: String?, in base: [Choice]) -> [Choice] {
        guard let value, !base.contains(where: { $0.value == value }) else { return base }
        return base + [Choice(value: value, label: value)]
    }

    private static func label(_ value: String, in choices: [Choice]) -> String {
        choices.first { $0.value == value }?.label ?? value
    }
}

public extension BoxDefaults.Key {
    /// The picker's label.
    var title: String {
        switch self {
        case .agent: return "Agent"
        case .model: return "Model"
        case .effort: return "Effort"
        }
    }

    /// The setting's name inside an error message.
    var errorName: String {
        switch self {
        case .agent: return "agent"
        case .model: return "model"
        case .effort: return "effort"
        }
    }
}
