#if os(macOS)
import XCTest
import AppKit
@testable import MatronMac
import MatronChat
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels

/// `MacChatListCell` and `MacSidebarChatRows`: what each row state draws
/// and reads to VoiceOver, where its parts go, and the context menu.
@MainActor
final class MacChatListCellTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func row(_ id: String = "c1", title: String = "Quarterly planning notes", ago: TimeInterval? = 300,
             snippet: String = "Drafted the agenda", unread: Int = 0, needs: Int = 0, silenced: Bool = false,
             new: Bool = false, box: (String, String)? = nil, short: String? = nil,
             room: [(String, String)] = []) -> MacSidebarChat {
        let summary = MacSidebarFixtures.summary(id, title, ago: ago, from: now, snippet: snippet, unread: unread,
                                                 needs: needs, box: box.map { (name: $0.0, letter: $0.1) },
                                                 short: short, room: room.map { (name: $0.0, letter: $0.1) })
        return MacSidebarChat(summary: summary, group: MacRecencyBuckets(now: now).bucket(summary.lastActivity),
                              isSilenced: silenced, isNew: new)
    }

    // MARK: Lines

    /// Laying a row out and then drawing it shapes each string once: the
    /// same text at the same width is the same line, in any appearance it
    /// was asked in.
    func test_line_isShapedOncePerTextWidthAndAppearance() {
        let text = MacChatListCell.detailString("Drafted the agenda", color: .secondaryLabelColor)
        var first: CTLine?, again: CTLine?, narrower: CTLine?, dark: CTLine?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            first = MacChatListCell.line(text, in: 120)
            again = MacChatListCell.line(NSAttributedString(attributedString: text), in: 120)
            narrower = MacChatListCell.line(text, in: 60)
        }
        XCTAssertTrue(first === again)
        XCTAssertFalse(first === narrower)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            dark = MacChatListCell.line(text, in: 120)
        }
        XCTAssertFalse(first === dark)
    }

    // MARK: Configuration

    func test_configure_showsTheRowAndItsTime_andIsIdempotent() {
        let cell = MacChatListCell(frame: NSRect(x: 0, y: 0, width: 248, height: MacChatListCell.rowHeight))
        let plain = row()
        XCTAssertTrue(cell.configure(plain, now: now))
        XCTAssertEqual(cell.row, plain)
        XCTAssertEqual(cell.timeText, "5m")
        XCTAssertFalse(cell.configure(plain, now: now), "an unchanged row and time draw nothing")
        XCTAssertTrue(cell.configure(plain, now: now.addingTimeInterval(60)), "the minute tick redraws a new time")
        XCTAssertEqual(cell.timeText, "6m")
        XCTAssertFalse(cell.configure(plain, now: now.addingTimeInterval(61)), "same minute, same text")
        XCTAssertTrue(cell.configure(row(unread: 3), now: now.addingTimeInterval(61)))
    }

    func test_configure_noActivity_hasNoTime() {
        let cell = MacChatListCell(frame: .zero)
        cell.configure(row(ago: nil), now: now)
        XCTAssertNil(cell.timeText)
    }

    func test_reuse_dropsTheHover() {
        let cell = MacChatListCell(frame: .zero)
        cell.setHoveredForTesting(true)
        XCTAssertTrue(cell.isHovered)
        cell.prepareForReuse()
        XCTAssertFalse(cell.isHovered)
    }

    func test_badges_forEveryRowState_inMacChatRowsOrder() {
        XCTAssertEqual(MacChatListCell.badges(for: row()), [])
        XCTAssertEqual(MacChatListCell.badges(for: row(unread: 2)), [.unread("2")])
        XCTAssertEqual(MacChatListCell.badges(for: row(needs: 1)), [.needsYou("1")])
        XCTAssertEqual(MacChatListCell.badges(for: row(silenced: true)), [.silenced])
        XCTAssertEqual(MacChatListCell.badges(for: row(new: true)), [.new])
        XCTAssertEqual(MacChatListCell.badges(for: row(unread: 120, needs: 100, silenced: true, new: true)),
                       [.silenced, .new, .needsYou("99+"), .unread("99+")])
    }

    func test_titleLine_tagsAndTitle() {
        func text(_ row: MacSidebarChat) -> String {
            MacChatListCell.titleString(for: row.summary, isDark: false, primary: .labelColor,
                                        secondary: .secondaryLabelColor).string
        }
        XCTAssertEqual(text(row()), "Quarterly planning notes")
        XCTAssertEqual(text(row(box: ("box-a", "A"), short: "k3")), "A:k3 Quarterly planning notes")
        XCTAssertEqual(text(row(short: "k3")), "k3 Quarterly planning notes", "no letter without two boxes")
        XCTAssertEqual(text(row(short: "r9", room: [("box-a", "A"), ("box-b", "B")])),
                       "A↔B:r9 Quarterly planning notes")
        XCTAssertEqual(text(row(short: "r9", room: [("box-a", "A"), ("box-b", "B"), ("box-c", "C")])),
                       "A,B,C:r9 Quarterly planning notes")
    }

    func test_titleLine_colorsTheBoxLetterWithItsHue() {
        let line = MacChatListCell.titleString(for: row(box: ("box-a", "A"), short: "k3").summary, isDark: true,
                                               primary: .labelColor, secondary: .secondaryLabelColor)
        let letter = line.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(letter, MacChatListCell.tint(for: "box-a", .dark))
        XCTAssertEqual(line.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, MacChatListCell.Fonts.titleTag)
        let separator = line.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        XCTAssertEqual(separator, .secondaryLabelColor)
        let title = line.attribute(.foregroundColor, at: line.length - 1, effectiveRange: nil) as? NSColor
        XCTAssertEqual(title, .labelColor)
    }

    // MARK: Layout

    func layout(_ row: MacSidebarChat, width: CGFloat = 248) -> MacChatListCell.Layout {
        let title = MacChatListCell.titleString(for: row.summary, isDark: false, primary: .labelColor,
                                                secondary: .secondaryLabelColor)
        let time = row.summary.lastActivity.map { RelativeMinuteTimeView.format($0, now: now) }
        return MacChatListCell.layout(for: row, time: time, title: title,
                                      in: NSSize(width: width, height: MacChatListCell.rowHeight))
    }

    func test_layout_linesAndBadges_sitWhereMacChatRowPutsThem() {
        let l = layout(row(snippet: "A long snippet that will not fit beside the badges at all", unread: 2, needs: 1,
                           silenced: true, new: true))
        // Content block: 43 pt centred in the 51 pt row; lines at 4 and 23.
        XCTAssertEqual(l.hover, NSRect(x: 0, y: 4, width: 248, height: 43))
        XCTAssertEqual(l.title.minY, 8)
        XCTAssertEqual(l.snippet?.minY, 27)
        XCTAssertEqual(l.title.minX, 4)
        // Badges right-aligned at the padding, 4 pt apart, in order.
        XCTAssertEqual(l.badges.map(\.kind), [.silenced, .new, .needsYou("1"), .unread("2")])
        XCTAssertEqual(l.badges.last?.frame.maxX, 244)
        for (a, b) in zip(l.badges, l.badges.dropFirst()) { XCTAssertEqual(b.frame.minX - a.frame.maxX, 4) }
        for badge in l.badges where badge.kind != .silenced { XCTAssertEqual(badge.frame.height, 17) }
        let unreadWidth = l.badges.last?.frame.width ?? 0
        XCTAssertTrue((18...19).contains(unreadWidth), "one digit keeps about the minimum width: \(unreadWidth)")
        // The text stops 16 pt before the badges (the HStack's spacing,
        // either side of the spacer).
        let textRight = l.badges[0].frame.minX - 16
        XCTAssertLessThanOrEqual(l.title.maxX, textRight)
        XCTAssertLessThanOrEqual(l.time!.maxX, textRight)
        // The time follows the truncated snippet and its `·`, 4 pt apart.
        XCTAssertEqual(l.dot!.minX - l.snippet!.maxX, 4)
        XCTAssertEqual(l.time!.minX - l.dot!.maxX, 4)
    }

    func test_layout_emptySnippet_keepsASpace_andDropsTheDot() {
        let l = layout(row(snippet: ""))
        XCTAssertNil(l.dot)
        XCTAssertNotNil(l.snippet)
        XCTAssertGreaterThan(l.time!.minX, l.snippet!.minX + 4, "the space SwiftUI lays out comes first")
    }

    func test_layout_noActivity_hasOnlyTheSnippet() {
        let l = layout(row(ago: nil))
        XCTAssertNil(l.time)
        XCTAssertNil(l.dot)
        XCTAssertNotNil(l.snippet)
    }

    func test_layout_narrowRow_neverOverlapsTheBadges() {
        let l = layout(row(title: String(repeating: "Very long title ", count: 8), unread: 120), width: 140)
        XCTAssertLessThanOrEqual(l.title.maxX, l.badges[0].frame.minX - 16)
        XCTAssertGreaterThanOrEqual(l.title.width, 0)
    }

    // MARK: Accessibility

    func test_accessibilityLabel_forEveryRowState() {
        XCTAssertEqual(MacChatListCell.accessibilityLabel(for: row(), now: now),
                       "Quarterly planning notes, Drafted the agenda, 5 minutes ago")
        XCTAssertEqual(MacChatListCell.accessibilityLabel(for: row(unread: 2, needs: 1), now: now),
                       "Quarterly planning notes, Drafted the agenda, 2 unread, 1 needs you, 5 minutes ago")
        XCTAssertEqual(MacChatListCell.accessibilityLabel(for: row(snippet: "", silenced: true, new: true), now: now),
                       "Quarterly planning notes, notifications off, new session, 5 minutes ago")
        XCTAssertEqual(MacChatListCell.accessibilityLabel(for: row(ago: nil), now: now),
                       "Quarterly planning notes, Drafted the agenda")
        XCTAssertEqual(MacChatListCell.accessibilityLabel(for: row(box: ("box-a", "A"), short: "k3"), now: now),
                       "box-a, session k3, Quarterly planning notes, Drafted the agenda, 5 minutes ago")
        XCTAssertEqual(MacChatListCell.accessibilityLabel(
            for: row(short: "r9", room: [("box-a", "A"), ("box-b", "B")]), now: now),
            "box-a and box-b, session r9, Quarterly planning notes, Drafted the agenda, 5 minutes ago")
    }

    func test_spokenTime_isTheShownTimeInWords() {
        XCTAssertEqual(MacChatListCell.spokenTime(now.addingTimeInterval(-20), now: now), "now")
        XCTAssertEqual(MacChatListCell.spokenTime(now.addingTimeInterval(-60), now: now), "1 minute ago")
        XCTAssertEqual(MacChatListCell.spokenTime(now.addingTimeInterval(-300), now: now), "5 minutes ago")
        XCTAssertEqual(MacChatListCell.spokenTime(now.addingTimeInterval(-3600), now: now), "1 hour ago")
        XCTAssertEqual(MacChatListCell.spokenTime(now.addingTimeInterval(-3 * 86400), now: now), "3 days ago")
        let old = now.addingTimeInterval(-30 * 86400)
        XCTAssertEqual(MacChatListCell.spokenTime(old, now: now), RelativeMinuteTimeView.format(old, now: now))
    }

    // MARK: Rows provider

    func test_rows_fixedHeight_headers_typeSelect_andLabel() {
        let rows = MacSidebarChatRows()
        rows.now = { self.now }
        XCTAssertEqual(rows.fixedRowHeight, 51)
        XCTAssertEqual(rows.sectionHeaderHeight("Today"), 19)
        XCTAssertEqual(rows.sectionHeaderTitle("Yesterday"), "Yesterday")
        XCTAssertEqual(rows.sectionHeaderTitle("No recent activity"), "No recent activity")
        XCTAssertNil(rows.sectionHeaderTitle("bogus"))
        XCTAssertEqual(rows.sectionHeaderInsets.leading, 15)
        let shown = row(box: ("box-a", "A"), short: "k3")
        XCTAssertEqual(rows.typeSelectString(for: shown), "Quarterly planning notes", "by title, without the tag")
        XCTAssertEqual(rows.accessibilityLabel(for: shown),
                       MacChatListCell.accessibilityLabel(for: shown, now: now))
        XCTAssertEqual(rows.cellKind(for: shown), MacSidebarChatRows.cellKind)
        let cell = rows.makeCell(MacSidebarChatRows.cellKind)
        rows.configure(cell, with: shown)
        XCTAssertEqual((cell as? MacChatListCell)?.row, shown)
    }

    func test_menu_oneConversation_hasNotificationsPinAndArchive() {
        let rows = MacSidebarChatRows()
        var pinned: [String] = []
        var archived: [Set<String>] = []
        rows.actions = .init(archive: { archived.append($0) }, pin: { pinned.append($0) },
                             notifyStore: Self.notifyStore())
        let items = rows.menuItems(for: ["c1"])
        XCTAssertEqual(items.map(\.title), ["Notifications", "Pin to Sidebar…", "Archive"])
        (items[1] as? MacActionMenuItem)?.performForTesting()
        (items[2] as? MacActionMenuItem)?.performForTesting()
        XCTAssertEqual(pinned, ["c1"])
        XCTAssertEqual(archived, [["c1"]])
    }

    func test_menu_selection_archivesAllOfIt_andOffersNoSingleConversationItems() {
        let rows = MacSidebarChatRows()
        var archived: [Set<String>] = []
        rows.actions = .init(archive: { archived.append($0) }, pin: { _ in }, notifyStore: Self.notifyStore())
        let items = rows.menuItems(for: ["c1", "c4", "c7"])
        XCTAssertEqual(items.map(\.title), ["Archive 3 Conversations"])
        (items[0] as? MacActionMenuItem)?.performForTesting()
        XCTAssertEqual(archived, [["c1", "c4", "c7"]])
        XCTAssertEqual(rows.menuItems(for: []).count, 0)
    }

    func test_menu_withoutPinOrNotifications_isArchiveAlone() {
        let rows = MacSidebarChatRows()
        XCTAssertEqual(rows.menuItems(for: ["c1"]).map(\.title), ["Archive"])
    }

    func test_activate_opensTheFirst() {
        let rows = MacSidebarChatRows()
        var opened: [[String]] = []
        rows.actions = .init(open: { opened.append($0) })
        rows.activate(["c2", "c3"])
        rows.activate([])
        XCTAssertEqual(opened, [["c2", "c3"]])
    }

    // MARK: Notifications submenu

    static func notifyStore(_ convos: [NotifySettings.ConvoOverride] = []) -> NotifySettingsStore {
        let api = SidebarFakeNotifyAPI(stored: NotifyView(
            settings: NotifySettings(mode: .coordinator, events: NotifySettings.preset(.coordinator) ?? [:],
                                     hasCoordinator: true, convos: convos),
            deviceLevel: .all))
        return NotifySettingsStore(api: api, updates: { AsyncStream { _ in } },
                                   connectionStates: { AsyncStream { _ in } })
    }

    func test_notificationsSubmenu_matchesTheSwiftUIMenu_andWritesThroughTheStore() async throws {
        let until = Date().addingTimeInterval(3600)
        let store = Self.notifyStore([NotifySettings.ConvoOverride(convoID: "c1", level: .silent, muteUntil: until)])
        await store.refresh()
        let items = MacConvoNotifyNSMenu.items(store: store, convoID: "c1")
        let titles = items.map { $0.isSeparatorItem ? "—" : $0.title }
        XCTAssertEqual(titles, NotifySettings.ConvoLevel.allCases.map(\.title)
            + [ConvoNotifyState.defaultLevelTitle, "—", "Unmute (muted until \(ConvoNotifyState.time(until)))"]
            + NotifyMuteDuration.allCases.map(\.title))
        let checked = items.filter { $0.state == .on }.map(\.title)
        XCTAssertEqual(checked, [NotifySettings.ConvoLevel.silent.title])

        // Another conversation: Default checked, no Unmute.
        let other = MacConvoNotifyNSMenu.items(store: store, convoID: "c2")
        XCTAssertEqual(other.filter { $0.state == .on }.map(\.title), [ConvoNotifyState.defaultLevelTitle])
        XCTAssertFalse(other.contains { $0.title.hasPrefix("Unmute") })

        // Picking a level writes it.
        let needsMe = try XCTUnwrap(items.first { $0.title == NotifySettings.ConvoLevel.needsMe.title }
            as? MacActionMenuItem)
        needsMe.performForTesting()
        for _ in 0..<100 where store.state(for: "c1").level != .needsMe { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.state(for: "c1").level, .needsMe)

        let submenu = MacConvoNotifyNSMenu.submenuItem(store: store, convoID: "c1")
        XCTAssertEqual(submenu.title, "Notifications")
        XCTAssertEqual(submenu.submenu?.items.count, items.count)
    }
}

/// Answers `GET /notify` with `stored` and applies each change to it.
final class SidebarFakeNotifyAPI: NotifySettingsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NotifyView

    init(stored: NotifyView) { self.stored = stored }

    func notifySettings() async throws -> NotifyView { lock.withLock { stored } }

    func updateNotify(_ change: NotifyChange) async throws -> NotifyView {
        lock.withLock {
            stored = change.applied(to: stored)
            return stored
        }
    }
}
#endif
