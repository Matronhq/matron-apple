#if os(macOS) && DEBUG
import XCTest
import AppKit
import SwiftUI
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronStorage
@testable import MatronViewModels
@testable import MatronMac

/// Approve on a chat request aimed at a protected box, from For you: the
/// whole window with made-up items, before (an alert sending the user to
/// the request's card) and after (the confirm sheet with the message in
/// full, above the Touch ID button). Both overlays are built from what
/// `StepUpTap` produces for the same item. For a pull request's
/// screenshots; skipped unless `FORYOU_APPROVAL_SHOTS` names a folder
/// (`TEST_RUNNER_FORYOU_APPROVAL_SHOTS` under `xcodebuild test`).
@MainActor
final class MacForYouChatApprovalRenderHarness: XCTestCase {
    static let message = """
        The nightly backup on box-a failed twice this week. I want to read its logs and the disk usage report, \
        then suggest a fix. I won't change anything on box-a without asking first.
        """

    static var item: TrackerItem {
        let now = Date()
        return TrackerItem(
            id: "it-chat", num: 4_310, kind: .question, awaiting: .user, rank: -1,
            title: "box-b asks to chat with box-a — backup logs",
            body: """
                **box-b** asks to open a chat with **box-a**.

                - **From:** box-b — session "Backups"
                - **To:** box-a

                **Why, in box-b's words:**

                ```
                \(message)
                ```
                """,
            labels: [TrackerItem.consentLabel],
            links: [TrackerLink(json: ["url": "matron://consent/chat/room-1/4"])!],
            originConvoID: "c-1", createdAt: now.addingTimeInterval(-120), updatedAt: now.addingTimeInterval(-120),
            actions: ["Approve", "Decline"], stepUp: true,
            subject: ApprovalSubjects.chat(roomID: "room-1", targetDeviceID: 4, box: "box-a", justification: message),
            consentKind: "chat")
    }

    func test_writeRenders() async throws {
        let path = ProcessInfo.processInfo.environment["FORYOU_APPROVAL_SHOTS"] ?? ""
        try XCTSkipIf(path.isEmpty, "set FORYOU_APPROVAL_SHOTS to a folder")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        // Before: no message to hand, so the tap is refused with a sentence.
        var refusal = ""
        XCTAssertThrowsError(try StepUpTap.consentRequest(item: Self.item, label: "Approve", verifiedText: nil)) {
            refusal = $0.localizedDescription
        }
        // After: the message from the pending list, checked against the subject.
        let request = try XCTUnwrap(StepUpTap.consentRequest(item: Self.item, label: "Approve", verifiedText: Self.message))
        let model = ApprovalConfirmView.Model(
            reference: request.reference, headline: request.headline, button: request.button, detail: request.detail,
            subject: request.subjectLines.map { .init(key: $0.key, value: $0.value) },
            method: "Touch ID", fingerprint: "7734f909")

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await withWindow(appearance: appearance) { window in
                let page = try XCTUnwrap(MacNarrowWindowLayoutTests.capture(window).flatMap(NSImage.init(data:)))
                let alert = try XCTUnwrap(Self.alertImage(refusal, appearance: appearance))
                let sheet = try XCTUnwrap(Self.sheetImage(model, appearance: appearance))
                try XCTUnwrap(Self.compose(page, alert, centred: true))
                    .write(to: URL(fileURLWithPath: "\(path)/before-\(name).png"))
                try XCTUnwrap(Self.compose(page, sheet, centred: false))
                    .write(to: URL(fileURLWithPath: "\(path)/after-\(name).png"))
            }
        }
    }

    // MARK: Overlays

    private static func alertImage(_ text: String, appearance: NSAppearance.Name) -> NSImage? {
        let alert = NSAlert()
        alert.messageText = "Tracker"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.window.appearance = NSAppearance(named: appearance)
        alert.layout()
        // The alert's material draws nothing off-screen: its content goes
        // on a plain fill of the window colour, in the alert's appearance.
        guard let content = alert.window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        let out = NSImage(size: content.bounds.size)
        out.lockFocus()
        let bounds = NSRect(origin: .zero, size: content.bounds.size)
        (appearance == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
        bounds.fill()
        rep.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        out.unlockFocus()
        return out
    }

    private static func sheetImage(_ model: ApprovalConfirmView.Model, appearance: NSAppearance.Name) -> NSImage? {
        let size = ApprovalPromptPresenter.sheetSize
        let host = MacSnapshotHost(ApprovalConfirmView(model: model, onConfirm: {}, onCancel: {})
            .frame(width: size.width, height: size.height), appearance: appearance)
        defer { host.close() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        return host.pngData().flatMap(NSImage.init(data:))
    }

    /// The page dimmed, the overlay on top (a sheet hangs from the title
    /// bar, an alert sits in the middle), outlined in red.
    private static func compose(_ page: NSImage, _ overlay: NSImage, centred: Bool) -> Data? {
        let size = page.size
        let out = NSImage(size: size)
        out.lockFocus()
        page.draw(in: NSRect(origin: .zero, size: size))
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceOver)
        let o = overlay.size
        let x = (size.width - o.width) / 2
        let y = centred ? (size.height - o.height) / 2 : size.height - 28 - o.height
        let rect = NSRect(x: x, y: y, width: o.width, height: o.height)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).addClip()
        overlay.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.systemRed.setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -6, dy: -6), xRadius: 16, yRadius: 16)
        outline.lineWidth = 4
        outline.stroke()
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Window

    private func withWindow(appearance: NSAppearance.Name, _ body: (NSWindow) async throws -> Void) async throws {
        let userID = "foryou-\(UUID().uuidString.prefix(8))"
        let session = UserSession(userID: userID, deviceID: "foryou-device",
                                  homeserverURL: URL(string: "https://journal.invalid")!, accessToken: "foryou")
        let deps = AppDependencies()
        let store = deps.journalStore(for: session)
        // A test window is never reported on screen, and drawn rows wait
        // for that before drawing.
        let wasVisible = MacDrawnCellView.isWindowVisible
        MacDrawnCellView.isWindowVisible = { _ in true }
        defer {
            MacDrawnCellView.isWindowVisible = wasVisible
            let file = deps.journalStoreURL(for: session)
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
        }
        try Self.seed(store)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1280, height: 800),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let root = MacChatListView(viewModel: ChatListViewModel(chat: deps.chatService(for: session), gate: .shared))
            .frame(minWidth: 800, minHeight: 600)
            .environment(\.appDependencies, deps)
            .environment(\.currentSession, session)
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await MacNarrowWindowLayoutTests.spin(2)
        NotificationCenter.default.post(name: .matronPerfOpenItem, object: "it-chat")
        await MacNarrowWindowLayoutTests.spin(2)
        // As a capture of a window that is not key: the list's focused
        // selection and the tab control draw through materials an
        // off-screen capture renders black.
        window.makeFirstResponder(nil)
        for table in MacNarrowWindowLayoutTests.allSubviews(of: window.contentView!).compactMap({ $0 as? NSTableView }) {
            // Drawn unselected: the selected row's text is drawn for a
            // highlight the capture does not show.
            table.enumerateAvailableRowViews { rowView, _ in 
                rowView.isEmphasized = false
                rowView.isSelected = false
                for cell in rowView.subviews.compactMap({ $0 as? NSTableCellView }) {
                    cell.backgroundStyle = .normal
                    cell.needsDisplay = true
                }
            }
        }
        await MacNarrowWindowLayoutTests.spin(0.5)
        try await body(window)
    }

    private static func seed(_ store: JournalStore) throws {
        let now = Date()
        let ts = Int64(now.timeIntervalSince1970 * 1000)
        try store.applyColdSnapshot([ConvoSummaryDTO(id: "c-1", title: "Backups", sessionState: "idle",
                                                     lastSeq: 0, snippet: "", createdAt: ts - 86_400_000, lastTS: ts)],
                                    headSeq: 0)
        let others = ["Review the new onboarding copy before it ships to the help centre",
                      "Pick a colour for the new settings icon"]
        try store.upsertItems([item] + others.enumerated().map { i, title in
            TrackerItem(id: "it-\(i)", num: 4_300 + i, kind: .question, awaiting: .user, rank: Double(i) * 1024,
                        title: title, originConvoID: "c-1", createdAt: now.addingTimeInterval(-Double(i + 1) * 3_600),
                        updatedAt: now.addingTimeInterval(-Double(i + 1) * 600))
        })
    }
}
#endif
