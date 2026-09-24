import Foundation
import MatronModels

/// One switchable session setting in the iPhone ⓘ sheet (decision #2972):
/// the Model row (`/model`) or the Effort row (`/effort`). Built from the
/// option lists the bridge publishes on the chat's status frame — the
/// same pool the slash palette suggests from — so a row only exists when
/// the bridge offers something to switch to. Choosing an option produces
/// exactly the command the user would otherwise type.
public struct SessionSettingRow: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case model, effort
    }

    public let kind: Kind
    /// Offered options in the bridge's order, repeated values (compared
    /// case-insensitively) collapsed to their first occurrence — the
    /// palette's own rule, since the picker identifies rows by value.
    public let options: [SessionStatus.Option]
    /// The session's current value as the status frame reports it
    /// (`model` / `effort`), `nil` when unknown.
    public let currentValue: String?

    public var id: Kind { kind }

    public var title: String {
        switch kind {
        case .model: return "Model"
        case .effort: return "Effort"
        }
    }

    /// What the row shows as the current value: the matching option's
    /// label (or value, when unlabelled), else the raw status value — the
    /// bridge may report a full model id that none of the aliases equals.
    public var currentLabel: String? {
        guard let currentValue else { return nil }
        guard let match = options.first(where: isCurrent) else { return currentValue }
        return match.label ?? match.value
    }

    /// Whether `option` is the session's current value: an exact,
    /// case-insensitive match on its value or label. Deliberately no
    /// substring matching — `opus` must not tick for `opus[1m]`.
    public func isCurrent(_ option: SessionStatus.Option) -> Bool {
        guard let current = currentValue?.lowercased() else { return false }
        return option.value.lowercased() == current || option.label?.lowercased() == current
    }

    /// The chat message that makes the switch, as if typed.
    public func command(for option: SessionStatus.Option) -> String {
        "/\(kind.rawValue) \(option.value)"
    }

    /// The rows for a status: Model then Effort, each only when its option
    /// list is present and non-empty (an older bridge publishes neither).
    public static func rows(for status: SessionStatus?) -> [SessionSettingRow] {
        guard let status else { return [] }
        var rows: [SessionSettingRow] = []
        let model = deduplicated(status.modelOptions)
        if !model.isEmpty { rows.append(SessionSettingRow(kind: .model, options: model, currentValue: status.model)) }
        let effort = deduplicated(status.effortLevels)
        if !effort.isEmpty { rows.append(SessionSettingRow(kind: .effort, options: effort, currentValue: status.effort)) }
        return rows
    }

    private static func deduplicated(_ options: [SessionStatus.Option]?) -> [SessionStatus.Option] {
        var seen: Set<String> = []
        return (options ?? []).filter { seen.insert($0.value.lowercased()).inserted }
    }
}
