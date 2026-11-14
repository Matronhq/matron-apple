import UIKit
import XCTest
import MatronJournal
import MatronViewModels
@testable import Matron

/// The confirm sheet on the iPhone: presented over whatever is on screen
/// (another sheet included) when a request waits, dismissed when it is
/// answered, and a second request's sheet follows the first.
@MainActor
final class ApprovalPromptPresenterTests: XCTestCase {
    private var window: UIWindow!
    private var root: UIViewController!

    override func setUp() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        root.dismiss(animated: false)
        window.isHidden = true
        window = nil
        root = nil
    }

    private func wait(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// The controller on top of everything the window presents.
    private var top: UIViewController {
        var top: UIViewController = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    private let first = ApprovalRequest(kind: .account, subject: ["op": "change_password"], headline: "Change password")
    private let second = ApprovalRequest(kind: .account, subject: ["op": "link_device", "code": "BCDF2345"],
                                         headline: "Sign in a new device")

    func test_sheetIsPresentedForARequest_andDismissedWhenItIsAnswered() async throws {
        let center = await ApprovalFixtures.screenModel(.ready, thisDevice: "alice's iPhone", method: "Face ID").center
        let presenter = ApprovalPromptPresenter(center: center)
        _ = presenter
        let task = Task { try await center.sign(self.first) }
        try await wait("the sheet") { self.root.presentedViewController != nil }
        XCTAssertTrue(root.presentedViewController?.isModalInPresentation ?? false, "a swipe is not an answer")
        center.confirm()
        let approval = try await task.value
        XCTAssertNotNil(approval)
        try await wait("the sheet to go") { self.root.presentedViewController == nil }
    }

    func test_sheetIsPresentedOverAnotherSheet() async throws {
        // An account action is started from inside a sheet (the password
        // form): the confirm sheet goes on top of it and leaves it there.
        let form = UIViewController()
        root.present(form, animated: false)
        let center = await ApprovalFixtures.screenModel(.ready, thisDevice: "alice's iPhone", method: "Face ID").center
        let presenter = ApprovalPromptPresenter(center: center)
        _ = presenter
        let task = Task { try await center.sign(self.first) }
        try await wait("the sheet over the form") { form.presentedViewController != nil }
        center.cancel()
        _ = try? await task.value
        try await wait("the sheet to go") { form.presentedViewController == nil }
        XCTAssertTrue(root.presentedViewController === form, "the form is still up")
    }

    func test_aSecondRequestsSheetFollowsTheFirst_neverTwoAtOnce() async throws {
        let center = await ApprovalFixtures.screenModel(.ready, thisDevice: "alice's iPhone", method: "Face ID").center
        let presenter = ApprovalPromptPresenter(center: center)
        _ = presenter
        let one = Task { try await center.sign(self.first) }
        let two = Task { try await center.sign(self.second) }
        try await wait("the first sheet") { self.root.presentedViewController != nil && center.prompt?.request == self.first }
        let firstSheet = root.presentedViewController
        center.confirm()
        _ = try await one.value
        try await wait("the second sheet") {
            center.prompt?.request == self.second && self.root.presentedViewController != nil
                && self.root.presentedViewController !== firstSheet && self.root.presentedViewController?.isBeingPresented == false
        }
        XCTAssertNil(root.presentedViewController?.presentedViewController, "one confirm sheet, not two stacked")
        center.confirm()
        _ = try await two.value
        try await wait("the sheet to go") { self.root.presentedViewController == nil }
    }
}
