#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import MatronMac
import MatronDesignSystem
import MatronModels

/// Made-up For you rows covering every state an item row draws: each kind,
/// a two-line title, a body line, the mission chip, comments, a consent
/// ask (and one answered from its row), a notice offering "Seen", an
/// image, an item with the agent, and
/// closed ones with their "Answered · 2h ago" captions.
enum MacDecisionsFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func open() -> [TrackerItem] {
        [
            TrackerItem(id: "i1", num: 412, kind: .question, awaiting: .user, title: "Ship the new onboarding flow?",
                        body: "Two options: the short tour or the checklist. I recommend the checklist.",
                        originConvoID: "c1", updatedAt: now.addingTimeInterval(-300), commentCount: 3,
                        missionNum: 61),
            TrackerItem(id: "i2", num: 415, kind: .notice, awaiting: .user, title: "Nightly backup finished with warnings",
                        body: "Three files were skipped because they were open.", originConvoID: "c2",
                        updatedAt: now.addingTimeInterval(-900), actions: [TrackerItem.seenAction]),
            TrackerItem(id: "i3", num: 418, kind: .question, awaiting: .user,
                        title: "Which of the three venue options should we book for the spring offsite next year?",
                        originConvoID: "c3", updatedAt: now.addingTimeInterval(-1800)),
            TrackerItem(id: "i4", num: 420, kind: .question, awaiting: .user, title: "Start a session on the build box?",
                        links: [TrackerLink(url: "matron://consent/spawn/req-1")], originConvoID: "c1",
                        updatedAt: now.addingTimeInterval(-3600)),
            TrackerItem(id: "i5", num: 423, kind: .notice, awaiting: .user, title: "Screenshot of the settings page",
                        originConvoID: "c4", updatedAt: now.addingTimeInterval(-7200), hasImage: true),
            TrackerItem(id: "i6", num: 427, kind: .decision, awaiting: .user, title: "Use the quarterly plan format",
                        body: "Recorded so the team can review it.", originConvoID: "c2",
                        updatedAt: now.addingTimeInterval(-10800), commentCount: 12, missionNum: 7),
            TrackerItem(id: "i7", num: 430, kind: .question, awaiting: .user, title: "box-b asks to chat with box-a",
                        labels: ["consent"], links: [TrackerLink(url: "matron://consent/chat/room-1/4")],
                        originConvoID: "c2", updatedAt: now.addingTimeInterval(-14400),
                        actions: ["Approve", "Decline"]),
        ]
    }

    static func closed() -> [TrackerItem] {
        [
            TrackerItem(id: "d1", num: 401, kind: .question, state: .closed, resolution: .answered,
                        title: "Rename the reports folder?", originConvoID: "c1", closedAt: now.addingTimeInterval(-7200),
                        lastUserInputAt: now.addingTimeInterval(-7200)),
            TrackerItem(id: "d2", num: 398, kind: .decision, state: .closed, resolution: .decided,
                        title: "Keep the weekly summary on Fridays", body: "Moved from Mondays.", originConvoID: "c2",
                        closedAt: now.addingTimeInterval(-86400 * 2), commentCount: 1, missionNum: 61,
                        lastUserInputAt: now.addingTimeInterval(-86400 * 2)),
            TrackerItem(id: "d3", num: 395, kind: .question, awaiting: .agent, title: "Draft the newsletter intro",
                        originConvoID: "c3", createdBy: .agent, lastUserInputAt: now.addingTimeInterval(-86400 * 3)),
            TrackerItem(id: "d4", num: 390, kind: .notice, state: .closed, resolution: .done,
                        title: "Disk clean-up report", originConvoID: "c4", closedAt: now.addingTimeInterval(-86400 * 5),
                        lastUserInputAt: now.addingTimeInterval(-86400 * 5)),
        ]
    }

    static let origins: [String: String] = [
        "c1": "Product planning", "c2": "Ops desk", "c3": "Events", "c4": "Settings polish",
    ]

    static func origin(_ item: TrackerItem) -> String { origins[item.originConvoID] ?? "Another chat" }

    static func rows(_ items: [TrackerItem], closed: Bool, hasMore: Bool = false) -> [MacDecisionsRow] {
        items.map { MacDecisionsRow(item: $0, origin: origin($0), isClosedTab: closed) }
            + (hasMore ? [.showMore] : [])
    }

    static func publication(_ rows: [MacDecisionsRow]) -> ListPublication<MacDecisionsRow, String> {
        ListPublication(update: .reset([ListSection(key: "rows", ids: rows.map(\.id))]), rows: rows)
    }
}

/// One For you list rendered off-screen, as `MacSidebarRender` does for
/// the sidebar.
@MainActor
enum MacDecisionsRender {
    /// Today's SwiftUI list (`DecisionsListView`).
    static func swiftUI(open: Bool, appearance: NSAppearance.Name, size: NSSize,
                        pixelScale: CGFloat = 0) -> MacSidebarRender {
        let model = DecisionsListView.Model(
            rows: open ? MacDecisionsFixtures.open().map { .init(item: $0, originTitle: MacDecisionsFixtures.origin($0)) } : [],
            closed: open ? [] : MacDecisionsFixtures.closed().map { .init(item: $0, originTitle: MacDecisionsFixtures.origin($0)) },
            closedTotalCount: open ? 0 : 60, tab: open ? .open : .closed, hasMoreClosed: !open,
            isSupported: true, isRefreshing: false)
        let view = DecisionsListView(model: model, onSelect: { _ in }, onOpenConversation: { _ in }, onRefresh: {},
                                     now: MacDecisionsFixtures.now)
        let host = NSHostingView(rootView: view)
        let window = MacSidebarRender.window(size: size, appearance: appearance, content: host)
        defer { window.close() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        let table = MacSidebarRender.findTable(in: host)!
        return MacSidebarRender.capture(window, table: table, pixelScale: pixelScale)
    }
}

extension MacDecisionsRender {
    /// The AppKit list (`MacDecisionsAppKitList`'s host) on the same rows,
    /// without the header and tabs above it.
    static func appKit(open: Bool, appearance: NSAppearance.Name, size: NSSize,
                       pixelScale: CGFloat = 0) -> MacSidebarRender {
        let rows = MacDecisionsRows()
        rows.now = { MacDecisionsFixtures.now }
        let host = MacListHost(rows: rows, style: .plain,
                               accessibilityIdentifier: MacDecisionsAppKitList.accessibilityIdentifier)
        let window = MacSidebarRender.window(size: size, appearance: appearance, content: host.view)
        defer { window.close() }
        host.scrollView.scrollerStyle = .overlay
        let fixtureRows = open ? MacDecisionsFixtures.rows(MacDecisionsFixtures.open(), closed: false)
            : MacDecisionsFixtures.rows(MacDecisionsFixtures.closed(), closed: true, hasMore: true)
        host.apply(MacDecisionsFixtures.publication(fixtureRows))
        host.flushPendingUpdates()
        window.contentView?.layoutSubtreeIfNeeded()
        host.tableView.layoutSubtreeIfNeeded()
        return MacSidebarRender.capture(window, table: host.tableView, pixelScale: pixelScale)
    }
}

/// Writes renders under `$HOME/Dev/shots-decisions` when
/// `MATRON_DECISIONS_SHOTS` is set (for a pull request's screenshots);
/// skipped otherwise.
@MainActor
final class MacDecisionsRenderHarness: XCTestCase {
    func test_writeRenders() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MATRON_DECISIONS_SHOTS"] != nil)
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Dev/shots-decisions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = NSSize(width: 380, height: 520)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for open in [true, false] {
                let tab = open ? "open" : "closed"
                let swiftUI = MacDecisionsRender.swiftUI(open: open, appearance: appearance, size: size, pixelScale: 2)
                try swiftUI.png()?.write(to: dir.appendingPathComponent("swiftui-\(tab)-\(name).png"))
                let appKit = MacDecisionsRender.appKit(open: open, appearance: appearance, size: size, pixelScale: 2)
                try appKit.png()?.write(to: dir.appendingPathComponent("appkit-\(tab)-\(name).png"))
            }
        }
    }
}
#endif
