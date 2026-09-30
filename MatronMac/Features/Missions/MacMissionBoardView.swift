import SwiftUI
import MatronDesignSystem
import MatronModels

/// The Board: the mission's items (never its sessions) in To do / In
/// progress / Done — `MissionBoard.assemble` decides which card goes where.
/// A card click opens the item where every item opens on the Mac.
struct MacMissionBoardView: View {
    let model: MacMissionPageModel
    let onOpenItem: (String) -> Void
    /// Asks the host for at least this many closed items (Show more past
    /// what is loaded).
    var onLoadClosedItems: (Int) -> Void = { _ in }
    /// How many Done cards show; "Show more" adds a page. The host keys the
    /// page on the mission id, so a different mission starts from one page.
    @State private var doneLimit = MissionBoard.donePageSize

    private var board: MissionBoard {
        MissionBoard.assemble(open: model.openItems, closed: model.closedItems,
                              closedTotal: model.closedItemsTotal, doneLimit: doneLimit)
    }

    var body: some View {
        let board = board
        HStack(alignment: .top, spacing: 16) {
            ForEach(MissionBoard.Column.allCases, id: \.self) { column in
                columnView(column, board: board)
            }
        }
        // Columns size to their content, then all take the tallest one's
        // height (`maxHeight: .infinity` below), as a kanban reads.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func columnView(_ column: MissionBoard.Column, board: MissionBoard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(MacMissionPalette.columnTint(column)).frame(width: 9, height: 9)
                Text("\(column.title.uppercased()) \(board.count(of: column))")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            let items = board.items(in: column)
            if items.isEmpty {
                Text(column == .done && board.isDoneLoading ? "Loading…" : emptyText(column)).font(.system(size: 14)).foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            }
            ForEach(items) { item in
                Button { onOpenItem(item.id) } label: {
                    MacMissionBoardCard(item: item, boxName: model.boxName(item.originConvoID))
                }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("missionBoard.card.\(item.num)")
            }
            if column == .done, board.showsMoreDone {
                Button("Show more (\(board.moreDone))") {
                    doneLimit += MissionBoard.donePageSize
                    onLoadClosedItems(doneLimit)
                }
                    .buttonStyle(.link)
                    .font(.system(size: 14))
                    .accessibilityIdentifier("missionBoard.showMore")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }

    private func emptyText(_ column: MissionBoard.Column) -> String {
        switch column {
        case .toDo: return "Nothing waiting."
        case .inProgress: return "Nothing in progress."
        case .done: return "Nothing closed yet."
        }
    }
}

/// One board card: kind pill, title (two lines at most), meta line. A card
/// that needs you is tinted red; a closed one is quieter, a cancelled one
/// quieter still.
struct MacMissionBoardCard: View {
    let item: TrackerItem
    let boxName: String?
    @Environment(\.macMissionPageClock) private var fixedNow

    private var needsYou: Bool { item.state == .open && item.awaiting == .user }
    private var isClosed: Bool { item.state == .closed }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacItemKindPill(kind: item.kind)
            Text(item.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isClosed ? Color.secondary : Color.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            MacMinuteText { MissionBoard.meta(for: item, boxName: boxName, now: $0) }
                .font(.system(size: 14))
                .foregroundStyle(needsYou ? Color.red : Color.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(needsYou ? Color.red.opacity(0.06) : MacMissionPalette.cardBackground,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(needsYou ? Color.red.opacity(0.25) : Color.primary.opacity(0.10)))
        .opacity(item.resolution == .cancelled ? 0.55 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ItemGlyph.label(item.kind)): \(item.title), "
                            + MissionBoard.meta(for: item, boxName: boxName, now: fixedNow ?? Date()))
    }
}
