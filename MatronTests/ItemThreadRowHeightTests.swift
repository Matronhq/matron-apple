import XCTest
import UIKit
import SwiftUI
import MatronDesignSystem
import MatronModels
@testable import Matron

/// Rows keep clear of each other when one changes height after its first
/// layout (a voice note's transcript arriving, a comment edited, a reply
/// delivered) and when a hosted piece draws taller than it was measured.
@MainActor
final class ItemThreadRowHeightTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)
    private let transcript = String(repeating: "These are the words of a long voice note. ", count: 14)

    private func model(voice: TrackerAttachment?, body: String = "", leading: Int = 0,
                       trailing: Int = 2) -> ItemDetailView.Model {
        let item = TrackerItem(id: "it_1", num: 1, kind: .question, title: "A thread", body: "The item's body.",
                               originConvoID: "c1", createdAt: t0, updatedAt: t0)
        var comments = [TrackerComment(id: "a", itemID: "it_1", author: .user, body: "An earlier reply.",
                                       createdAt: t0.addingTimeInterval(60)),
                        TrackerComment(id: "s", itemID: "it_1", author: .agent, kind: .status, body: "",
                                       createdAt: t0.addingTimeInterval(120)),
                        TrackerComment(id: "v", itemID: "it_1", author: .user, body: body,
                                       attachments: voice.map { [$0] } ?? [], createdAt: t0.addingTimeInterval(180))]
        comments = (0..<leading).map { index in
            TrackerComment(id: "l\(index)", itemID: "it_1", author: .agent,
                           body: String(repeating: "An earlier answer, a few lines long. ", count: 6),
                           createdAt: t0.addingTimeInterval(Double(index)))
        } + comments
        comments += (0..<trailing).map { index in
            TrackerComment(id: "t\(index)", itemID: "it_1", author: .agent, body: "A later reply.",
                           createdAt: t0.addingTimeInterval(Double(index) * 60 + 240))
        }
        return .init(item: item, comments: comments, pending: [], availableResolutions: [.done], isBusy: false)
    }

    private func voice(_ transcript: String?) -> TrackerAttachment {
        TrackerAttachment(blobRef: "b1", mime: "audio/mp4", name: "voice-note.m4a", size: 1, transcript: transcript,
                          transcriptStatus: transcript == nil ? "pending" : "done")
    }

    private func factory(_ model: ItemDetailView.Model, image: Image? = nil) -> ItemThreadPieceFactory {
        let detail = ItemDetailView(model: model, draft: .constant(""), image: { _ in image },
                                    onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                                    onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                                    now: t0.addingTimeInterval(86_400), startsAtBottom: true)
        return ItemThreadPieceFactory(detail: detail, environment: TimelineHostedEnvironment())
    }

    private func mount(_ factory: ItemThreadPieceFactory) throws -> (ItemThreadController, UIWindow) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let controller = ItemThreadController(factory: factory)
        window.rootViewController = controller
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.update(factory: factory)
        settle(window)
        return (controller, window)
    }

    private func settle(_ window: UIWindow) {
        for _ in 0..<5 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    /// No row's frame reaches into the next, and no cell on screen draws
    /// more than its frame holds.
    private func assertNothingOverlaps(_ controller: ItemThreadController, file: StaticString = #filePath,
                                       line: UInt = #line) {
        let frames = controller.framesForTesting
        for index in frames.minYs.indices.dropLast() {
            XCTAssertGreaterThanOrEqual(frames.minYs[index + 1],
                                        frames.minYs[index] + frames.heights[index] + ItemTypography.threadSpacing - 0.5,
                                        "row \(index) reaches into the next", file: file, line: line)
        }
        let live = controller.collectionView.subviews.compactMap { $0 as? UICollectionViewCell }.filter { !$0.isHidden }
        XCTAssertEqual(live.count, controller.collectionView.visibleCells.count, "a cell was left behind", file: file,
                       line: line)
        for cell in controller.collectionView.visibleCells {
            guard let index = controller.collectionView.indexPath(for: cell) else { continue }
            let item = controller.itemsForTesting[index.item]
            XCTAssertEqual(cell.frame, item.frame, "\(item.id) is not where the layout put it", file: file, line: line)
            guard let hosted = cell as? HostedRowCell else { continue }
            let fitting = hosted.fittingHeight()
            XCTAssertLessThanOrEqual(fitting, cell.bounds.height + 1, "\(item.id) draws past its frame", file: file,
                                     line: line)
        }
    }

    private func rowHeight(_ id: String, in controller: ItemThreadController) throws -> CGFloat {
        let item = try XCTUnwrap(controller.itemsForTesting.first { $0.id == "comment:\(id)|ground" })
        return item.frame.height
    }

    func test_aTranscriptArriving_growsItsCard_andPushesTheRowsBelowDown() throws {
        let (controller, window) = try mount(factory(model(voice: voice(nil))))
        let before = try rowHeight("v", in: controller)
        assertNothingOverlaps(controller)

        controller.update(factory: factory(model(voice: voice(transcript))), inSwiftUIUpdate: true)
        settle(window)
        XCTAssertGreaterThan(try rowHeight("v", in: controller), before + 150)
        assertNothingOverlaps(controller)
    }

    func test_aTranscriptArriving_onTheLastRow_keepsAReaderAtTheTailThere() throws {
        let (controller, window) = try mount(factory(model(voice: voice(nil), leading: 12, trailing: 0)))
        let view = controller.collectionView
        XCTAssertTrue(controller.geometry.atBottom && controller.geometry.scrollable)
        controller.update(factory: factory(model(voice: voice(transcript), leading: 12, trailing: 0)), inSwiftUIUpdate: true)
        settle(window)
        assertNothingOverlaps(controller)
        XCTAssertEqual(view.contentOffset.y, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom,
                       accuracy: 1)
    }

    func test_aTranscriptArriving_leavesAReaderUpTheThreadWhereTheyAre() throws {
        let (controller, window) = try mount(factory(model(voice: voice(nil), leading: 12, trailing: 0)))
        let view = controller.collectionView
        view.contentOffset.y = 300
        settle(window)
        controller.update(factory: factory(model(voice: voice(transcript), leading: 12, trailing: 0)), inSwiftUIUpdate: true)
        settle(window)
        XCTAssertEqual(view.contentOffset.y, 300, accuracy: 0.5)
    }

    func test_anEditedComment_growsItsCard_andPushesTheRowsBelowDown() throws {
        let (controller, window) = try mount(factory(model(voice: nil, body: "Short.")))
        let before = try rowHeight("v", in: controller)
        controller.update(factory: factory(model(voice: nil, body: transcript)), inSwiftUIUpdate: true)
        settle(window)
        XCTAssertGreaterThan(try rowHeight("v", in: controller), before + 150)
        assertNothingOverlaps(controller)
    }

    /// A picture the journal gave no size for takes its room when its
    /// bytes arrive: nothing in the model changes, its cell says it grew.
    func test_anImageArriving_growsItsCard_andPushesTheRowsBelowDown() throws {
        let picture = TrackerAttachment(blobRef: "p1", mime: "image/png", name: "one.png", size: 1)
        let model = model(voice: picture)
        let (controller, window) = try mount(factory(model))
        let before = try rowHeight("v", in: controller)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 600)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 600))
        }
        controller.update(factory: factory(model, image: Image(uiImage: image)), inSwiftUIUpdate: true)
        settle(window)
        settle(window)
        XCTAssertGreaterThan(try rowHeight("v", in: controller), before + 100)
        assertNothingOverlaps(controller)
    }

    // MARK: A note left when closing

    private let note = """
        Saved as a rule, so every new session follows it. The rules:
        1. Send a real browser User-Agent.
        2. Run the browser visibly on the display, not headless.
        3. Fall back in order: the feed, then the PDF, then the archive.
        4. Then have box-a fetch the page, or box-b if box-a is offline. No need to ask first.
        5. If that is blocked too, leave that site. No proxies or stealth tools.

        Our own zone stays on skip rules.
        """

    private func closed(with body: String) -> ItemDetailView.Model {
        var closed = model(voice: voice(transcript), trailing: 0)
        let open = TrackerItem.StatusSnapshot(state: .open, resolution: nil, awaiting: .agent)
        let done = TrackerItem.StatusSnapshot(state: .closed, resolution: .done, awaiting: nil)
        closed.comments.insert(TrackerComment(id: "note", itemID: "it_1", author: .agent, kind: .status, body: body,
                                              statusFrom: open, statusTo: done, createdAt: t0.addingTimeInterval(170)),
                               at: 2)
        return closed
    }

    /// The note is a card, measured as every card is: its line across the
    /// column, the card under it, and the next row a thread gap below. Drawn
    /// whole by SwiftUI it was measured shorter than it drew, lists most of
    /// all, and lay over the rows above and below it.
    func test_aNoteLeftWhenClosing_keepsClearOfTheRowsAroundIt() throws {
        let (controller, _) = try mount(factory(closed(with: note)))
        let items = controller.itemsForTesting.filter { $0.id.hasPrefix("comment:note") }
        let line = try XCTUnwrap(items.first { $0.id.hasSuffix("|0|hosted") })
        let ground = try XCTUnwrap(items.first { $0.kind == .ground })
        XCTAssertEqual(ground.frame.minY, line.frame.maxY + ItemDetailView.statusNoteSpacing)
        XCTAssertGreaterThan(ground.frame.height, 250, "the note's list is not measured")
        let frames = controller.framesForTesting
        XCTAssertEqual(frames.minYs[frames.minYs.count - 1], ground.frame.maxY + ItemTypography.threadSpacing, accuracy: 1)
        assertNothingOverlaps(controller)
    }

    // MARK: What a cell reports

    /// The screen is right when it and the measurement disagree: a piece
    /// measured too short takes the height it has in its cell, and the rows
    /// below move down with it.
    func test_piecesMeasuredTooShort_takeTheHeightTheyHaveOnScreen() throws {
        let model = model(voice: voice(transcript))
        let (right, _) = try mount(factory(model))
        let expected = right.framesForTesting

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1_400)
        let controller = ItemThreadController(factory: factory(model))
        let sizer = ItemPieceSizer()
        controller.measureHostedForTesting = { view, width in
            let size = sizer.size(of: view, maxWidth: width)
            return CGSize(width: size.width, height: max(0, size.height - 9))
        }
        window.rootViewController = controller
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.update(factory: factory(model))
        XCTAssertLessThan(controller.framesForTesting.contentHeight, expected.contentHeight - 30)
        settle(window)
        settle(window)
        XCTAssertEqual(controller.framesForTesting, expected)
        assertNothingOverlaps(controller)
    }

    /// A report is checked against its cell as it is now, so one that
    /// arrives late, after the row was laid out again, changes nothing.
    func test_aReportItsCellDoesNotBearOut_changesNothing() throws {
        let (controller, window) = try mount(factory(model(voice: nil, body: "A reply.")))
        let index = try XCTUnwrap(controller.itemsForTesting.firstIndex { $0.id == "comment:s" })
        let cell = try XCTUnwrap(controller.collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? HostedRowCell)
        let before = controller.framesForTesting
        let measured = controller.measureCount
        cell.onHeightChange?("comment:s", before.heights[controller.itemsForTesting[index].row] + 40)
        settle(window)
        XCTAssertEqual(controller.framesForTesting, before)
        XCTAssertEqual(controller.measureCount, measured)
    }

    // MARK: Through SwiftUI, as the app drives it

    @MainActor
    private final class Box: ObservableObject {
        @Published var model: ItemDetailView.Model
        init(_ model: ItemDetailView.Model) { self.model = model }
    }

    private struct Screen: View {
        @ObservedObject var box: Box
        let now: Date
        var body: some View {
            ItemNativeThreadView(detail: ItemDetailView(
                model: box.model, draft: .constant(""), image: { _ in nil },
                onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                now: now, startsAtBottom: true))
        }
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews { if let match = find(type, in: subview) { return match } }
        return nil
    }

    func test_throughSwiftUI_aVoiceNoteSentAndTranscribed_neverOverlaps() throws {
        var sending = model(voice: nil, trailing: 0)
        sending.comments.removeLast()
        sending.pending = [.init(id: "local", body: "", attachmentCount: 1, attempts: 0, lastError: nil)]
        let box = Box(sending)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIHostingController(rootView: Screen(box: box, now: t0.addingTimeInterval(86_400)))
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        settle(window)
        let collectionView = try XCTUnwrap(find(UICollectionView.self, in: window))
        let controller = try XCTUnwrap(collectionView.dataSource as? ItemThreadController)
        assertNothingOverlaps(controller)

        var queued = model(voice: voice(nil), trailing: 0)
        queued.queuedReplies = ["v": .sending]
        box.model = queued
        settle(window)
        assertNothingOverlaps(controller)

        box.model = model(voice: voice(nil), trailing: 0)
        settle(window)
        assertNothingOverlaps(controller)
        let before = try rowHeight("v", in: controller)

        box.model = model(voice: voice(transcript), trailing: 0)
        settle(window)
        XCTAssertGreaterThan(try rowHeight("v", in: controller), before + 150)
        assertNothingOverlaps(controller)

        box.model = model(voice: voice(transcript), trailing: 1)
        settle(window)
        assertNothingOverlaps(controller)

        box.model = closed(with: note)
        settle(window)
        assertNothingOverlaps(controller)
    }

    func test_aDeliveredReply_shrinksItsCard_andTheRowsBelowFollow() throws {
        var queued = model(voice: nil, body: "A reply the agent has not got yet.")
        queued.queuedReplies = ["v": .sending]
        let (controller, window) = try mount(factory(queued))
        let before = try rowHeight("v", in: controller)
        assertNothingOverlaps(controller)
        controller.update(factory: factory(model(voice: nil, body: "A reply the agent has not got yet.")),
                          inSwiftUIUpdate: true)
        settle(window)
        XCTAssertLessThan(try rowHeight("v", in: controller), before - 10)
        assertNothingOverlaps(controller)
    }
}
