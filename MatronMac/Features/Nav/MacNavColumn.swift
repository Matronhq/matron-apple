import SwiftUI

/// Top-level Mac navigation entries (app shell, spec §5), top to bottom.
enum MacNav: Hashable, CaseIterable {
    case coordinator
    case missions
    case decisions
    case conversations

    var title: String {
        switch self {
        case .coordinator: return "Coordinator"
        case .missions: return "Missions"
        case .decisions: return "Decisions"
        case .conversations: return "Conversations"
        }
    }

    var symbol: String {
        switch self {
        case .coordinator: return "person.crop.circle.badge.checkmark"
        case .missions: return "flag.checkered"
        case .decisions: return "checkmark.circle"
        case .conversations: return "bubble.left.and.bubble.right"
        }
    }
}

/// Fixed-width vertical column of large icons with labels beneath — the
/// Slack-workspace-switcher shape Dan asked for. Lives INSIDE the sidebar
/// column of `MacChatListView`'s split view (so the sidebar's material and
/// `navigationSplitViewColumnWidth` still apply) and is never collapsible.
/// Any entry in `badges` carries a red count badge at its top-trailing
/// corner, hidden at zero (generalises the old single `decisionsCount`,
/// which only ever covered Decisions — Missions has its own "needs you"
/// total now too).
struct MacNavColumn: View {
    @Binding var selection: MacNav
    let badges: [MacNav: Int]
    /// Whether the signed-in journal supports `/missions` at all. `false`
    /// hides the Missions entry entirely rather than showing a permanently
    /// empty one — matches the iOS tab.
    var missionsSupported: Bool = true

    static let width: CGFloat = 72

    /// The count to draw on an entry, or `nil` when there is nothing to
    /// show. Zero hides, as `UnreadBadge`/`NeedsYouBadge` do.
    static func badgeCount(_ badges: [MacNav: Int], for entry: MacNav) -> Int? {
        guard let n = badges[entry], n > 0 else { return nil }
        return n
    }

    /// The entries to draw. An old journal with no `/missions` routes hides
    /// the Missions entry entirely, matching the iOS tab.
    static func entries(missionsSupported: Bool) -> [MacNav] {
        missionsSupported ? MacNav.allCases : MacNav.allCases.filter { $0 != .missions }
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Self.entries(missionsSupported: missionsSupported), id: \.self) { entry in
                let count = Self.badgeCount(badges, for: entry)
                Button { selection = entry } label: {
                    VStack(spacing: 4) {
                        Image(systemName: entry.symbol)
                            .font(.system(size: 22))
                            .frame(height: 28)
                            .overlay(alignment: .topTrailing) {
                                if let count {
                                    countBadge(count)
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
                .accessibilityLabel(entry.title + (count.map { ", \($0) need you" } ?? ""))
                .accessibilityAddTraits(selection == entry ? .isSelected : [])
                .accessibilityIdentifier("nav.\(entry.title.lowercased())")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
    }

    private func countBadge(_ count: Int) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 16)
            .background(Color.red, in: Capsule())
            .offset(x: 8, y: -6)
    }
}
