import XCTest
import UIKit
import SwiftUI
import MatronDesignSystem
import MatronModels
@testable import Matron

/// Profiling harness for typing in the For you search, on a For you list
/// the size of a busy account: the filter alone, and a list update (the
/// query changes and the view settles). Before the field kept its own
/// text, a list update ran on every keystroke; now it runs once typing
/// pauses. Skipped unless `FORYOU_PERF=1`.
///
/// - `FORYOU_PERF_OPEN` / `FORYOU_PERF_DONE`: items needing you / done
///   (default 150 / 3000), bodies of about 3 KB.
/// - `FORYOU_PERF_OUT`: where the report is written.
@MainActor
final class ForYouTypingPerfHarness: XCTestCase {
    @Observable final class Store {
        var awaiting: [TrackerItem] = []
        var decided: [TrackerItem] = []
        var tab: ForYouTab = .open
        var query = ""
    }

    /// The For you root as the tab hosts it: the model rebuilt from the
    /// store's lists and query on every change of either.
    struct Host: View {
        let store: Store
        var body: some View {
            NavigationStack {
                DecisionsListView(
                    model: .forYou(awaiting: store.awaiting, decided: store.decided,
                                   decidedVisibleCount: min(50, store.decided.count),
                                   hasMoreDecided: store.decided.count > 50, tab: store.tab, isSupported: true,
                                   isRefreshing: false, query: store.query, origin: { _ in "Proxy rollout" }),
                    onSelect: { _ in }, onOpenConversation: { _ in }, onRefresh: {})
                .navigationTitle("For you")
            }
        }
    }

    static let words = ["proxy", "timeout", "deploy", "parser", "review", "invoice", "screenshot", "journal",
                        "keyboard", "search", "release", "summary", "budget", "printer", "cover", "upload"]

    static func items(_ count: Int, prefix: String, state: ItemState) -> [TrackerItem] {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        return (0..<count).map { i in
            var body = "## Notes\n\n"
            var j = i
            while body.utf8.count < 3_000 {
                body += "- " + (0..<12).map { k in words[(j + k * 7) % words.count] }.joined(separator: " ") + ".\n"
                j += 3
            }
            return TrackerItem(id: "\(prefix)_\(i)", num: 10_000 + i, kind: i % 3 == 0 ? .notice : .question,
                               state: state, awaiting: .user, title: "Item \(i): \(words[i % words.count]) follow-up",
                               body: body, originConvoID: "c\(i % 40)", createdAt: t0, updatedAt: t0,
                               closedAt: state == .open ? nil : t0)
        }
    }

    static func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

    func test_profileTyping() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["FORYOU_PERF"] == "1", "set FORYOU_PERF=1 to profile")
        let open = Int(env["FORYOU_PERF_OPEN"] ?? "") ?? 150
        let done = Int(env["FORYOU_PERF_DONE"] ?? "") ?? 3000
        let store = Store()
        store.awaiting = Self.items(open, prefix: "o", state: .open)
        store.decided = Self.items(done, prefix: "d", state: .closed)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let host = UIHostingController(rootView: Host(store: store))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        var report = "For you typing: \(open) needing you, \(done) done, bodies about 3 KB\n"
        for tab in [ForYouTab.open, .closed] {
            store.tab = tab
            store.query = ""
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            var filter: [Double] = [], update: [Double] = []
            for _ in 0..<3 {
                for query in ["p", "pr", "pro", "prox", "proxy", "proxy ", "proxy t", "proxy ti", "proxy tim", ""] {
                    // The filter alone, as the tab's body runs it.
                    var start = CACurrentMediaTime()
                    _ = DecisionsListView.Model.forYou(
                        awaiting: store.awaiting, decided: store.decided, decidedVisibleCount: 50,
                        hasMoreDecided: true, tab: tab, isSupported: true, isRefreshing: false, query: query,
                        origin: { _ in "Proxy rollout" })
                    filter.append((CACurrentMediaTime() - start) * 1000)
                    // A list update: the query changes and the view settles.
                    start = CACurrentMediaTime()
                    store.query = query
                    RunLoop.main.run(until: Date())
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    CATransaction.flush()
                    update.append((CACurrentMediaTime() - start) * 1000)
                }
            }
            report += String(format: "%@ tab: filter median %.1f ms (max %.1f); list update median %.1f ms (max %.1f)\n",
                             tab == .open ? "Needs you" : "Done",
                             Self.median(filter), filter.max() ?? 0, Self.median(update), update.max() ?? 0)
        }
        print(report)
        try report.write(toFile: env["FORYOU_PERF_OUT"] ?? "/tmp/foryou-perf.txt", atomically: true, encoding: .utf8)
    }
}
