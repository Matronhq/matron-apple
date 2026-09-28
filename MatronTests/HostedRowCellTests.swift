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

    // MARK: - Safe area

    /// A view in a window that belongs to the scene, so the scene's safe
    /// area reaches it as it reaches a cell in the collection view. At `y`
    /// 0 the top safe area overlaps it; mid-screen nothing does.
    private func inScene(_ view: UIView, atY y: CGFloat) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let controller = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        view.frame.origin.y = y
        controller.view.addSubview(view)
        for _ in 0..<5 {
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Where the hosted content's rendered pieces sit, in `view`'s coordinates.
    private func pieces(in view: UIView) -> [String] {
        var pieces: [String] = []
        func visit(_ parent: UIView, hosted: Bool) {
            for subview in parent.subviews {
                let isHost = String(describing: type(of: subview)).contains("UIHostingContentView")
                if hosted {
                    let frame = subview.convert(subview.bounds, to: view)
                    pieces.append(String(format: "%@ %.1f %.1f %.1f %.1f", String(describing: type(of: subview)),
                                         frame.minX, frame.minY, frame.width, frame.height))
                }
                visit(subview, hosted: hosted || isHost)
            }
        }
        visit(view, hosted: false)
        return pieces
    }

    /// A probe with pieces UIKit can see: a label over a filled shape.
    struct Pieces: View {
        var body: some View {
            Text("Thinking…")
                .padding(6)
                .background(Capsule().fill(Color.red))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A row under the navigation bar as it scrolls, or beside the notch in
    /// landscape, draws its content where the layout put it.
    func test_hostedRow_staysPut_whenTheCellSitsInASafeArea() throws {
        func cell(atY y: CGFloat) throws -> HostedRowCell {
            let cell = HostedRowCell(frame: CGRect(x: 0, y: 0, width: 393, height: 40))
            cell.configure(rowID: "row-1", expectedHeight: 40, content: AnyView(Pieces()))
            try inScene(cell, atY: y)
            return cell
        }
        let clear = try cell(atY: 300)
        let under = try cell(atY: 0)
        XCTAssertEqual(clear.safeAreaInsets, .zero, "precondition: nothing overlaps a cell mid-screen")
        XCTAssertGreaterThan(under.safeAreaInsets.top, 0, "precondition: the top safe area overlaps this cell")
        let expected = pieces(in: clear)
        XCTAssertFalse(expected.isEmpty, "precondition: the content rendered")
        XCTAssertEqual(pieces(in: under), expected,
                       "a safe area must not move a hosted row's content (cell safe area \(under.safeAreaInsets))")
    }

    func test_footer_staysPut_whenItSitsInASafeArea() throws {
        func footer(atY y: CGFloat) throws -> TimelineFooterView {
            let footer = TimelineFooterView(frame: CGRect(x: 0, y: 0, width: 393, height: 30))
            footer.configure(content: AnyView(Pieces()))
            try inScene(footer, atY: y)
            return footer
        }
        let clear = try footer(atY: 300)
        let under = try footer(atY: 0)
        XCTAssertEqual(clear.safeAreaInsets, .zero, "precondition: nothing overlaps a footer mid-screen")
        XCTAssertGreaterThan(under.safeAreaInsets.top, 0, "precondition: the top safe area overlaps this footer")
        let expected = pieces(in: clear)
        XCTAssertFalse(expected.isEmpty, "precondition: the content rendered")
        XCTAssertEqual(pieces(in: under), expected,
                       "a safe area must not move the footer's content (footer safe area \(under.safeAreaInsets))")
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
