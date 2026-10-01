import SwiftUI
import MatronModels

/// One row of a project page's "Sessions on it now" (iOS): state dot, tag,
/// title and context gauge, then the model and the mission it is on. The
/// Mac page draws `MacProjectSessionRow` from the same `metaLine`.
public struct ProjectSessionRowView: View {
    let row: ProjectSessionRow

    public init(row: ProjectSessionRow) { self.row = row }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                DashboardStateDot(state: row.session.state, isStalled: row.session.isStalled)
                DashboardSessionTag(session: row.session)
                Text(row.session.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                if let context = row.session.context { ContextGaugeLabel(context: context) }
            }
            if let meta = Self.metaLine(row) {
                Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "opus · stalled · #4907 Launch day: Wed 7 Oct": the model, a stall,
    /// then the mission — its numbers alone ("#4791, #4907") when it is on
    /// more than one, so a long title never truncates the others away. Nil
    /// when there is nothing to say.
    public static func metaLine(_ row: ProjectSessionRow) -> String? {
        var parts: [String] = []
        if let model = row.session.model { parts.append(model) }
        if row.session.isStalled { parts.append("stalled") }
        if row.missions.count == 1, let only = row.missions.first {
            parts.append(only.label)
        } else if !row.missions.isEmpty {
            parts.append(row.missions.map { "#\($0.num)" }.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
