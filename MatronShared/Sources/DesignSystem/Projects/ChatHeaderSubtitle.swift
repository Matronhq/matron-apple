import SwiftUI
import MatronModels

/// The iOS chat header's second line (spec 2026-09-30 §6, mockup 04 right):
/// "box · ~/workdir" — which Dan asked to see without opening anything
/// (16 Aug) — then the mission chip. Both share the line; the workdir
/// middle-truncates first. When even `contextMinWidth` of workdir beside
/// the whole chip won't fit, the chip drops to a compact line of its own.
public struct ChatHeaderSubtitle: View {
    /// The least workdir text worth keeping beside the chip.
    public static let contextMinWidth: CGFloat = 96

    public enum Layout: Equatable { case contextAndChip, chipOnly, contextOnly, none }

    public static func layout(context: String?, missions: ConversationMissions) -> Layout {
        switch (context?.isEmpty == false, MissionChipLabel.text(missions) != nil) {
        case (true, true): return .contextAndChip
        case (false, true): return .chipOnly
        case (true, false): return .contextOnly
        case (false, false): return .none
        }
    }

    let context: String?
    let missions: ConversationMissions
    let onTapChip: () -> Void
    public init(context: String?, missions: ConversationMissions, onTapChip: @escaping () -> Void) {
        self.context = context; self.missions = missions; self.onTapChip = onTapChip
    }

    public var body: some View {
        switch Self.layout(context: context, missions: missions) {
        case .contextAndChip:
            // `ViewThatFits` compares IDEAL widths. The workdir's ideal is
            // pinned to `contextMinWidth`, so the one-line form is chosen
            // whenever 96 pt of workdir plus the whole chip fit — and then
            // it is laid out at the real width, where the workdir grows or
            // truncates while the higher-priority chip keeps its size.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    contextText
                        .frame(minWidth: Self.contextMinWidth, idealWidth: Self.contextMinWidth, maxWidth: .infinity)
                    chip.layoutPriority(1)
                }
                VStack(spacing: 1) {
                    contextText
                    chip
                }
            }
        case .chipOnly: chip
        case .contextOnly: contextText
        case .none: EmptyView()
        }
    }

    private var contextText: some View {
        Text(context ?? "")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            // The tail of a path is the part worth keeping.
            .truncationMode(.middle)
    }

    private var chip: some View {
        Button(action: onTapChip) { MissionChipLabel(missions: missions) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.missionsChip")
    }
}
