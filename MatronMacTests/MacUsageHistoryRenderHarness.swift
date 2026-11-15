#if os(macOS) && DEBUG
import AppKit
import SwiftUI
import XCTest
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels
@testable import MatronMac

/// Renders the Boxes page and its usage history on the Mac to PNGs, from
/// made-up data, for pull requests. Off unless `USAGE_HISTORY_SHOTS` names
/// a folder:
///
///     TEST_RUNNER_USAGE_HISTORY_SHOTS=/tmp/usage-history-shots xcodebuild test \
///       -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' \
///       -only-testing:MatronMacTests/MacUsageHistoryRenderHarness
@MainActor
final class MacUsageHistoryRenderHarness: XCTestCase {
    private var deps: AppDependencies!

    override func tearDown() async throws {
        await deps?.stopMaintenanceForTests()
        deps = nil
        try await super.tearDown()
    }

    private func write<V: View>(_ view: V, _ name: String, to directory: URL) throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = MacSnapshotHost(view, appearance: appearance)
            defer { host.close() }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
            let suffix = appearance == .darkAqua ? "-dark" : ""
            try XCTUnwrap(host.pngData()).write(to: directory.appendingPathComponent("mac-\(name)\(suffix).png"))
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

        // The Boxes page as it opens, with the new Now / Usage history switch.
        try write(MacBoxesPage(deps: deps, session: session, viewModel: boxes, historyViewModel: history,
                               onOpenConversation: { _ in })
            .frame(width: 1180, height: 760), "boxes-now", to: directory)
        // Usage history: an account per row, a week per column.
        try write(MacBoxesPage(deps: deps, session: session, viewModel: boxes, historyViewModel: history,
                               showsHistory: true, onOpenConversation: { _ in })
            .frame(width: 1180, height: 560), "usage-history", to: directory)
        // The model meter, when an account reports one.
        if let model = history.choices.first(where: { $0.id != UsageMeterChoice.primaryID }) {
            history.choiceID = model.id
            try write(MacBoxesPage(deps: deps, session: session, viewModel: boxes, historyViewModel: history,
                                   showsHistory: true, onOpenConversation: { _ in })
                .frame(width: 1180, height: 560), "usage-history-model", to: directory)
        }
    }
}

#endif
