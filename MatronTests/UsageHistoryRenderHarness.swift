#if DEBUG
import SwiftUI
import UIKit
import XCTest
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels
@testable import Matron

/// Renders Boxes and its usage history on the iPhone to PNGs, from made-up
/// data, for pull requests. Off unless `USAGE_HISTORY_SHOTS` names a folder
/// on the Mac running the Simulator:
///
///     TEST_RUNNER_USAGE_HISTORY_SHOTS=/tmp/usage-history-shots scripts/ios-test.sh MatronTests/UsageHistoryRenderHarness
@MainActor
final class UsageHistoryRenderHarness: XCTestCase {
    private var deps: AppDependencies!
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        await deps?.stopMaintenanceForTests()
        deps = nil
        try await super.tearDown()
    }

    private func write(_ screen: some View, _ name: String, to directory: URL) throws {
        for dark in [false, true] {
            // A window outside a scene renders black, whatever it holds.
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            self.window?.isHidden = true
            self.window = window
            window.frame = scene.screen.bounds
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = UIHostingController(rootView: screen)
            window.makeKeyAndVisible()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let suffix = dark ? "-dark" : ""
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("iphone-\(name)\(suffix).png"))
        }
    }

    func test_writeRenders() async throws {
        let path = ProcessInfo.processInfo.environment["USAGE_HISTORY_SHOTS"] ?? ""
        try XCTSkipIf(path.isEmpty, "set USAGE_HISTORY_SHOTS to a folder")
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        deps = AppDependencies()
        let session = UserSession(userID: "alice", deviceID: "3", homeserverURL: URL(string: "https://journal.example")!,
                                  accessToken: "t")
        let boxes = BoxesViewModel(api: BoxesDemoData(), capacityCache: ApprovalFixtures.NoCapacityCache(),
                                   pollSleep: { try? await Task.sleep(for: .seconds(3600)) })
        await boxes.load()
        let history = UsageHistoryViewModel(api: BoxesDemoData())
        await history.load()

        // Boxes, with the new Usage history row.
        try write(NavigationStack {
            BoxesScreen(viewModel: boxes, deps: deps, session: session, isActive: false, onOpenChat: { _ in })
                .navigationTitle("Boxes")
        }, "boxes", to: directory)
        // Usage history: a card per account.
        try write(NavigationStack {
            UsageHistoryScreen(viewModel: history).navigationTitle("Usage history")
        }, "usage-history", to: directory)
        // The model meter, when an account reports one.
        if let model = history.choices.first(where: { $0.id != UsageMeterChoice.primaryID }) {
            history.choiceID = model.id
            try write(NavigationStack {
                UsageHistoryScreen(viewModel: history).navigationTitle("Usage history")
            }, "usage-history-model", to: directory)
        }
    }
}
#endif
