import SwiftUI
import MatronDesignSystem
import MatronJournal

/// Top-level Mac navigation entries (app shell, spec §5), top to bottom.
/// The Coordinator is an entry here (its own page, ⌘1) —
/// and the only way to it. Memories (spec 2026-09-27 memories) is last so
/// ⌘1…⌘4 keep their entries. The user's pinned desk
/// chats (journal "Pinned desk chats") are `.desk` entries drawn under the
/// Coordinator, each a full-width page like the Coordinator's.
enum MacNav: Hashable {
    case coordinator
    case missions
    case decisions
    case conversations
    case memories
    /// A pinned desk chat's page, by its conversation id.
    case desk(String)

    /// The fixed entries, top to bottom (desks are drawn among them, under
    /// the Coordinator).
    static let allCases: [MacNav] = [.coordinator, .missions, .decisions, .conversations, .memories]

    var deskID: String? {
        if case .desk(let id) = self { return id }
        return nil
    }

    /// The Coordinator's page or a desk's: a chat across the full width.
    var isChatPage: Bool { self == .coordinator || deskID != nil }

    var title: String {
        switch self {
        case .coordinator: return "Coordinator"
        case .missions: return "Projects"
        case .decisions: return "For you"
        case .conversations: return "Conversations"
        case .memories: return "Memories"
        case .desk: return "Pinned chat"
        }
    }

    var symbol: String {
        switch self {
        case .coordinator: return "person.crop.circle.badge.checkmark"
        case .missions: return ProjectGlyph.symbol
        case .decisions: return "tray"
        case .conversations: return "bubble.left.and.bubble.right"
        case .memories: return "brain"
        case .desk: return "pin"
        }
    }
}

/// Fixed-width vertical column of large icons with labels beneath — the
/// Slack-workspace-switcher shape. Lives INSIDE the sidebar
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
    /// What needs the user on an entry — items it raised that await them —
    /// drawn as an orange count at the top-leading corner, opposite the red
    /// one. The Coordinator and the desks carry it.
    var needsYou: [MacNav: Int] = [:]
    /// The pinned desk chats, in the user's order, drawn under the
    /// Coordinator.
    var pins: [ConvoPin] = []
    /// The successor hint per pin id, for the entry's tooltip and menu.
    var successorHints: [String: String] = [:]
    /// A pin entry's menu.
    var onPinAction: ((MacPinAction) -> Void)? = nil

    static let width: CGFloat = 72

    /// The count to draw on an entry, or `nil` when there is nothing to
    /// show. Zero hides, as `UnreadBadge`/`NeedsYouBadge` do.
    static func badgeCount(_ badges: [MacNav: Int], for entry: MacNav) -> Int? {
        guard let n = badges[entry], n > 0 else { return nil }
        return n
    }

    /// The entries to draw. An old journal with no `/missions` routes hides
    /// the Missions entry entirely, matching the iOS tab.
    static func entries(missionsSupported: Bool, pins: [ConvoPin] = []) -> [MacNav] {
        let fixed = missionsSupported ? MacNav.allCases : MacNav.allCases.filter { $0 != .missions }
        return [.coordinator] + pins.map { .desk($0.convoID) } + fixed.filter { $0 != .coordinator }
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Self.entries(missionsSupported: missionsSupported, pins: pins), id: \.self) { entry in
                if let id = entry.deskID, let pin = pins.first(where: { $0.convoID == id }) {
                    pinEntry(pin)
                } else {
                    fixedEntry(entry)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
    }

    /// The accessibility label: the title, then what needs the user, then
    /// unread.
    static func accessibilityLabel(_ title: String, needsYou: Int?, count: Int?, hint: String? = nil) -> String {
        var label = title
        if let needsYou { label += ", \(needsYou) need you" }
        if let count { label += ", \(count) unread" }
        if let hint { label += ", \(hint)" }
        return label
    }

    private func fixedEntry(_ entry: MacNav) -> some View {
        let count = Self.badgeCount(badges, for: entry)
        let needs = Self.badgeCount(needsYou, for: entry)
        return Button { selection = entry } label: {
                    VStack(spacing: 4) {
                        Image(systemName: entry.symbol)
                            .font(.system(size: 22))
                            .frame(height: 28)
                            .overlay(alignment: .topTrailing) {
                                if let count {
                                    countBadge(count)
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                if let needs {
                                    countBadge(needs, color: .orange, leading: true)
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
                .accessibilityLabel(entry == .coordinator
                                    ? Self.accessibilityLabel(entry.title, needsYou: needs, count: count)
                                    : entry.title + (count.map { ", \($0) need you" } ?? ""))
                .accessibilityAddTraits(selection == entry ? .isSelected : [])
                .accessibilityIdentifier("nav.\(entry.title.lowercased())")
    }

    /// A pinned desk chat: its glyph, its label beneath (the full label in
    /// the tooltip), the same two badges, and a dot while it offers a
    /// successor. A missing pin is greyed out and opens its page's Move
    /// pin… / Unpin; its menu holds only those two.
    private func pinEntry(_ pin: ConvoPin) -> some View {
        let entry = MacNav.desk(pin.convoID)
        let count = pin.missing ? nil : Self.badgeCount(badges, for: entry)
        let needs = pin.missing ? nil : Self.badgeCount(needsYou, for: entry)
        let hint = pin.missing ? nil : successorHints[pin.convoID]
        let selected = selection == entry
        return Button { selection = entry } label: {
            VStack(spacing: 4) {
                PinGlyph(pin.glyph, size: 28, dimmed: pin.missing)
                    .overlay(alignment: .topTrailing) {
                        if let count {
                            countBadge(count)
                        } else if hint != nil {
                            Circle().fill(Color.accentColor).frame(width: 9, height: 9).offset(x: 4, y: -3)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let needs { countBadge(needs, color: .orange, leading: true) }
                    }
                Text(pin.label)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: Self.width - 12, height: 56)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(selected ? Color.accentColor : (pin.missing ? Color.secondary.opacity(0.6) : Color.secondary))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(hint.map { "\(pin.label) — \($0)" } ?? (pin.missing ? "\(pin.label) — conversation gone" : pin.label))
        .contextMenu {
            if let onPinAction {
                MacPinMenu(pin: pin, successorHint: hint, onAction: onPinAction)
            }
        }
        .accessibilityLabel(Self.accessibilityLabel(pin.label, needsYou: needs, count: count,
                                                    hint: pin.missing ? "conversation gone" : hint))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("nav.pin.\(pin.convoID)")
    }

    private func countBadge(_ count: Int, color: Color = .red, leading: Bool = false) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 16)
            .background(color, in: Capsule())
            .offset(x: leading ? -8 : 8, y: -6)
    }
}
