import SwiftUI
import MatronModels

/// The project vocabulary's symbols, in one place (sibling of `MissionGlyph`).
public enum ProjectGlyph {
    /// The Projects tab / nav entry.
    public static let symbol = "square.stack.3d.up"
    /// The chip's mark (the mockups' ▣).
    public static let chipSymbol = "square.inset.filled"
    public static let tint = Color.purple
}

/// Running green, waiting orange, idle grey, quiet faint grey (spec §2).
public struct MissionActivityDot: View {
    let activity: MissionActivity
    let isClosed: Bool
    public init(activity: MissionActivity, isClosed: Bool = false) { self.activity = activity; self.isClosed = isClosed }

    public var body: some View {
        Circle().fill(Self.color(activity, isClosed: isClosed)).frame(width: 9, height: 9)
            .accessibilityLabel(isClosed ? "Closed" : activity.label)
    }

    public static func color(_ activity: MissionActivity, isClosed: Bool) -> Color {
        if isClosed { return Color.gray.opacity(0.5) }
        switch activity {
        case .running: return .green
        case .waiting: return .orange
        case .idle: return .gray
        case .quiet: return Color.gray.opacity(0.4)
        }
    }
}

/// "also on #4791" / "moved to #4905" on a mission page's conversation row
/// (mockup 03). Only the `#N` is a button: it opens that mission. A
/// borderless button, so it stays tappable inside a List row whose own tap
/// opens the conversation.
public struct LinkedMissionChip: View {
    let linked: LinkedMission
    let action: () -> Void
    public init(linked: LinkedMission, action: @escaping () -> Void) { self.linked = linked; self.action = action }

    public static func accessibilityText(_ linked: LinkedMission) -> String {
        "\(linked.label) mission \(linked.link.num), \(linked.link.title)"
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text(linked.label).foregroundStyle(.secondary)
            Button(action: action) {
                Text(verbatim: "#\(linked.link.num)").monospacedDigit().fontWeight(.medium)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.blue.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Self.accessibilityText(linked))
            .accessibilityHint("Opens that mission")
            .accessibilityIdentifier("missionConversation.linked.\(linked.link.num)")
        }
        .font(.caption)
        .fixedSize()
    }
}

/// "▣ Promo launch" — a mission's project, tappable when it can open.
public struct ProjectChip: View {
    let title: String
    let action: (() -> Void)?
    public init(title: String, action: (() -> Void)? = nil) { self.title = title; self.action = action }

    public var body: some View {
        if let action {
            Button(action: action) { label }.buttonStyle(.plain)
                .accessibilityHint("Opens the project")
        } else {
            label
        }
    }

    private var label: some View {
        Label { Text(title).lineLimit(1) } icon: { Image(systemName: ProjectGlyph.chipSymbol) }
            .font(.caption.weight(.medium))
            .foregroundStyle(ProjectGlyph.tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(ProjectGlyph.tint.opacity(0.12), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Project \(title)")
    }
}
