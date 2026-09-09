import XCTest
import SwiftUI
import UIKit
import MatronChat
import MatronModels
import MatronViewModels
@testable import Matron

/// Local no-op fakes, mirroring the per-file pattern in
/// `SummariesSheetBindingTests.swift` — the subagents section reads nothing
/// from the timeline, so both fakes exist only to build a `ChatViewModel`.
private final class FakeTimelineForSubagents: TimelineService, @unchecked Sendable {
    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}
}

private final class FakeMediaForSubagents: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

/// Covers the subagents list that moved out of `ChatView`'s toolbar `Menu`
/// and into `SessionStatusSheet` (Dan, 2026-09-09).
///
/// Two layers, because only some of this surface is observable from a
/// unit-test host (the sheet takes `SubChatSummary` straight from the
/// strip view model — no projection to pin):
///
///  * `onOpenSubagent` — the handoff closure. Invoked directly on the
///    constructed view (the `NewChatSheetBindingTests` pattern); this is
///    what the row's action calls, one hop away.
///  * the rendered sheet — hosted in a real, scene-attached `UIWindow` and
///    laid out, which is what actually executes `body` (SwiftUI's `body` is
///    lazy, so merely constructing the struct proves only that it compiles).
///
/// What the render tests can assert is limited by the same wall documented
/// at length in `SummariesSheetBindingTests`, re-confirmed here by a
/// throwaway diagnostic against THIS sheet (2026-09-09): with two subagents
/// rendered, a public `UIView` walk of the hosted tree finds exactly one
/// `UILabel` ("Session", the navigation title) and ZERO
/// `accessibilityIdentifier`s — the entire body, rows included, is drawn
/// into anonymous layers, and this host has no connected accessibility
/// client to populate the AX tree. `UIHostingController.sizeThatFits(in:)`
/// with an unbounded height was tried as a structural discriminator and
/// returns height 0 for empty AND populated alike (the `NavigationStack`
/// collapses under that proposal), so content height can't separate them
/// either.
///
/// The consequence is deliberate and worth stating, because the obvious
/// test here is a trap: asserting that the empty case renders NO
/// `subagent-row-*` identifier would pass whether or not the section is
/// correctly gated — it passes for the populated case too. Rather than
/// bank a fail-open assertion, the render tests below pin only what is
/// genuinely observed (the sheet mounts and completes layout against each
/// input without trapping — a malformed `ForEach`/`ViewBuilder` or a
/// crash in the new branch does fail here), and the behavioural coverage
/// lives in the two layers above, which are exact. Proving the row's
/// identifier and its tap belongs to an XCUITest, where a real AX client
/// exists.
/// Emits one `children(of:)` snapshot then finishes, so a
/// `SubChatStripViewModel.start()` task completes and can be awaited.
private final class FakeChatForSubagents: ChatService, @unchecked Sendable {
    var childrenToEmit: [SubChatSummary] = []
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        let snapshot = childrenToEmit
        return AsyncStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }
    func createChat(with botID: String) async throws -> String { "!stub:server" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

@MainActor
final class SessionStatusSheetSubagentsTests: XCTestCase {
    private var window: UIWindow!

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(roomID: "!parent:server",
                      timeline: FakeTimelineForSubagents(),
                      media: FakeMediaForSubagents())
    }

    /// A started strip VM whose `children` already hold `children`.
    private func makeStrip(_ children: [SubChatSummary]) async -> SubChatStripViewModel {
        let chat = FakeChatForSubagents()
        chat.childrenToEmit = children
        let strip = SubChatStripViewModel(chat: chat, parentConvoID: "!parent:server")
        await strip.start().value
        return strip
    }

    // MARK: - the observable source

    func test_sheet_readsChildrenFromTheStripViewModel_notASnapshot() async {
        let strip = await makeStrip([
            SubChatSummary(id: "!c1:server", title: "sweep the services", isRunning: true),
        ])
        let sheet = SessionStatusSheet(viewModel: makeViewModel(), strip: strip)

        // The sheet holds the VM, so whatever `children` says NOW is what
        // the section renders — no copy taken at construction.
        XCTAssertEqual(sheet.strip?.children.map(\.id), ["!c1:server"])
        XCTAssertEqual(sheet.strip?.children.first?.isRunning, true)
    }

    // MARK: - the handoff closure

    func test_subagentsList_rowTap_reportsTheChildID() {
        var captured: [String] = []
        let list = SubagentsListView(
            subagents: [SubChatSummary(id: "!c1:server", title: "sweep", isRunning: true)],
            onSelect: { captured.append($0) }
        )
        list.onSelect("!c1:server")
        XCTAssertEqual(captured, ["!c1:server"])
    }

    func test_onOpenSubagent_reportsTheTappedChildID() async {
        var captured: [String] = []
        let strip = await makeStrip([
            SubChatSummary(id: "!c2:server", title: "read the middleware", isRunning: false),
        ])
        let sheet = SessionStatusSheet(
            viewModel: makeViewModel(),
            strip: strip,
            onOpenSubagent: { captured.append($0) }
        )

        // Exactly what the row's Button action does before dismissing.
        sheet.onOpenSubagent?("!c2:server")

        XCTAssertEqual(captured, ["!c2:server"],
                       "the sheet must hand the child's id back — ChatView's onDismiss pushes it")
    }

    func test_subagentsAndOnOpenSubagent_defaultToAbsent_soOtherCallSitesAreUnaffected() {
        let sheet = SessionStatusSheet(viewModel: makeViewModel())
        XCTAssertNil(sheet.strip)
        XCTAssertNil(sheet.onOpenSubagent)
    }

    // MARK: - rendering

    func test_sheet_withSubagents_rendersWithoutCrashing() async {
        let strip = await makeStrip([
            SubChatSummary(id: "!c1:server", title: "sweep the services", isRunning: true),
            SubChatSummary(id: "!c2:server", title: "read the middleware", isRunning: false),
        ])
        let sheet = SessionStatusSheet(
            viewModel: makeViewModel(),
            strip: strip,
            onOpenSubagent: { _ in }
        )

        let hostView = renderInWindow(sheet)

        XCTAssertTrue(
            uikitLabelTexts(in: hostView).contains("Session"),
            "sheet never mounted its NavigationStack chrome with a populated subagents list"
        )
    }

    func test_sheet_withNoSubagents_rendersWithoutCrashing() {
        let hostView = renderInWindow(SessionStatusSheet(viewModel: makeViewModel()))

        XCTAssertTrue(
            uikitLabelTexts(in: hostView).contains("Session"),
            "sheet never mounted its NavigationStack chrome with an empty subagents list"
        )
    }

    // MARK: - Rendering helpers

    @MainActor
    private func renderInWindow<V: View>(_ view: V) -> UIView {
        let hosting = UIHostingController(rootView: view)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        }
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        hosting.view.layoutIfNeeded()
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            hosting.view.layoutIfNeeded()
        }
        return hosting.view
    }

    private func uikitLabelTexts(in root: UIView) -> [String] {
        var out: [String] = []
        func visit(_ view: UIView) {
            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                out.append(text)
            }
            for sub in view.subviews { visit(sub) }
        }
        visit(root)
        return out
    }
}
