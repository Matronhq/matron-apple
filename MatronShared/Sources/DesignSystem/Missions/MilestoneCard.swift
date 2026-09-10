import SwiftUI
import MatronModels
import MatronEvents

/// Inline timeline rendering of a `milestone` marker: the card IS the jump
/// target's own row, so it needs no navigation of its own beyond opening the
/// mission page.
///
/// The mission is named through `marker.missionLabel`, which falls back to
/// `#N` when the journal sieved `mission_title` away at write time. Never
/// render `missionTitle` directly.
public struct MilestoneCard: View {
    let marker: MilestoneMarkerEvent
    let onOpen: () -> Void
    public init(marker: MilestoneMarkerEvent, onOpen: @escaping () -> Void) {
        self.marker = marker; self.onOpen = onOpen
    }

    /// "Your input · Missions & milestones" / "Progress · #61". Static so the
    /// fallback is unit-testable without rendering.
    public static func subtitle(for marker: MilestoneMarkerEvent) -> String {
        "\(MissionGlyph.label(marker.kind)) · \(marker.missionLabel)"
    }

    public var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: MissionGlyph.symbol(marker.kind))
                    .foregroundStyle(MissionGlyph.tint(marker.kind))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("#\(marker.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(marker.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    }
                    if !marker.body.isEmpty {
                        Text(marker.body.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Text(Self.subtitle(for: marker))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(marker.kind == .userInput ? Color.orange.opacity(0.5) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Milestone \(marker.num), \(marker.title). \(Self.subtitle(for: marker))")
        .accessibilityHint("Opens the mission")
    }
}

/// Inline rendering of a `mission` marker — a one-line notice, not a card.
/// Same title-fallback rule as `MilestoneCard`.
public struct MissionNotice: View {
    let marker: MissionMarkerEvent
    let onOpen: () -> Void
    public init(marker: MissionMarkerEvent, onOpen: @escaping () -> Void) {
        self.marker = marker; self.onOpen = onOpen
    }

    public static func text(for marker: MissionMarkerEvent) -> String {
        let named = marker.title.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
        switch marker.action {
        case .created: return "🏁 Mission #\(marker.num) started\(named)"
        case .joined:  return "🏁 Joined mission #\(marker.num)\(named)"
        case .updated: return "🏁 Mission #\(marker.num) renamed\(named)"
        case .closed:
            guard !marker.openItemNums.isEmpty else { return "🏁 Mission #\(marker.num) closed\(named)" }
            return "🏁 Mission #\(marker.num)\(named) closed over " + marker.openItemNums.map { "#\($0)" }.joined(separator: ", ")
        }
    }

    public var body: some View {
        Button(action: onOpen) {
            Text(Self.text(for: marker)).font(.caption).lineLimit(2).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.text(for: marker))
    }
}
