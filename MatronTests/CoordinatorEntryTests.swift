import XCTest
import SwiftUI
import UIKit
@testable import Matron

private final class EnvBox { var seen: [Bool] = [] }

private struct EnvProbe: View {
    let box: EnvBox
    @Environment(\.openCoordinator) private var openCoordinator
    var body: some View { Color.clear.onAppear { box.seen.append(openCoordinator != nil) } }
}

@MainActor
final class CoordinatorEntryTests: XCTestCase {
    private var window: UIWindow!

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    func test_openCoordinatorAction_runsItsBody() {
        var runs = 0
        let action = OpenCoordinatorAction { runs += 1 }
        action()
        XCTAssertEqual(runs, 1)
    }

    func test_outsideTheSheet_theShellActionReachesAChat() {
        let box = EnvBox()
        render(EnvProbe(box: box).environment(\.openCoordinator, OpenCoordinatorAction {}))
        XCTAssertEqual(box.seen, [true])
    }

    /// Review focus: the Coordinator's own chat offers no way to open the
    /// Coordinator (a second copy on its own stack).
    func test_insideTheCoordinatorSheet_entriesAreHidden() {
        let box = EnvBox()
        render(InsideCoordinatorSheet { EnvProbe(box: box) }.environment(\.openCoordinator, OpenCoordinatorAction {}))
        XCTAssertEqual(box.seen, [false])
    }

    func test_floatingButton_labelsTheUnreadDot_andTaps() {
        XCTAssertEqual(CoordinatorFloatingButton.accessibilityLabel(hasUnread: false), "Coordinator")
        XCTAssertEqual(CoordinatorFloatingButton.accessibilityLabel(hasUnread: true), "Coordinator, unread messages")
        var taps = 0
        CoordinatorFloatingButton(hasUnread: true) { taps += 1 }.action()
        XCTAssertEqual(taps, 1)
    }

    private func render<V: View>(_ view: V) {
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
}
