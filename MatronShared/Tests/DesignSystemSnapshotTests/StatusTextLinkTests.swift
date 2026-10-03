import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

/// Mission 7568: a project's status held `[#N](matron://item/N)`, drawn as
/// a link, and a tap did nothing. The status is a plain SwiftUI `Text`, so
/// the tap went to the default `\.openURL` and from there to the OS, which
/// has no handler for the `matron` scheme. These pin both halves of the
/// fix: what the status text marks as a link, and that `inAppLinks()` puts
/// the app's link policy in front of `\.openURL`.
@MainActor
final class StatusTextLinkTests: XCTestCase {

    private func links(_ text: AttributedString) -> [String] {
        text.runs.compactMap { $0.link?.absoluteString }
    }

    // MARK: - What the status text marks as a link

    func test_statusText_keepsTheLinksTheAppCanOpen() {
        let text = MissionsDashboardFormat.statusText(
            "Waiting on [#5](matron://item/5), see [the session](matron://convo/c-1), "
                + "[#61](matron://mission/61), [Promo](matron://project/12) and [docs](https://example.com/x).")
        XCTAssertEqual(links(text), ["matron://item/5", "matron://convo/c-1", "matron://mission/61",
                                     "matron://project/12", "https://example.com/x"])
    }

    /// A link the app would swallow does nothing under the finger, so it is
    /// not drawn as one. Its text stays.
    func test_statusText_dropsALinkTheAppWouldSwallow() {
        let text = MissionsDashboardFormat.statusText(
            "Pair with [this](matron://link?v=1&code=ABCD-1234) or [#0](matron://item/0), then [#5](matron://item/5).")
        XCTAssertEqual(links(text), ["matron://item/5"])
        XCTAssertEqual(String(text.characters), "Pair with this or #0, then #5.")
    }

    /// A card is one tap target: its text carries no link, so a tap on the
    /// link's words opens the card like a tap anywhere else on it.
    func test_statusPreviewText_carriesNoLinks() {
        let text = MissionsDashboardFormat.statusPreviewText(
            "Waiting on [#5](matron://item/5) and **[docs](https://example.com/x)**.")
        XCTAssertEqual(links(text), [])
        XCTAssertEqual(String(text.characters), "Waiting on #5 and docs.")
    }

    // MARK: - inAppLinks()

    /// Captures the `\.openURL` a `Text` below it would call on a tap.
    private struct OpenURLProbe: View {
        @Environment(\.openURL) private var openURL
        let capture: (OpenURLAction) -> Void

        var body: some View {
            let _ = capture(openURL)
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private func render(_ view: some View) {
        #if os(macOS)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 50, height: 50)
        host.layoutSubtreeIfNeeded()
        #else
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        host.view.layoutIfNeeded()
        #endif
    }

    func test_inAppLinks_routesMatronLinksToTheEnvironmentsHosts() throws {
        var items: [Int] = []
        var conversations: [String] = []
        var pages: [MatronPageLink] = []
        var captured: OpenURLAction?
        render(OpenURLProbe { captured = $0 }
            .inAppLinks()
            .environment(\.openTrackerItem) { items.append($0) }
            .environment(\.openConversation) { conversations.append($0) }
            .environment(\.openPageLink) { pages.append($0) })

        let openURL = try XCTUnwrap(captured, "the probe was rendered")
        for string in ["matron://item/5", "matron://convo/c-1", "matron://mission/61", "matron://project/12"] {
            openURL(try XCTUnwrap(URL(string: string)))
        }
        XCTAssertEqual(items, [5])
        XCTAssertEqual(conversations, ["c-1"])
        XCTAssertEqual(pages, [.mission(61), .project(12)])
    }

    /// With no host installed a `matron://` tap is consumed: `accepted`
    /// reports that the handler took it, i.e. it was not passed to the OS.
    func test_inAppLinks_withNoHost_stillKeepsMatronLinksFromTheSystem() throws {
        var captured: OpenURLAction?
        render(OpenURLProbe { captured = $0 }.inAppLinks())

        let openURL = try XCTUnwrap(captured, "the probe was rendered")
        let handled = expectation(description: "handled in-app")
        openURL(try XCTUnwrap(URL(string: "matron://item/5"))) { accepted in
            XCTAssertTrue(accepted)
            handled.fulfill()
        }
        wait(for: [handled], timeout: 2)
    }
}
