import XCTest
import SwiftUI
import UIKit
@testable import Matron

/// Hosted rows keep cached sizes but re-report when their SwiftUI content
/// changes size on its own (an ask card answered, an image landing, a live
/// output tile growing) — the controller re-lays out that row only.
@MainActor
final class HostedRowCellTests: XCTestCase {
    @Observable final class HeightBox { var height: CGFloat = 40 }

    struct Probe: View {
        let box: HeightBox
        var body: some View { Color.red.frame(height: box.height) }
    }

    private func mount(_ view: UIView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 400))
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.layoutIfNeeded()
        return window
    }

    func test_reportsAHeightChange_whenHostedContentGrows() async throws {
        let box = HeightBox()
        let cell = HostedRowCell(frame: CGRect(x: 0, y: 0, width: 393, height: 40))
        var reports: [(String, CGFloat)] = []
        cell.onHeightChange = { reports.append(($0, $1)) }
        cell.configure(rowID: "row-1", expectedHeight: 40, content: AnyView(Probe(box: box)))
        let window = mount(cell)
        box.height = 90
        try await waitUntil { !reports.isEmpty }
        XCTAssertEqual(reports.last?.0, "row-1")
        XCTAssertEqual(reports.last?.1, 90)
        _ = window
    }

    func test_doesNotReportWhenTheHeightMatches() async throws {
        let cell = HostedRowCell(frame: CGRect(x: 0, y: 0, width: 393, height: 40))
        var reports = 0
        cell.onHeightChange = { _, _ in reports += 1 }
        cell.configure(rowID: "row-1", expectedHeight: 40, content: AnyView(Probe(box: HeightBox())))
        let window = mount(cell)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(reports, 0)
        _ = window
    }

    func test_footerView_hostsItsContentEdgeToEdge() {
        let footer = TimelineFooterView(frame: CGRect(x: 0, y: 0, width: 393, height: 30))
        footer.configure(content: AnyView(Text("Thinking…")))
        footer.layoutIfNeeded()
        XCTAssertEqual(footer.subviews.count, 1)
        XCTAssertEqual(footer.subviews.first?.frame, footer.bounds)
    }

    /// `UIHostingConfiguration`'s content view traps if `.configuration` is
    /// later set to a different `Content` TYPE than the one it was created
    /// with — a real reuse cycle exercises exactly that assignment
    /// (`prepareForReuse` then a fresh `configure`), so a regression here
    /// is a crash, not a wrong value.
    func test_reuseCycleDoesNotTrap() {
        let cell = HostedRowCell(frame: CGRect(x: 0, y: 0, width: 393, height: 40))
        cell.configure(rowID: "row-1", expectedHeight: 40, content: AnyView(Text("hi")))
        cell.layoutIfNeeded()
        cell.prepareForReuse()
        cell.configure(rowID: "row-2", expectedHeight: 40, content: AnyView(Text("bye")))
        cell.layoutIfNeeded()
    }
}
