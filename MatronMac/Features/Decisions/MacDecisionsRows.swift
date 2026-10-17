import AppKit
import MatronModels

/// The AppKit For you list's `MacListRows`: native `MacItemRowCell` rows
/// whose heights come from their layout, the Done tab's "Show more" row,
/// one label per row for VoiceOver, type-select by title, and the rows'
/// context menu (Seen, Open conversation).
@MainActor
final class MacDecisionsRows: MacListRows {
    typealias Row = MacDecisionsRow

    static let itemKind = MacListCellKind.native(MacItemRowCell.identifier)
    static let showMoreKind = MacListCellKind.native(MacDecisionsShowMoreCell.identifier)

    /// What the rows do; set by the list view on every update, since its
    /// closures capture the view model and the window's navigation.
    struct Actions {
        /// Return, Enter or a double-click on an item: open it.
        var open: (String) -> Void = { _ in }
        var openConversation: (String) -> Void = { _ in }
        var seen: (String) -> Void = { _ in }
        var showMore: () -> Void = {}
    }

    var actions = Actions()
    /// The clock the Done rows' captions read (tests pin it).
    var now: () -> Date = { Date() }

    /// The shown rows' items by id, and whether they are on the Done tab,
    /// for the menu (which is given ids). Filled as rows are configured,
    /// which every row the menu can be opened on has been.
    private var itemsByID: [String: (item: TrackerItem, isClosedTab: Bool)] = [:]

    init() {}

    func cellKind(for row: MacDecisionsRow) -> MacListCellKind {
        row.item == nil ? Self.showMoreKind : Self.itemKind
    }

    func makeCell(_ kind: MacListCellKind) -> NSTableCellView {
        kind == Self.showMoreKind ? MacDecisionsShowMoreCell(frame: .zero) : MacItemRowCell(frame: .zero)
    }

    func configure(_ cell: NSTableCellView, with row: MacDecisionsRow) {
        switch row.content {
        case .item(let item, let origin, let isClosedTab):
            itemsByID[item.id] = (item, isClosedTab)
            guard let cell = cell as? MacItemRowCell else { return }
            cell.configure(item, origin: origin, isClosedTab: isClosedTab, now: now())
            let seen = actions.seen
            cell.onSeen = { seen(item.id) }
        case .showMore:
            (cell as? MacDecisionsShowMoreCell)?.onShowMore = actions.showMore
        }
    }

    func height(for row: MacDecisionsRow, width: CGFloat) -> CGFloat {
        switch row.content {
        case .item(let item, let origin, let isClosedTab):
            MacItemRowCell.height(for: item, origin: origin, isClosedTab: isClosedTab, width: width)
        case .showMore:
            MacDecisionsShowMoreCell.rowHeight
        }
    }

    func accessibilityLabel(for row: MacDecisionsRow) -> String? {
        switch row.content {
        case .item(let item, let origin, let isClosedTab):
            MacItemRowCell.accessibilityLabel(for: item, origin: origin, isClosedTab: isClosedTab, now: now())
        case .showMore:
            nil
        }
    }

    func typeSelectString(for row: MacDecisionsRow) -> String? { row.item?.title }

    /// `DecisionsListView`'s row menu, for the clicked row: Seen on a
    /// notice that offers it (the Needs you tab only), then Open
    /// conversation.
    func menuItems(for ids: [String]) -> [NSMenuItem] {
        guard let id = ids.first, let (item, isClosedTab) = itemsByID[id] else { return [] }
        var items: [NSMenuItem] = []
        if !isClosedTab && item.offersSeen {
            let seen = actions.seen
            items.append(MacActionMenuItem(TrackerItem.seenAction) { seen(id) })
        }
        let openConversation = actions.openConversation
        let origin = item.originConvoID
        items.append(MacActionMenuItem("Open conversation") { openConversation(origin) })
        return items
    }

    func activate(_ ids: [String]) {
        guard let id = ids.first else { return }
        if id == MacDecisionsRow.showMoreID {
            actions.showMore()
        } else {
            actions.open(id)
        }
    }
}
