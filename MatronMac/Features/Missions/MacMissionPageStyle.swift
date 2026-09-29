import SwiftUI
import AppKit
import MatronDesignSystem
import MatronModels

/// Which view the Mac mission page shows. Remembered per app (AppStorage)
/// under `MacMissionPage.modeKey`.
enum MacMissionPageMode: String, CaseIterable, Identifiable {
    case overview, board

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .board: return "Board"
        }
    }
}

/// The page's width rules, pure so the breakpoint is a plain test.
enum MacMissionPageLayout {
    /// Content never grows past this; wider windows centre it.
    static let maxContentWidth: CGFloat = 1_300
    /// Overview goes to two columns once the DETAIL column (the page's
    /// whole width) is at least this wide.
    static let twoColumnMinDetailWidth: CGFloat = 900
    static let horizontalPadding: CGFloat = 32
    /// The right Overview column's share of the content width.
    static let sideColumnFraction: CGFloat = 0.4
    static let columnSpacing: CGFloat = 24

    /// The width the page's content gets inside a `detailWidth`-wide detail.
    static func contentWidth(detailWidth: CGFloat) -> CGFloat {
        max(0, min(detailWidth - 2 * horizontalPadding, maxContentWidth))
    }

    static func usesTwoColumns(detailWidth: CGFloat) -> Bool {
        detailWidth >= twoColumnMinDetailWidth
    }
}

/// A fixed clock for the page's age labels — snapshot tests pin it; the
/// app leaves it `nil` and the labels tick each minute.
private struct MacMissionPageClockKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    var macMissionPageClock: Date? {
        get { self[MacMissionPageClockKey.self] }
        set { self[MacMissionPageClockKey.self] = newValue }
    }
}

/// Text that depends on the time ("14m ago"). The minute tick is scoped to
/// this label alone: a `TimelineView` around the whole page re-evaluated
/// every card and milestone once a minute.
struct MacMinuteText: View {
    let make: (Date) -> String
    @Environment(\.macMissionPageClock) private var fixedNow

    init(_ make: @escaping (Date) -> String) { self.make = make }

    var body: some View {
        if let fixedNow {
            Text(make(fixedNow))
        } else {
            TimelineView(.everyMinute) { context in Text(make(context.date)) }
        }
    }
}

/// Colours the approved wireframes name. Deliberately not `ItemGlyph` /
/// `MissionGlyph` tints (question orange, decision purple, milestones
/// orange/grey), which the rest of the app keeps: the page's pills and
/// dots follow the wireframe.
enum MacMissionPalette {
    static func kindTint(_ kind: ItemKind) -> Color {
        switch kind {
        case .question: return .red
        case .task: return .blue
        case .decision: return .orange
        }
    }

    static func milestoneTint(_ kind: MilestoneKind) -> Color {
        switch kind {
        case .userInput: return .purple
        case .progress: return .blue
        }
    }

    static func columnTint(_ column: MissionBoard.Column) -> Color {
        switch column {
        case .toDo: return .gray
        case .inProgress: return .blue
        case .done: return .green
        }
    }

    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
}

/// A small-caps section label: "STATUS", "LATEST STEP", "NEEDS YOU".
struct MacMissionSectionLabel: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) { self.text = text; self.tint = tint }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(tint)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The page's rounded card: padded, filled, hairline border.
struct MacMissionCard: ViewModifier {
    var fill: Color = MacMissionPalette.cardBackground
    var border: Color = Color.primary.opacity(0.10)

    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(border))
    }
}

extension View {
    func macMissionCard(fill: Color = MacMissionPalette.cardBackground,
                        border: Color = Color.primary.opacity(0.10)) -> some View {
        modifier(MacMissionCard(fill: fill, border: border))
    }
}

/// The board card's kind pill: Question red, Task blue, Decision amber.
struct MacItemKindPill: View {
    let kind: ItemKind

    var body: some View {
        Text(ItemGlyph.label(kind))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(MacMissionPalette.kindTint(kind), in: Capsule())
            .fixedSize()
    }
}
