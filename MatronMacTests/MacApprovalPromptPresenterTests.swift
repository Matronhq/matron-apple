#if os(macOS)
import AppKit
import XCTest
import MatronDesignSystem
import MatronJournal
import MatronViewModels
@testable import MatronMac

/// The confirm sheet on the Mac: it attaches to the window in front when a
/// request waits, goes when the request is answered, and a second
/// request's sheet follows the first.
@MainActor
final class MacApprovalPromptPresenterTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 800), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }

    override func tearDown() async throws {
        for host in NSApp.windows { if let sheet = host.attachedSheet, sheet.title == ApprovalConfirmView.title { host.endSheet(sheet) } }
        window.close()
        window = nil
    }

    /// The confirm sheet, on whichever window has it. The presenter picks
    /// the window in front, which in a test run may be the host app's own
    /// rather than this test's.
    private var confirmSheet: NSWindow? {
        NSApp.windows.compactMap(\.attachedSheet).first { $0.title == ApprovalConfirmView.title }
    }

    private func wait(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private let first = ApprovalRequest(kind: .account, subject: ["op": "change_password"], headline: "Change password")
    private let second = ApprovalRequest(kind: .account, subject: ["op": "link_device", "code": "BCDF2345"],
                                         headline: "Sign in a new device")

    func test_sheetGoesUpForARequest_andDownWhenItIsAnswered() async throws {
        let center = await ApprovalFixtures.screenModel(.ready, thisDevice: "alice's Mac", method: "Touch ID").center
        let presenter = ApprovalPromptPresenter(center: center)
        _ = presenter
        let task = Task { try await center.sign(self.first) }
        try await wait("the sheet") { self.confirmSheet != nil }
        XCTAssertEqual(center.prompt?.request, first)
        center.confirm()
        let approval = try await task.value
        XCTAssertNotNil(approval)
        try await wait("the sheet to go") { self.confirmSheet == nil }
    }

    func test_cancel_takesTheSheetDown_andNothingIsSigned() async throws {
        let center = await ApprovalFixtures.screenModel(.ready, thisDevice: "alice's Mac", method: "Touch ID").center
        let presenter = ApprovalPromptPresenter(center: center)
        _ = presenter
        let task = Task { try await center.sign(self.first) }
        try await wait("the sheet") { self.confirmSheet != nil }
        center.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancel")
        } catch {
            XCTAssertEqual(error as? ApprovalKeyFailure, .cancelled)
        }
        try await wait("the sheet to go") { self.confirmSheet == nil }
    }

    func test_aSecondRequestsSheetFollowsTheFirst() async throws {
        let center = await ApprovalFixtures.screenModel(.ready, thisDevice: "alice's Mac", method: "Touch ID").center
        let presenter = ApprovalPromptPresenter(center: center)
        _ = presenter
        let one = Task { try await center.sign(self.first) }
        let two = Task { try await center.sign(self.second) }
        try await wait("the first sheet") { self.confirmSheet != nil && center.prompt?.request == self.first }
        let firstSheet = confirmSheet
        center.confirm()
        _ = try await one.value
        try await wait("the second sheet") {
            center.prompt?.request == self.second && self.confirmSheet != nil && self.confirmSheet !== firstSheet
        }
        center.confirm()
        _ = try await two.value
        try await wait("the sheet to go") { self.confirmSheet == nil }
    }
}
#endif
