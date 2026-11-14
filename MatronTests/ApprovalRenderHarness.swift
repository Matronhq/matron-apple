import SwiftUI
import UIKit
import XCTest
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels
@testable import Matron

/// Renders the approval-key screens on the iPhone to PNGs, from fixture
/// data, for pull requests. Off unless `APPROVAL_SHOTS` names a folder on
/// the Mac running the Simulator:
///
///     TEST_RUNNER_APPROVAL_SHOTS=/tmp/approval-shots scripts/ios-test.sh MatronTests/ApprovalRenderHarness
@MainActor
final class ApprovalRenderHarness: XCTestCase {
    private var deps: AppDependencies!
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        await deps?.stopMaintenanceForTests()
        deps = nil
        try await super.tearDown()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Draws `screen` full-screen, with `sheet` presented over it when
    /// given, and writes what the window shows.
    private func write(_ screen: some View, sheet: UIViewController? = nil, _ name: String, to directory: URL,
                       dark: Bool = false) throws {
        // A window outside a scene renders black, whatever it holds.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        self.window?.isHidden = true
        self.window = window
        window.frame = scene.screen.bounds
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let root = UIHostingController(rootView: screen)
        window.rootViewController = root
        window.makeKeyAndVisible()
        spin(0.8)
        if let sheet {
            root.present(sheet, animated: false)
            spin(0.8)
        }
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let suffix = dark ? "-dark" : ""
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("iphone-\(name)\(suffix).png"))
        if sheet != nil {
            root.dismiss(animated: false)
            spin(0.3)
        }
    }

    func test_writeRenders() async throws {
        let path = ProcessInfo.processInfo.environment["APPROVAL_SHOTS"] ?? ""
        try XCTSkipIf(path.isEmpty, "set APPROVAL_SHOTS to a folder")
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let method = "Face ID"
        let device = "alice's iPhone"

        // Settings ▸ Approval keys, in each state.
        let scenes: [(String, ApprovalFixtures.Scene)] = [
            ("keys-not-set-up", .notSetUp), ("keys-ready", .ready), ("keys-waiting", .waiting), ("keys-reattach", .needsAttach),
        ]
        var ready: ApprovalKeysScreenModel?
        for (name, scene) in scenes {
            let model = await ApprovalFixtures.screenModel(scene, thisDevice: device, method: method)
            if scene == .ready { ready = model }
            try write(NavigationStack { ApprovalKeysScreen(model: model) }, name, to: directory)
        }
        let readyModel = try XCTUnwrap(ready)
        try write(NavigationStack { ApprovalKeysScreen(model: readyModel) }, "keys-ready", to: directory, dark: true)

        // The password-and-code form, over the screen that opens it.
        let setUp = await ApprovalFixtures.screenModel(.notSetUp, thisDevice: device, method: method)
        let form = UIHostingController(rootView: ApprovalKeyPasswordForm(model: setUp, form: .setUp))
        try write(NavigationStack { ApprovalKeysScreen(model: setUp) }, sheet: form, "keys-set-up-form", to: directory)

        // Boxes: locked, unlocked for a while, and in lockdown.
        deps = AppDependencies()
        let session = UserSession(userID: "alice", deviceID: "3", homeserverURL: URL(string: "https://journal.example")!,
                                  accessToken: "t")
        let boxes = await ApprovalFixtures.boxesViewModel()
        let boxesScreen = NavigationStack {
            BoxesScreen(viewModel: boxes, deps: deps, session: session, isActive: false, onOpenChat: { _ in })
        }
        try write(boxesScreen, "boxes-locked", to: directory)
        let locked = try XCTUnwrap(boxes.rows().first { $0.device.name == "box-a" })
        let unlock = UIHostingController(rootView: BoxUnlockSheet(device: locked.device, viewModel: boxes, close: {}))
        // The app shows this sheet at half height. Its glass backdrop
        // draws black in an off-screen capture, so it is captured full
        // height here.
        unlock.sheetPresentationController?.detents = [.large()]
        try write(boxesScreen, sheet: unlock, "box-unlock", to: directory)

        // The confirm sheet, for each kind of approval, as the app
        // presents it.
        let confirms: [(String, ApprovalConfirmView.Model, Bool)] = [
            ("confirm-tap", ApprovalFixtures.tapModel(method: method), false),
            ("confirm-tap", ApprovalFixtures.tapModel(method: method), true),
            ("confirm-consent", ApprovalFixtures.consentModel(method: method), false),
            ("confirm-account", ApprovalFixtures.accountModel(method: method), false),
            ("confirm-unlock", ApprovalFixtures.unlockModel(method: method), false),
            ("confirm-refused", ApprovalFixtures.errorModel(method: method), false),
        ]
        for (name, model, dark) in confirms {
            let sheet = ApprovalPromptPresenter.sheetController(ApprovalConfirmView(model: model, onConfirm: {}, onCancel: {}))
            let behind = name == "confirm-unlock" ? AnyView(boxesScreen) : AnyView(NavigationStack { ApprovalKeysScreen(model: readyModel) })
            try write(behind, sheet: sheet, name, to: directory, dark: dark)
        }

        // The locked-account banner, across the top of a screen.
        let monitor = AccountLockMonitor()
        monitor.note(status: 423)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(monitor.isLocked)
        try write(boxesScreen.accountLockedBanner(monitor), "account-locked", to: directory)
    }
}
