#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac
import MatronModels

@MainActor
final class MacProjectPageSnapshotTests: XCTestCase {
    private typealias F = MacProjectPageFixtures

    func testOtherOpenItemsNeverGoesNegative() {
        XCTAssertEqual(MacProjectPageContent.otherOpenItems(F.page), 40)
        var none = F.page
        none.project = Project(id: "pj_1", num: 1, title: "P", openItems: 1)
        none.openItems = none.needsYou
        XCTAssertEqual(MacProjectPageContent.otherOpenItems(none), 0)
    }

    func testOtherOpenItemsCountsTheLocalRowsWhenTheJournalLags() {
        var lagging = F.page
        lagging.project = Project(id: "pj_1", num: 1, title: "P", openItems: 4)
        XCTAssertEqual(MacProjectPageContent.otherOpenItems(lagging), 10, "never fewer than the rows listed")
    }

    func testAwaitingLabels() {
        XCTAssertEqual(MacProjectItemRow.awaitingLabel(.agent), "agent")
        XCTAssertEqual(MacProjectItemRow.awaitingLabel(.user), "you")
        XCTAssertNil(MacProjectItemRow.awaitingLabel(nil))
    }

    /// Stand-in thumbnails: a soft two-tone "screenshot" per image blob.
    static let images: [String: Image] = {
        let tones: [(NSColor, NSColor)] = [(.init(white: 0.93, alpha: 1), .init(calibratedRed: 0.86, green: 0.80, blue: 0.70, alpha: 1)),
                                           (.init(calibratedRed: 0.17, green: 0.21, blue: 0.40, alpha: 1), .init(calibratedRed: 0.55, green: 0.60, blue: 0.80, alpha: 1)),
                                           (.init(calibratedRed: 0.86, green: 0.88, blue: 0.92, alpha: 1), .white),
                                           (.init(calibratedRed: 0.80, green: 0.70, blue: 0.56, alpha: 1), .init(white: 0.96, alpha: 1))]
        var out: [String: Image] = [:]
        for (blob, (back, panel)) in zip(["b1", "b2", "b4", "b5"], tones) {
            let image = NSImage(size: NSSize(width: 160, height: 120), flipped: false) { rect in
                back.setFill(); rect.fill()
                panel.setFill(); NSBezierPath(roundedRect: NSRect(x: 18, y: 18, width: 124, height: 46), xRadius: 6, yRadius: 6).fill()
                NSColor(white: 0.3, alpha: 0.35).setFill()
                NSBezierPath(roundedRect: NSRect(x: 18, y: 92, width: 60, height: 9), xRadius: 4, yRadius: 4).fill()
                NSBezierPath(roundedRect: NSRect(x: 18, y: 78, width: 104, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
                return true
            }
            out[blob] = Image(nsImage: image)
        }
        return out
    }()

    private func page(_ model: ProjectPageModel = F.page, width: CGFloat, height: CGFloat, selectedBox: String? = nil,
                      showsAllItems: Bool = false, showsClosed: Bool = false,
                      loadingMore: Set<ProjectFeedKind> = []) -> some View {
        VStack(spacing: 0) {
            MacProjectPageTopBar(page: model, actions: .init())
            Divider()
            MacProjectPageContent(page: model, actions: .init(), loadingMore: loadingMore, images: Self.images,
                                  selectedBox: selectedBox, showsAllItems: showsAllItems, showsClosed: showsClosed)
        }
        .frame(width: width, height: height)
        .environment(\.macMissionPageClock, F.now)
    }

    /// The roll-up at the window's usual width: decisions (an answered
    /// question, a reversed decision), files, milestones over two days.
    func testProjectPageWide() {
        assertVariants(of: page(F.pageWithFeed, width: 1_440, height: 2_000), named: "project-page-1440")
    }

    /// One column below 900 pt, "Show more" on Milestones loading.
    func testProjectPageNarrow() {
        assertVariants(of: page(F.pageWithFeed, width: 800, height: 3_400, loadingMore: [.milestones]),
                       named: "project-page-800")
    }

    /// A journal without the roll-up: today's page, latest steps and all.
    /// A box clicked (slate), every other open item unfolded.
    func testProjectPageFilteredAndExpanded() {
        assertVariants(of: page(width: 1_440, height: 1_500, selectedBox: "slate", showsAllItems: true),
                       named: "project-page-1440-filtered")
    }

    /// The Missions card's Closed fold open.
    func testProjectPageClosedMissionsUnfolded() {
        assertVariants(of: page(F.pageWithFeed, width: 1_440, height: 2_000, showsClosed: true),
                       named: "project-page-1440-closed")
    }
}
#endif
