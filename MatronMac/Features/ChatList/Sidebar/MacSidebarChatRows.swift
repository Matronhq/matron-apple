import AppKit
import MatronChat
import MatronJournal
import MatronModels
import MatronViewModels

/// A menu item that runs a closure.
final class MacActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run(_:)), keyEquivalent: "")
        target = self
        self.state = state
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run(_ sender: Any?) { handler() }

    /// Runs the item's action (tests).
    func performForTesting() { handler() }
}

/// `MacConvoNotifyMenuItems` in AppKit: one conversation's notification
/// level (All / Needs me / None, or Default to follow the mode), its
/// running mute, and the mute choices. Same words and same writes through
/// `NotifySettingsStore`.
@MainActor
enum MacConvoNotifyNSMenu {
    static func items(store: NotifySettingsStore, convoID: String) -> [NSMenuItem] {
        let state = store.state(for: convoID)
        var items: [NSMenuItem] = []
        for level in NotifySettings.ConvoLevel.allCases {
            items.append(MacActionMenuItem(level.title, state: state.level == level ? .on : .off) {
                Task { await store.setLevel(level, convoID: convoID) }
            })
        }
        items.append(MacActionMenuItem(ConvoNotifyState.defaultLevelTitle, state: state.level == nil ? .on : .off) {
            Task { await store.setLevel(nil, convoID: convoID) }
        })
        items.append(.separator())
        if let mutedUntil = state.mutedUntil {
            items.append(MacActionMenuItem("Unmute (muted until \(ConvoNotifyState.time(mutedUntil)))") {
                Task { await store.unmute(convoID: convoID) }
            })
        }
        for duration in NotifyMuteDuration.allCases {
            items.append(MacActionMenuItem(duration.title) {
                Task { await store.mute(convoID: convoID, for: duration) }
            })
        }
        return items
    }

    /// The "Notifications" submenu item.
    static func submenuItem(store: NotifySettingsStore, convoID: String) -> NSMenuItem {
        let item = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Notifications")
        for child in items(store: store, convoID: convoID) { menu.addItem(child) }
        item.submenu = menu
        return item
    }
}

/// The AppKit sidebar's `MacListRows`: native `MacChatListCell` rows of a
/// fixed height, recency-group headers, one label per row for VoiceOver,
/// type-select by title, and the list's one context menu.
@MainActor
final class MacSidebarChatRows: MacListRows {
    var stallLabels: MacListStallLabels {
        MacListStallLabels(apply: "Sidebar.apply", pass: "Sidebar.pass", cell: "Sidebar.cell")
    }

    typealias Row = MacSidebarChat

    static let cellKind = MacListCellKind.native(MacChatListCell.identifier)
    /// The header row, as SwiftUI's sidebar draws it. The source-list table
    /// itself keeps 13 pt above every header but the first.
    static let headerHeight: CGFloat = 19

    /// What the rows do; set by the sidebar view on every update, since its
    /// closures capture bindings and settings that can change.
    struct Actions {
        /// Return, Enter or a double-click: open the first of `ids`.
        var open: ([String]) -> Void = { _ in }
        /// "Archive" on the whole selection.
        var archive: (Set<String>) -> Void = { _ in }
        /// "Pin to Sidebar…" on one conversation; `nil` draws no item.
        var pin: ((String) -> Void)?
        /// Each row's Notifications submenu; `nil` draws none.
        var notifyStore: NotifySettingsStore?
    }

    var actions = Actions()
    /// The clock the rows read their times from (tests pin it).
    var now: () -> Date = { Date() }

    init() {}

    var fixedRowHeight: CGFloat? { MacChatListCell.rowHeight }

    func cellKind(for row: MacSidebarChat) -> MacListCellKind { Self.cellKind }

    func makeCell(_ kind: MacListCellKind) -> NSTableCellView { MacChatListCell(frame: .zero) }

    func configure(_ cell: NSTableCellView, with row: MacSidebarChat) {
        (cell as? MacChatListCell)?.configure(row, now: now())
    }

    func height(for row: MacSidebarChat, width: CGFloat) -> CGFloat { MacChatListCell.rowHeight }

    func accessibilityLabel(for row: MacSidebarChat) -> String? {
        MacChatListCell.accessibilityLabel(for: row, now: now())
    }

    func typeSelectString(for row: MacSidebarChat) -> String? { row.summary.title }

    func sectionHeaderTitle(_ key: String) -> String? { ChatRecencyGroup(rawValue: key)?.rawValue }

    func sectionHeaderHeight(_ key: String) -> CGFloat { Self.headerHeight }

    /// Where SwiftUI's sidebar section header sets its title.
    var sectionHeaderInsets: (leading: CGFloat, bottom: CGFloat) { (15, 2) }

    /// The sidebar's right-click menu: the Notifications submenu and "Pin to
    /// Sidebar…" for one conversation, then Archive for all of `ids`.
    func menuItems(for ids: [String]) -> [NSMenuItem] {
        guard !ids.isEmpty else { return [] }
        var items: [NSMenuItem] = []
        if ids.count == 1, let id = ids.first {
            if let store = actions.notifyStore {
                items.append(MacConvoNotifyNSMenu.submenuItem(store: store, convoID: id))
            }
            if let pin = actions.pin {
                items.append(MacActionMenuItem("Pin to Sidebar…") { pin(id) })
            }
        }
        let archive = actions.archive
        let set = Set(ids)
        items.append(MacActionMenuItem(ids.count > 1 ? "Archive \(ids.count) Conversations" : "Archive") {
            archive(set)
        })
        return items
    }

    func activate(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        actions.open(ids)
    }
}

/// How the sidebar list's selection (several rows, for Archive) and the
/// window's selected conversation (one, or none) follow each other.
enum MacSidebarSelection {
    /// The window's conversation once the list's selection is `list`: the
    /// one row selected, none for none, and unchanged while several are
    /// selected (the detail keeps the chat it shows).
    static func window(after list: Set<String>, current: String?) -> String? {
        switch list.count {
        case 0: return nil
        case 1: return list.first
        default: return current
        }
    }

    /// The list's selection once the window's conversation is `window`:
    /// unchanged when the list already shows exactly it (the echo of the
    /// list's own change), else that one row, or none.
    static func list(after window: String?, current: Set<String>) -> Set<String> {
        guard let window else { return [] }
        return current == [window] ? current : [window]
    }
}
