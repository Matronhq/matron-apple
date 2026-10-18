#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import MatronMac
import MatronDesignSystem
import MatronModels

/// Made-up items pane rows covering every section and every state a row
/// draws: pending creates (sending and failed), Needs you (a question, a
/// notice), Tasks (with the agent, a body line, a mission chip, an image),
/// an open decision, and closed items under Done.
enum MacItemsPaneFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let convoID = "c1"

    static func needsYou() -> [TrackerItem] {
        [
            TrackerItem(id: "n1", num: 412, kind: .question, awaiting: .user, title: "Ship the new onboarding flow?",
                        body: "Two options: the short tour or the checklist. I recommend the checklist.",
                        originConvoID: "c1", updatedAt: now.addingTimeInterval(-300), commentCount: 3),
            TrackerItem(id: "n2", num: 415, kind: .notice, awaiting: .user, title: "Nightly backup finished with warnings",
                        originConvoID: "c2", updatedAt: now.addingTimeInterval(-900), actions: [TrackerItem.seenAction]),
        ]
    }

    static func tasks() -> [TrackerItem] {
        [
            TrackerItem(id: "t1", num: 420, kind: .task, awaiting: .agent, rank: 1024, title: "Write the release notes",
                        originConvoID: "c1", updatedAt: now.addingTimeInterval(-1200)),
            TrackerItem(id: "t2", num: 421, kind: .task, awaiting: .agent, rank: 2048,
                        title: "Move the nightly report to the new storage bucket and check last week's files",
                        body: "The old bucket is read-only from Monday.", originConvoID: "c3",
                        updatedAt: now.addingTimeInterval(-2400), missionNum: 61),
            TrackerItem(id: "t3", num: 425, kind: .task, awaiting: .agent, rank: 3072, title: "Crop the header image",
                        originConvoID: "c1", updatedAt: now.addingTimeInterval(-3600), commentCount: 2,
                        hasImage: true),
            TrackerItem(id: "t4", num: 426, kind: .task, rank: 4096, title: "Tidy the shared drive",
                        originConvoID: "c2", updatedAt: now.addingTimeInterval(-4000)),
        ]
    }

    static func decisions() -> [TrackerItem] {
        [
            TrackerItem(id: "x1", num: 427, kind: .decision, title: "Use the quarterly plan format",
                        body: "Recorded so the team can review it.", originConvoID: "c2",
                        updatedAt: now.addingTimeInterval(-10800), missionNum: 7),
        ]
    }

    static func done() -> [TrackerItem] {
        [
            TrackerItem(id: "d1", num: 401, kind: .question, state: .closed, resolution: .answered,
                        title: "Rename the reports folder?", originConvoID: "c1", closedAt: now.addingTimeInterval(-7200)),
            TrackerItem(id: "d2", num: 398, kind: .task, state: .closed, resolution: .done,
                        title: "Archive last year's invoices", originConvoID: "c4",
                        closedAt: now.addingTimeInterval(-86400 * 2), commentCount: 1),
        ]
    }

    static func pending() -> [ItemsListView.PendingRow] {
        [
            .init(id: "p1", kind: .task, title: "Book the venue", isFailed: false, error: nil),
            .init(id: "p2", kind: .question, title: "Which caterer?", isFailed: true, error: "offline"),
        ]
    }

    static let origins: [String: String] = [
        "c1": "Product planning", "c2": "Ops desk", "c3": "Events", "c4": "Settings polish",
    ]

    static func origin(_ item: TrackerItem, all: Bool) -> String? {
        all ? (origins[item.originConvoID] ?? "Another chat") : nil
    }

    static func rows(all: Bool) -> [MacItemsPaneRow] {
        var rows = pending().map { MacItemsPaneRow(pending: $0) }
        for (section, items) in [(MacItemsPaneSection.needsYou, needsYou()), (.tasks, tasks()),
                                 (.decisions, decisions()), (.done, done())] {
            rows += items.map { MacItemsPaneRow(item: $0, section: section, origin: origin($0, all: all)) }
        }
        return rows
    }

    static func publication(_ rows: [MacItemsPaneRow]) -> ListPublication<MacItemsPaneRow, String> {
        let sections = MacItemsPaneSection.allCases.map { section in
            ListSection(key: section.rawValue, ids: rows.filter { $0.section == section }.map(\.id))
        }
        return ListPublication(update: .reset(sections), rows: rows)
    }

    static func model() -> ItemsListView.Model {
        ItemsListView.Model(needsYou: needsYou(), tasks: tasks(), decisions: decisions(), done: done(),
                            originTitles: origins, isSupported: true, isRefreshing: false, pending: pending())
    }
}

@MainActor
enum MacItemsPaneRender {
    /// Today's SwiftUI list (`ItemsListView`), in either scope.
    static func swiftUI(all: Bool, appearance: NSAppearance.Name, size: NSSize,
                        pixelScale: CGFloat = 0) -> MacSidebarRender {
        let scope: ItemsScope = all ? .all : .convo(MacItemsPaneFixtures.convoID)
        let view = ItemsListView(model: MacItemsPaneFixtures.model(), scope: .constant(scope),
                                 convoID: MacItemsPaneFixtures.convoID, thumbnail: { _ in nil },
                                 onSelect: { _ in }, onMove: { _, _ in }, onCreate: {}, onOpenConversation: { _ in })
        let host = NSHostingView(rootView: view)
        let window = MacSidebarRender.window(size: size, appearance: appearance, content: host)
        defer { window.close() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        let table = MacSidebarRender.findTable(in: host)!
        return MacSidebarRender.capture(window, table: table, pixelScale: pixelScale)
    }
}

extension MacItemsPaneRender {
    /// The AppKit list (`MacItemsAppKitList`'s host) on the same rows,
    /// without the header above it.
    static func appKit(all: Bool, appearance: NSAppearance.Name, size: NSSize,
                       pixelScale: CGFloat = 0) -> MacSidebarRender {
        let rows = MacItemsPaneRows()
        let host = MacListHost(rows: rows, style: .plain,
                               accessibilityIdentifier: MacItemsAppKitList.accessibilityIdentifier)
        let window = MacSidebarRender.window(size: size, appearance: appearance, content: host.view)
        defer { window.close() }
        host.scrollView.scrollerStyle = .overlay
        host.apply(MacItemsPaneFixtures.publication(MacItemsPaneFixtures.rows(all: all)))
        host.flushPendingUpdates()
        window.contentView?.layoutSubtreeIfNeeded()
        host.tableView.layoutSubtreeIfNeeded()
        return MacSidebarRender.capture(window, table: host.tableView, pixelScale: pixelScale)
    }
}

/// Writes renders under `$HOME/Dev/shots-items` when `MATRON_ITEMS_SHOTS`
/// is set (for a pull request's screenshots); skipped otherwise.
@MainActor
final class MacItemsPaneRenderHarness: XCTestCase {
    func test_writeRenders() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MATRON_ITEMS_SHOTS"] != nil)
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Dev/shots-items")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = NSSize(width: 380, height: 900)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for all in [false, true] {
                let scope = all ? "all" : "chat"
                let swiftUI = MacItemsPaneRender.swiftUI(all: all, appearance: appearance, size: size, pixelScale: 2)
                try swiftUI.png()?.write(to: dir.appendingPathComponent("swiftui-\(scope)-\(name).png"))
                var lines: [String] = []
                for row in swiftUI.rows {
                    let ink = swiftUI.inkBox(in: row.rect.insetBy(dx: 0, dy: 1))
                    lines.append("\(row.isHeader ? "H" : "R") \(row.rect) ink \(ink.map { "\($0)" } ?? "-")")
                }
                try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("swiftui-\(scope)-\(name).txt"),
                                                        atomically: true, encoding: .utf8)
                let appKit = MacItemsPaneRender.appKit(all: all, appearance: appearance, size: size, pixelScale: 2)
                try appKit.png()?.write(to: dir.appendingPathComponent("appkit-\(scope)-\(name).png"))
            }
        }
    }
}
#endif
