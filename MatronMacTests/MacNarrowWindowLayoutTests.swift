#if os(macOS) && DEBUG
import XCTest
import AppKit
import SwiftUI
import MatronJournal
import MatronModels
import MatronStorage
import MatronViewModels
@testable import MatronMac

/// The whole signed-in window (`MacChatListView` on a real store with
/// made-up items) at narrow and normal widths. In a narrow window the
/// split view used to lay out wider than the window itself, which AppKit
/// then centred: the For you list was cut off at the left edge and the
/// item's title, comments and reply bar at the right. The cause was the
/// markdown panel's SwiftUI `.inspector`, which took the detail content's
/// ideal width (plus the floating sidebar's) as its minimum even while
/// closed.
///
/// `NARROW_SHOTS_DIR=<dir>` (`TEST_RUNNER_NARROW_SHOTS_DIR` under
/// `xcodebuild test`) also writes a PNG of the window at each width.
@MainActor
final class MacNarrowWindowLayoutTests: XCTestCase {
    static let widths: [CGFloat] = [800, 900, 1000, 1200, 1440]

    func test_forYouItem_fitsTheWindowAtEveryWidth() async throws {
        try await withWindow { window in
            NotificationCenter.default.post(name: .matronPerfOpenItem, object: "it-0")
            await Self.spin(2)
            try await assertFits(window, label: "item")
        }
    }

    func test_markdownPanelOpen_fitsTheWindow_andCoversTheItemWhenNarrow() async throws {
        try await withWindow { window in
            NotificationCenter.default.post(name: .matronPerfOpenItem, object: "it-0")
            await Self.spin(2)
            NotificationCenter.default.post(name: .matronPerfOpenMarkdown,
                                            object: "# Notes\n\nA short file with a few lines of text, previewed beside the item.")
            await Self.spin(1)
            try await assertFits(window, label: "markdown")
        }
    }

    func test_emptyConversationsPage_fitsTheWindowAtTheMinimumWidth() async throws {
        try await withWindow { window in
            try await assertFits(window, label: "empty", widths: [800])
        }
    }

    // MARK: Harness

    private func assertFits(_ window: NSWindow, label: String, widths: [CGFloat] = widths,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let shots = ProcessInfo.processInfo.environment["NARROW_SHOTS_DIR"]
        if let shots { try FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true) }
        for width in widths {
            window.setContentSize(NSSize(width: width, height: 760))
            await Self.spin(1)
            let content = try XCTUnwrap(window.contentView)
            let split = try XCTUnwrap(Self.splitView(in: content), file: file, line: line)
            // The outer split view is the window's; nothing may lay out
            // wider than the window it sits in.
            XCTAssertEqual(split.frame.width, content.frame.width, accuracy: 1,
                           "\(label) at \(width): the split view is wider than the window", file: file, line: line)
            for view in Self.allSubviews(of: split) where view is NSSplitView {
                XCTAssertLessThanOrEqual(view.frame.width, content.frame.width + 1,
                                         "\(label) at \(width): a nested split view is wider than the window",
                                         file: file, line: line)
            }
            let sidebar = split.arrangedSubviews[0].frame.width
            XCTAssertGreaterThanOrEqual(width - sidebar, MacChatListView.detailMinWidth - 1,
                                        "\(label) at \(width): the detail column is narrower than its minimum",
                                        file: file, line: line)
            if let shots, let png = Self.capture(window) {
                try png.write(to: URL(fileURLWithPath: "\(shots)/\(label)-\(Int(width)).png"))
            }
        }
    }

    private func withWindow(_ body: (NSWindow) async throws -> Void) async throws {
        let userID = "narrow-\(UUID().uuidString.prefix(8))"
        let session = UserSession(userID: userID, deviceID: "narrow-device",
                                  homeserverURL: URL(string: "https://journal.invalid")!, accessToken: "narrow")
        let deps = AppDependencies()
        let store = deps.journalStore(for: session)
        defer {
            let file = StoragePaths.appSupport.appendingPathComponent("journal-store/\(userID).sqlite")
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
        }
        try Self.seed(store)

        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1440, height: 900),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The app's own window minimum (`MatronMacApp`).
        let root = MacChatListView(viewModel: ChatListViewModel(chat: deps.chatService(for: session), gate: .shared))
            .frame(minWidth: 800, minHeight: 600)
            .environment(\.appDependencies, deps)
            .environment(\.currentSession, session)
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await Self.spin(2)
        try await body(window)
    }

    /// Made-up items: one with a long title, a body, action buttons and a
    /// comment, and a few short ones for the list.
    private static func seed(_ store: JournalStore) throws {
        let now = Date()
        let ts = Int64(now.timeIntervalSince1970 * 1000)
        try store.applyColdSnapshot([ConvoSummaryDTO(id: "c-1", title: "Desktop app polish", sessionState: "idle",
                                                     lastSeq: 0, snippet: "", createdAt: ts - 86_400_000, lastTS: ts)],
                                    headSeq: 0)
        let titles = ["Voice notes: show which microphone is recording, or let the user pick it before recording starts",
                      "Review the new onboarding copy before it ships to the help centre",
                      "Approve the draft reply about the late delivery of the spring order",
                      "Pick a colour for the new settings icon"]
        try store.upsertItems(titles.enumerated().map { i, title in
            TrackerItem(id: "it-\(i)", num: 4_200 + i, kind: i == 0 ? .question : .task, awaiting: .user,
                        rank: Double(i) * 1024, title: title,
                        body: "The recorder uses whichever input the system picked. Show its name next to the timer, and offer a menu to switch before recording.",
                        originConvoID: "c-1", createdAt: now.addingTimeInterval(-Double(i) * 3_600),
                        updatedAt: now.addingTimeInterval(-Double(i) * 60),
                        actions: i == 0 ? ["Show it", "Let me pick"] : [])
        })
        try store.replaceComments(itemID: "it-0", [
            TrackerComment(id: "cm-1", itemID: "it-0", author: .agent,
                           body: "Found it: the recorder never names its input, so it is not clear which microphone a voice note uses when a headset is plugged in. I can show the device name next to the timer.",
                           createdAt: now.addingTimeInterval(-600)),
        ])
    }

    /// The window as drawn, title bar included. The sidebar's glass
    /// material draws nothing in an off-screen capture, so its column is
    /// drawn again on a plain sidebar fill.
    static func capture(_ window: NSWindow) -> Data? {
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(rep)
        if let split = splitView(in: window.contentView),
           let column = allSubviews(of: split.arrangedSubviews[0])
               .first(where: { String(describing: type(of: $0)).contains("SidebarStyleContext") }),
           let columnRep = column.bitmapImageRepForCachingDisplay(in: column.bounds) {
            column.cacheDisplay(in: column.bounds, to: columnRep)
            var rect = column.convert(column.bounds, to: frameView)
            if frameView.isFlipped { rect.origin.y = frameView.bounds.height - rect.maxY }
            image.lockFocus()
            NSColor(white: 0.93, alpha: 1).setFill()
            rect.fill()
            columnRep.draw(in: rect)
            NSColor(white: 0.82, alpha: 1).setFill()
            NSRect(x: rect.maxX - 1, y: rect.minY, width: 3, height: rect.height).fill()
            image.unlockFocus()
        }
        guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return nil }
        return out.representation(using: .png, properties: [:])
    }

    static func splitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        return ([view] + allSubviews(of: view)).lazy.compactMap { $0 as? NSSplitView }.first
    }

    static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }

    static func spin(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// Where the markdown panel goes in the detail column.
final class MacMarkdownPanelLayoutTests: XCTestCase {
    func test_closed_contentTakesTheWholeColumn() {
        let layout = MacMarkdownPanelLayout(total: 500, isOpen: false, preferred: 480)
        XCTAssertEqual(layout, MacMarkdownPanelLayout(contentWidth: 500, besidePanelWidth: nil, coversContent: false))
    }

    func test_wide_panelSitsBesideAtItsPreferredWidth() {
        let layout = MacMarkdownPanelLayout(total: 1200, isOpen: true, preferred: 480)
        XCTAssertEqual(layout.besidePanelWidth, 480)
        XCTAssertEqual(layout.contentWidth, 1200 - 1 - 480)
        XCTAssertFalse(layout.coversContent)
    }

    func test_medium_panelGivesWaySoTheContentKeepsItsMinimum() {
        let layout = MacMarkdownPanelLayout(total: 760, isOpen: true, preferred: 480)
        XCTAssertEqual(layout.contentWidth, MacMarkdownPanelLayout.minContentWidth)
        XCTAssertEqual(layout.besidePanelWidth, 760 - 1 - MacMarkdownPanelLayout.minContentWidth)
    }

    func test_narrow_panelCoversTheContentInsteadOfSqueezingIt() {
        let total = MacMarkdownPanelLayout.minContentWidth + MacMarkdownPanelLayout.minPanelWidth
        let layout = MacMarkdownPanelLayout(total: total, isOpen: true, preferred: 480)
        XCTAssertNil(layout.besidePanelWidth)
        XCTAssertTrue(layout.coversContent)
        XCTAssertEqual(layout.contentWidth, total)
    }

    func test_nothingIsEverWiderThanTheColumn() {
        for total in stride(from: CGFloat(0), through: 2_000, by: 7) {
            for preferred in [CGFloat(0), 320, 480, 900, 5_000] {
                let layout = MacMarkdownPanelLayout(total: total, isOpen: true, preferred: preferred)
                let used = layout.contentWidth + (layout.besidePanelWidth.map { $0 + 1 } ?? 0)
                XCTAssertLessThanOrEqual(used, total + 0.001, "total \(total), preferred \(preferred)")
                if let panel = layout.besidePanelWidth {
                    XCTAssertGreaterThanOrEqual(panel, MacMarkdownPanelLayout.minPanelWidth)
                    XCTAssertLessThanOrEqual(panel, MacMarkdownPanelLayout.maxPanelWidth)
                    XCTAssertGreaterThanOrEqual(layout.contentWidth, MacMarkdownPanelLayout.minContentWidth)
                }
            }
        }
    }

    func test_dragClampsToThePanelRangeAndTheContentMinimum() {
        XCTAssertEqual(MacMarkdownPanelLayout.clampedPanelWidth(100, total: 1_500), MacMarkdownPanelLayout.minPanelWidth)
        XCTAssertEqual(MacMarkdownPanelLayout.clampedPanelWidth(2_000, total: 2_000), MacMarkdownPanelLayout.maxPanelWidth)
        XCTAssertEqual(MacMarkdownPanelLayout.clampedPanelWidth(900, total: 1_000), 1_000 - 1 - MacMarkdownPanelLayout.minContentWidth)
    }
}
#endif
