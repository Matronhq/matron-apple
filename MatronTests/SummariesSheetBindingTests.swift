import XCTest
import SwiftUI
import UIKit
import MatronChat
import MatronModels
import MatronViewModels
@testable import Matron

/// Local fake mirrors `FakeTimelineForChat` in `ChatViewBindingTests.swift` —
/// same lightweight per-file pattern; only `summaryEntriesStream()` is
/// exercised here.
private final class FakeTimelineForSummaries: TimelineService, @unchecked Sendable {
    var summariesToEmit: [[ConversationSummaryEntry]] = []

    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}

    func summaryEntriesStream() -> AsyncStream<[ConversationSummaryEntry]> {
        let snapshots = summariesToEmit
        return AsyncStream { continuation in
            for s in snapshots { continuation.yield(s) }
            continuation.finish()
        }
    }
}

/// No-op MediaService — these tests never resolve an image.
private final class FakeMediaForSummaries: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

/// Renders a REAL `SummariesSheet` — a `UIHostingController` in a live,
/// scene-attached `UIWindow` (the `ComposerPasteSupportTests`/
/// `PasteMenuDiagnosticTests` pattern) — instead of merely constructing the
/// struct. A bare `let _ = SummariesSheet(viewModel:)` never evaluates
/// `body` at all (SwiftUI `View.body` is lazy), so it proves nothing beyond
/// "this compiles"; forcing a real host + window + layout pass is what
/// actually exercises `List(viewModel.summaryEntries)` / the
/// `ContentUnavailableView` branch against live view-model data and would
/// catch a runtime crash neither the old test nor `ChatViewModelTests
/// .testSummaryEntriesFlowFromServiceToViewModel` (C3's VM-only coverage)
/// can see.
///
/// IMPORTANT — what this test can and can't assert, after a genuine
/// investigation (see the fix report for task C5, 2026-08-10, for the full
/// trace): `SummariesSheet`'s body content (the `List` rows and the
/// `ContentUnavailableView` empty state) renders as three anonymous
/// `_TtC7SwiftUI...CGDrawingLayer` layers with NO per-row/per-text UIView or
/// UILabel substructure — confirmed via a live `recursiveDescription` dump
/// of the hosted view tree. The public accessibility-tree API
/// (`UIView.accessibilityElements`) reaches that hosting view but returns
/// an empty array even when the window is attached to a real, foreground
/// `UIWindowScene` — SwiftUI's accessibility bridge for this content
/// appears to require an actual connected AX client (VoiceOver / XCUITest's
/// accessibility server), which a plain `XCTestCase` unit-test host does
/// not provide. The legacy indexed container API
/// (`accessibilityElementCount()`/`accessibilityElement(at:)`) does
/// populate — but calling it deadlocked the entire test process (had to be
/// force-killed), so it is unsafe to use here. Snapshot-image testing
/// (`swift-snapshot-testing`, already used for `DesignSystemSnapshotTests`
/// in `MatronMacTests`) is not linked into the `MatronTests` iOS bundle
/// target (see `project.yml`) — wiring it in would be exactly the "new
/// dependency" instructed against. Genuinely reachable UIKit content is the
/// navigation bar's title `UILabel` (SwiftUI always bridges navigation
/// chrome to real `UIKit.UINavigationBar`/`UILabel`, unlike arbitrary body
/// content) — these tests assert against that AND against the view model
/// state the (successfully, crash-free) rendered `List`/empty-state is
/// bound to, which is the strongest verifiable combination available in
/// this target without adding a dependency or moving to an XCUITest target.
final class SummariesSheetBindingTests: XCTestCase {
    private var window: UIWindow!

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    @MainActor
    func test_sheet_rendersWithEntries_withoutCrashing_boundToNewestFirstOrder() async throws {
        let fake = FakeTimelineForSummaries()
        let older = ConversationSummaryEntry(seq: 10, toc: "Older pass", detail: "", date: .now)
        let newer = ConversationSummaryEntry(seq: 42, toc: "Newer pass", detail: "", date: .now)
        // The journal store query orders `seq DESC` (newest first) and
        // `JournalTimelineService.summaryEntriesStream()` maps that array
        // verbatim — a seeded fake emitting newest-first mirrors the real
        // backend's shape.
        fake.summariesToEmit = [[newer, older]]

        let chatVM = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaForSummaries())
        let task = await chatVM.start()
        await task.value

        // `summaryEntriesStream()` is drained by its own unstructured task
        // inside `start()` (not the one `task.value` awaits above), so poll
        // rather than assert immediately — same pattern
        // `ChatViewModelTests.testSessionStatusSubscriptionMergesPartialFrames`
        // uses for the sibling `sessionStatus()` stream.
        for _ in 0..<200 {
            if chatVM.summaryEntries.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(chatVM.summaryEntries.count, 2, "VM never populated summaryEntries — nothing for the sheet to render")

        let hostView = renderInWindow(SummariesSheet(viewModel: chatVM))

        // Proof the sheet actually mounted its `NavigationStack` chrome
        // against this exact view model (not just compiled).
        XCTAssertTrue(
            uikitLabelTexts(in: hostView).contains("Summaries"),
            "sheet's navigation title never rendered — the NavigationStack/toolbar wiring is broken"
        )
        // The `List` bound to this data rendered without crashing (the line
        // above already proved the view tree exists past first layout); the
        // order the RENDERED List would draw is exactly
        // `viewModel.summaryEntries`'s order, since `SummariesSheet` does
        // `List(viewModel.summaryEntries)` with no re-sort of its own (see
        // `SummariesSheet.swift`) — this is the strongest available pin on
        // "newest-first" reachable without a private/deadlocking API or a
        // new snapshot-testing dependency (see the type doc above).
        XCTAssertEqual(chatVM.summaryEntries.map(\.seq), [42, 10],
                       "the rendered List's source data must stay newest-first")
    }

    @MainActor
    func test_sheet_rendersEmptyState_withoutCrashing() async throws {
        let fake = FakeTimelineForSummaries()
        fake.summariesToEmit = [[]]

        let chatVM = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaForSummaries())
        let task = await chatVM.start()
        await task.value
        // Nothing to poll toward (target state IS empty) — give the
        // zero-entry stream frame a moment to land before rendering.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(chatVM.summaryEntries.isEmpty)

        let hostView = renderInWindow(SummariesSheet(viewModel: chatVM))

        // Proves the `ContentUnavailableView` empty-state branch renders
        // (rather than crashing/being skipped) for a genuinely empty VM —
        // same rendered-chrome pin as the populated-state test, since the
        // empty-state text itself is unreachable body content (see the type
        // doc above).
        XCTAssertTrue(
            uikitLabelTexts(in: hostView).contains("Summaries"),
            "sheet's navigation title never rendered for the empty state"
        )
    }

    // MARK: - Rendering helpers

    /// Hosts `view` in a real, key `UIWindow` attached to the test process's
    /// actual foreground `UIWindowScene` (falls back to a scene-less window
    /// if none is connected), forces layout, and gives SwiftUI's internal
    /// hosting/List machinery a few run-loop turns to finish mounting
    /// before returning the root `UIView` for inspection. Returns the
    /// hosting view directly (not the controller) since only its subtree is
    /// ever walked.
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

    /// Every non-empty `UILabel.text` reachable from `root` by walking
    /// `subviews` — a plain, public `UIView` traversal (no private
    /// selectors). SwiftUI bridges navigation chrome (titles, bar buttons)
    /// to real `UIKit.UILabel`s, so this reaches those; it does NOT reach
    /// arbitrary SwiftUI `Text` body content, which renders via opaque
    /// Core Graphics drawing layers with no `UILabel` backing (confirmed by
    /// a live `recursiveDescription` dump — see the type doc above).
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
