import SwiftUI

/// Top-level Mac navigation entries (app shell, spec §5), top to bottom.
enum MacNav: Hashable, CaseIterable {
    case coordinator
    case conversations
    case decisions

    var title: String {
        switch self {
        case .coordinator: return "Coordinator"
        case .conversations: return "Conversations"
        case .decisions: return "Decisions"
        }
    }

    var symbol: String {
        switch self {
        case .coordinator: return "person.crop.circle.badge.checkmark"
        case .conversations: return "bubble.left.and.bubble.right"
        case .decisions: return "checkmark.circle"
        }
    }
}

/// Fixed-width vertical column of large icons with labels beneath — the
/// Slack-workspace-switcher shape Dan asked for. Lives INSIDE the sidebar
/// column of `MacChatListView`'s split view (so the sidebar's material and
/// `navigationSplitViewColumnWidth` still apply) and is never collapsible.
/// The Decisions entry carries a red count badge at its top-trailing
/// corner, hidden at zero.
struct MacNavColumn: View {
    @Binding var selection: MacNav
    let decisionsCount: Int

    static let width: CGFloat = 72

    var body: some View {
        VStack(spacing: 4) {
            ForEach(MacNav.allCases, id: \.self) { entry in
                Button { selection = entry } label: {
                    VStack(spacing: 4) {
                        Image(systemName: entry.symbol)
                            .font(.system(size: 22))
                            .frame(height: 28)
                            .overlay(alignment: .topTrailing) {
                                if entry == .decisions, decisionsCount > 0 {
                                    countBadge
                                }
                            }
                        Text(entry.title)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .frame(width: Self.width - 12, height: 56)
                    .background(
                        selection == entry ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(selection == entry ? Color.accentColor : Color.secondary)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(entry.title)
                .accessibilityLabel(entry.title + (entry == .decisions && decisionsCount > 0 ? ", \(decisionsCount) need you" : ""))
                .accessibilityAddTraits(selection == entry ? .isSelected : [])
                .accessibilityIdentifier("nav.\(entry.title.lowercased())")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
    }

    private var countBadge: some View {
        Text(decisionsCount > 99 ? "99+" : "\(decisionsCount)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 16)
            .background(Color.red, in: Capsule())
            .offset(x: 8, y: -6)
    }
}
