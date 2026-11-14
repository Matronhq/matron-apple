#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels
@testable import MatronMac

/// Renders the approval-key screens on the Mac to PNGs, from fixture data,
/// for pull requests. Off unless `APPROVAL_SHOTS` names a folder:
///
///     TEST_RUNNER_APPROVAL_SHOTS=/tmp/approval-shots xcodebuild test \
///       -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' \
///       -only-testing:MatronMacTests/MacApprovalRenderHarness
@MainActor
final class MacApprovalRenderHarness: XCTestCase {
    private var deps: AppDependencies!

    override func tearDown() async throws {
        await deps?.stopMaintenanceForTests()
        deps = nil
        try await super.tearDown()
    }

    private func write<V: View>(_ view: V, _ name: String, to directory: URL, dark: Bool = false) throws {
        for appearance in dark ? [NSAppearance.Name.aqua, .darkAqua] : [.aqua] {
            let host = MacSnapshotHost(view, appearance: appearance)
            defer { host.close() }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            let suffix = appearance == .darkAqua ? "-dark" : ""
            try XCTUnwrap(host.pngData()).write(to: directory.appendingPathComponent("mac-\(name)\(suffix).png"))
        }
    }

    func test_writeRenders() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try XCTUnwrap(environment["APPROVAL_SHOTS"], "set APPROVAL_SHOTS to a folder").nonEmpty()
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let method = "Touch ID"
        let size = ApprovalPromptPresenter.sheetSize

        // The confirm sheet, for each kind of approval.
        let confirms: [(String, ApprovalConfirmView.Model)] = [
            ("confirm-tap", ApprovalFixtures.tapModel(method: method)),
            ("confirm-consent", ApprovalFixtures.consentModel(method: method)),
            ("confirm-account", ApprovalFixtures.accountModel(method: method)),
            ("confirm-unlock", ApprovalFixtures.unlockModel(method: method)),
            ("confirm-refused", ApprovalFixtures.errorModel(method: method)),
        ]
        for (name, model) in confirms {
            try write(ApprovalConfirmView(model: model, onConfirm: {}, onCancel: {})
                .frame(width: size.width, height: size.height), name, to: directory, dark: name == "confirm-tap")
        }

        // Settings ▸ Approval keys, in each state.
        let scenes: [(String, ApprovalFixtures.Scene)] = [
            ("keys-not-set-up", .notSetUp), ("keys-ready", .ready), ("keys-waiting", .waiting), ("keys-reattach", .needsAttach),
        ]
        for (name, scene) in scenes {
            let model = await ApprovalFixtures.screenModel(scene, thisDevice: "alice's Mac Studio", method: method)
            try write(ApprovalKeysScreen(model: model).frame(width: 560, height: scene == .ready ? 760 : 520),
                      name, to: directory, dark: scene == .ready)
        }
        let setUp = await ApprovalFixtures.screenModel(.notSetUp, thisDevice: "alice's Mac Studio", method: method)
        try write(ApprovalKeyPasswordForm(model: setUp, form: .setUp), "keys-set-up-form", to: directory)

        // Boxes: locked, unlocked for a while, and in lockdown.
        deps = AppDependencies()
        let session = UserSession(userID: "alice", deviceID: "3", homeserverURL: URL(string: "https://journal.example")!,
                                  accessToken: "t")
        let boxes = await ApprovalFixtures.boxesViewModel()
        try write(MacBoxesPage(deps: deps, session: session, viewModel: boxes, onOpenConversation: { _ in })
            .frame(width: 1180, height: 560), "boxes-locked", to: directory)
        let locked = try XCTUnwrap(boxes.rows().first { $0.device.name == "box-a" })
        try write(BoxUnlockSheet(device: locked.device, viewModel: boxes, close: {}), "box-unlock", to: directory)

        // The locked-account banner.
        try write(AccountLockedBanner().frame(width: 900), "account-locked", to: directory)
    }
}

private extension String {
    func nonEmpty() throws -> String {
        try XCTSkipIf(isEmpty)
        return self
    }
}
#endif
