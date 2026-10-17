#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import MatronMac
import MatronChat
import MatronModels

/// Made-up sidebar rows covering every state a chat row draws: box and
/// room tags, unread and needs-you pills (one past 99), the bell-slash,
/// "New", an empty snippet, no time, and all four recency groups.
enum MacSidebarFixtures {
    static let bot = BotIdentity(matrixID: "agent:claude", displayName: "Claude", avatarURL: nil)

    struct Fixture {
        var summary: ChatSummary
        var isSilenced = false
        var isNew = false
    }

    static func summary(_ id: String, _ title: String, ago: TimeInterval?, from now: Date, snippet: String = "",
                        unread: Int = 0, needs: Int = 0, box: (name: String, letter: String)? = nil,
                        short: String? = nil, room: [(name: String, letter: String)] = []) -> ChatSummary {
        ChatSummary(id: id, title: title, bot: bot, lastActivity: ago.map { now.addingTimeInterval(-$0) },
                    unreadCount: unread, snippet: snippet, boxName: box?.name, sessionShort: short,
                    boxShort: box?.letter, roomBoxNames: room.map(\.name), roomBoxShorts: room.map(\.letter),
                    needsUserCount: needs)
    }

    /// About a dozen rows. Times are relative to `now`, at whole hours of
    /// the day so the groups do not depend on when the test runs.
    static func rows(now: Date) -> [Fixture] {
        let a = (name: "box-a", letter: "A"), b = (name: "box-b", letter: "B")
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let sinceMidnight = now.timeIntervalSince(startOfDay)
        // Today's rows stay inside today however early the run is.
        func today(_ seconds: TimeInterval) -> TimeInterval { min(seconds, max(0, sinceMidnight - 1)) }
        let day: TimeInterval = 86400
        return [
            Fixture(summary: summary("c1", "Quarterly planning notes", ago: today(300), from: now,
                                     snippet: "Drafted the agenda for Monday", unread: 2, needs: 1, box: a,
                                     short: "k3")),
            Fixture(summary: summary("c2", "Fix the flaky login test", ago: today(720), from: now,
                                     snippet: "Running the suite again", box: b, short: "7f")),
            Fixture(summary: summary("c3", "Release checklist", ago: today(3600), from: now,
                                     snippet: "All checks passed", box: a, short: "q1"), isSilenced: true),
            Fixture(summary: summary("c4", "Onboarding docs review", ago: today(7200), from: now,
                                     snippet: "Started a new session", unread: 1, box: b, short: "m2"), isNew: true),
            Fixture(summary: summary("c5", "Shared API contract", ago: today(10800), from: now,
                                     snippet: "Both sides agree on v2", needs: 2, short: "r9", room: [a, b])),
            Fixture(summary: summary("c6", "Garden irrigation timer", ago: sinceMidnight + 3600, from: now,
                                     box: a, short: "g4")),
            Fixture(summary: summary("c7", "Recipe scaler script", ago: sinceMidnight + 7200, from: now,
                                     snippet: "Converted cups to grams", unread: 14, box: b, short: "s5")),
            Fixture(summary: summary("c8", "Photo library cleanup", ago: sinceMidnight + 3 * day, from: now,
                                     snippet: "Found 212 duplicates", needs: 1, box: a, short: "p6"),
                    isSilenced: true),
            Fixture(summary: summary("c9", "Weekend trip itinerary with train times", ago: sinceMidnight + 4 * day,
                                     from: now, snippet: "Trains booked both ways, seats reserved for the return", box: b, short: "w8")),
            Fixture(summary: summary("c10", "Bird feeder camera", ago: sinceMidnight + 5 * day, from: now,
                                     snippet: "Motion clips from the morning", unread: 120, box: a, short: "b2")),
            Fixture(summary: summary("c11", "Old prototype ideas", ago: 30 * day, from: now,
                                     snippet: "Archived sketches", box: b, short: "o1")),
            Fixture(summary: summary("c12", "Reading list", ago: nil, from: now, snippet: "Three books queued")),
        ]
    }

    static func sidebarRow(_ fixture: Fixture, now: Date) -> MacSidebarChat {
        MacSidebarChat(summary: fixture.summary, group: MacRecencyBuckets(now: now).bucket(fixture.summary.lastActivity),
                       isSilenced: fixture.isSilenced, isNew: fixture.isNew)
    }

    /// The fixtures in sidebar order: grouped, newest first (as listed).
    static func grouped(_ fixtures: [Fixture], now: Date) -> [(group: ChatRecencyGroup, rows: [Fixture])] {
        let buckets = MacRecencyBuckets(now: now)
        return ChatRecencyGroup.allCases.compactMap { group in
            let rows = fixtures.filter { buckets.bucket($0.summary.lastActivity) == group }
            return rows.isEmpty ? nil : (group, rows)
        }
    }

    static func publication(_ fixtures: [Fixture], now: Date) -> ListPublication<MacSidebarChat, String> {
        let groups = grouped(fixtures, now: now)
        let sections = ChatRecencyGroup.allCases.map { group in
            ListSection(key: group.rawValue,
                        ids: groups.first { $0.group == group }?.rows.map(\.summary.id) ?? [])
        }
        let rows = groups.flatMap { $0.rows.map { sidebarRow($0, now: now) } }
        return ListPublication(update: .reset(sections), rows: rows)
    }
}

/// One sidebar list rendered off-screen in a borderless window: the image,
/// and where each table row is in it.
@MainActor
struct MacSidebarRender {
    var bitmap: NSBitmapImageRep
    /// Points to pixels.
    var scale: CGFloat
    var size: NSSize
    /// Table rows, top to bottom, in the image's (flipped) point space.
    var rows: [(isHeader: Bool, rect: NSRect)]

    func png() -> Data? { bitmap.representation(using: .png, properties: [:]) }

    static func window(size: NSSize, appearance: NSAppearance.Name, content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let backdrop = MacSidebarBackdrop(frame: NSRect(origin: .zero, size: size))
        content.frame = backdrop.bounds
        content.autoresizingMask = [.width, .height]
        backdrop.addSubview(content)
        window.contentView = backdrop
        return window
    }

    static func capture(_ window: NSWindow, table: NSTableView, pixelScale: CGFloat = 0) -> MacSidebarRender {
        let view = window.contentView!
        // Unfocused, as in a window that is not key: the selection draws
        // its unemphasized grey (the focused accent selection is drawn
        // through a material an off-screen capture renders black).
        window.makeFirstResponder(nil)
        for _ in 0..<6 {
            view.layoutSubtreeIfNeeded()
            table.enumerateAvailableRowViews { rowView, _ in rowView.isEmphasized = false }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        standInForSelectionMaterial(in: table)
        let rep: NSBitmapImageRep
        if pixelScale > 0 {
            rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * pixelScale),
                                   pixelsHigh: Int(view.bounds.height * pixelScale), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = view.bounds.size
        } else {
            rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        var rows: [(Bool, NSRect)] = []
        for row in 0..<table.numberOfRows {
            var rect = table.convert(table.rect(ofRow: row), to: view)
            // To the image's top-left origin.
            if !view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
            // SwiftUI's table does not answer `isGroupRow`; its headers
            // are the short rows.
            let isHeader = table.delegate?.tableView?(table, isGroupRow: row) ?? (rect.height < 30)
            rows.append((isHeader, rect))
        }
        return MacSidebarRender(bitmap: rep, scale: CGFloat(rep.pixelsWide) / view.bounds.width,
                                size: view.bounds.size, rows: rows)
    }

    /// AppKit's source-list selection is a system material, which an
    /// off-screen capture draws black in light mode: a plain fill of the
    /// unemphasized selection colour stands in for it, in the material's
    /// own frame, so the capture shows what the screen does.
    static func standInForSelectionMaterial(in table: NSTableView) {
        table.enumerateAvailableRowViews { rowView, _ in
            for subview in rowView.subviews where String(describing: type(of: subview)).contains("SelectionView") {
                guard !subview.isHidden else { continue }
                subview.isHidden = true
                let fill = NSView(frame: subview.frame)
                fill.wantsLayer = true
                rowView.effectiveAppearance.performAsCurrentDrawingAppearance {
                    fill.layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
                }
                fill.layer?.cornerRadius = 5
                fill.autoresizingMask = subview.autoresizingMask
                rowView.addSubview(fill, positioned: .below, relativeTo: nil)
            }
        }
    }

    /// Today's SwiftUI sidebar list (`MacChatSidebarList`'s `List`).
    static func swiftUI(_ fixtures: [MacSidebarFixtures.Fixture], now: Date, selected: String?,
                        appearance: NSAppearance.Name, size: NSSize, pixelScale: CGFloat = 0) -> MacSidebarRender {
        let groups = MacSidebarFixtures.grouped(fixtures, now: now)
        let list = List(selection: .constant(selected)) {
            ForEach(groups, id: \.group) { group in
                Section(group.group.rawValue) {
                    ForEach(group.rows, id: \.summary.id) { fixture in
                        MacChatRow(summary: fixture.summary, isNotifySilenced: fixture.isSilenced,
                                   isNew: fixture.isNew)
                            .tag(fixture.summary.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        let host = NSHostingView(rootView: list)
        let window = window(size: size, appearance: appearance, content: host)
        defer { window.close() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let table = findTable(in: host)!
        return capture(window, table: table, pixelScale: pixelScale)
    }

    /// The AppKit list (`MacSidebarAppKitList`'s host) on the same rows.
    static func appKit(_ fixtures: [MacSidebarFixtures.Fixture], now: Date, selected: String?, hovered: String? = nil,
                       appearance: NSAppearance.Name, size: NSSize, pixelScale: CGFloat = 0) -> MacSidebarRender {
        let rows = MacSidebarChatRows()
        rows.now = { now }
        let host = MacListHost(rows: rows, style: .sourceList, allowsMultipleSelection: true,
                               accessibilityIdentifier: MacSidebarAppKitList.accessibilityIdentifier)
        let window = window(size: size, appearance: appearance, content: host.view)
        defer { window.close() }
        host.scrollView.scrollerStyle = .overlay
        host.apply(MacSidebarFixtures.publication(fixtures, now: now))
        host.flushPendingUpdates()
        if let selected { host.selection = [selected] }
        window.contentView?.layoutSubtreeIfNeeded()
        host.tableView.layoutSubtreeIfNeeded()
        if let hovered, let row = host.tableRow(of: hovered),
           let cell = host.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? MacChatListCell {
            cell.setHoveredForTesting(true)
        }
        return capture(window, table: host.tableView, pixelScale: pixelScale)
    }

    static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews { if let table = findTable(in: subview) { return table } }
        return nil
    }

    // MARK: Ink

    /// The luminance of the pixel at `x, y` (pixels, top-left origin).
    func luminance(x: Int, y: Int) -> CGFloat {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }

    /// The box, in points, around the pixels in `rect` that differ from the
    /// rect's background (its left-edge pixel, outside any selection or
    /// hover fill) by more than `threshold` in luminance: where the row's
    /// text and badges actually are.
    func inkBox(in rect: NSRect, threshold: CGFloat = 0.18) -> NSRect? {
        let x0 = max(0, Int((rect.minX * scale).rounded())), x1 = min(bitmap.pixelsWide, Int((rect.maxX * scale).rounded()))
        let y0 = max(0, Int((rect.minY * scale).rounded())), y1 = min(bitmap.pixelsHigh, Int((rect.maxY * scale).rounded()))
        guard x1 > x0 + 2, y1 > y0 else { return nil }
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in y0..<y1 {
            let background = luminance(x: x0 + 1, y: y)
            for x in x0..<x1 where abs(luminance(x: x, y: y) - background) > threshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}

/// Paints the window background in the view's effective appearance.
final class MacSidebarBackdrop: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
#endif
