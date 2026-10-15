#if os(macOS) && DEBUG
import XCTest
import AppKit
import SwiftUI
import QuartzCore
import MatronJournal
import MatronModels
import MatronStorage
import MatronViewModels
@testable import MatronMac

/// Profiling harness: the whole signed-in window (`MacChatListView` on a
/// real `AppDependencies` and journal store) under a steady stream of
/// journal writes — agent messages in a dozen live chats and the
/// Coordinator, session status flips, tracker items changing, missions
/// moving — at the rates a busy account sees. The writes go into the store
/// off the main thread, exactly as the sync engine's do, so every view
/// model reaches the window through its real observation path.
///
/// Three phases, each timed with a display link: the window idle while
/// the updates land, then trackpad-style scrolling of the conversation
/// list and of the open chat (after a quiet phase with nothing arriving,
/// the noise floor). Each phase reports frame gaps, stalls of 50 ms or
/// more with their recorded causes, CPU seconds, and how many
/// times each view model published and each heavy body re-evaluated.
///
/// Skipped unless `WINDOW_PERF=1` (pass `TEST_RUNNER_WINDOW_PERF=1` to
/// `xcodebuild test`). `WINDOW_PERF_SECONDS` sets the idle phase (default
/// 30), `WINDOW_PERF_OUT` the report file, `WINDOW_PERF_ARM` the label.
@MainActor
final class WindowLiveUpdatePerfHarness: XCTestCase {
    static let chats = 600
    static let liveChats = 12
    static let items = 2_000
    static let missions = 120
    static let coordinatorID = "perf-coordinator"
    static let openChatID = "perf-live-0"

    func test_windowUnderLiveUpdates() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["WINDOW_PERF"] == "1" else { throw XCTSkip("set WINDOW_PERF=1") }
        let idleSeconds = env["WINDOW_PERF_SECONDS"].flatMap(Double.init) ?? 30
        let arm = env["WINDOW_PERF_ARM"] ?? "?"

        let userID = "perf-\(UUID().uuidString.prefix(8))"
        let session = UserSession(userID: userID, deviceID: "perf-device",
                                  homeserverURL: URL(string: "https://journal.invalid")!, accessToken: "perf")
        UserDefaults.standard.set(Self.coordinatorID, forKey: CoordinatorSetting.defaultsKey(for: userID))
        let deps = AppDependencies()
        let store = deps.journalStore(for: session)
        defer {
            UserDefaults.standard.removeObject(forKey: CoordinatorSetting.defaultsKey(for: userID))
            let file = StoragePaths.appSupport.appendingPathComponent("journal-store/\(userID).sqlite")
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: file.path + suffix)
            }
        }
        let feed = Feed(store: store, ownSender: "user:\(userID)")
        try feed.seed()

        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1440, height: 900),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = MacChatListView(viewModel: ChatListViewModel(chat: deps.chatService(for: session)))
            .environment(\.appDependencies, deps)
            .environment(\.currentSession, session)
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await Self.spin(3)
        NotificationCenter.default.post(name: .matronPerfOpenConversation, object: Self.openChatID)
        await Self.spin(3)

        let sidebar = try XCTUnwrap(Self.sidebarScrollView(in: window.contentView), "no conversation list")
        let timeline = Self.timelineScrollView(in: window.contentView, excluding: sidebar)

        var lines = ["WINPERF arm=\(arm) chats=\(Self.chats) live=\(Self.liveChats) items=\(Self.items) missions=\(Self.missions) load=\(Self.loadAverage())"]
        // The noise floor: the same window with nothing arriving.
        lines.append(await measure("quiet", window: window) { frame in frame.elapsed >= 10 })

        let feeding = Task.detached(priority: .userInitiated) { await feed.run() }
        await Self.spin(2)
        lines.append(await measure("idle", window: window) { frame in frame.elapsed >= idleSeconds })
        lines.append(await measure("scroll-list", window: window, scrolling: sidebar))
        if let timeline {
            lines.append(await measure("scroll-chat", window: window, scrolling: timeline))
        } else {
            lines.append("WINPERF phase=scroll-chat skipped: no timeline scroll view")
        }
        feeding.cancel()
        await feeding.value
        lines.append("WINPERF feed writes=\(feed.writes)")
        let report = lines.joined(separator: "\n")
        print(report)
        try? report.write(toFile: env["WINDOW_PERF_OUT"] ?? "/tmp/winperf-last.txt", atomically: true, encoding: .utf8)
    }

    // MARK: Phases

    struct Frame { var elapsed: Double; var index: Int }

    /// Runs `step` once per display-link frame until it returns `true`, and
    /// reports the frame gaps, stalls and notes of that stretch.
    func measure(_ phase: String, window: NSWindow, scrolling scrollView: NSScrollView? = nil,
                 until done: ((Frame) -> Bool)? = nil) async -> String {
        let steps = 900
        let points: CGFloat = 14
        let stalls = StallList()
        let monitor = MainThreadStallMonitor(causes: .shared)
        monitor.start(interval: 0.02, threshold: 0.05, unresponsiveAfter: 10,
                      onStallExplained: { stalls.append($0, $1) })
        defer { monitor.stop() }
        StallCauseRecorder.shared.beginTally()
        let cpu0 = Self.cpuSeconds()
        var counter = HitchCounter()
        var direction: CGFloat = 1
        var lastY = scrollView?.contentView.bounds.origin.y ?? 0
        var stuck = 0
        if let scrollView { Self.sendScroll(to: scrollView, delta: 0, phase: .began) }
        let wall = await Self.runLink(on: window) { link, start, index in
            counter.frame(at: link.timestamp, duration: link.duration)
            if let scrollView {
                Self.sendScroll(to: scrollView, delta: points * direction, phase: .changed)
                let y = scrollView.contentView.bounds.origin.y
                if abs(y - lastY) < 0.5 { stuck += 1 } else { stuck = 0 }
                lastY = y
                if stuck > 20 { direction = -direction; stuck = 0 }
                return index >= steps
            }
            return done?(Frame(elapsed: link.timestamp - start, index: index)) ?? true
        }
        if let scrollView { Self.sendScroll(to: scrollView, delta: 0, phase: .ended) }
        await Self.spin(0.3)
        let cpu = Self.cpuSeconds() - cpu0
        let notes = StallCauseRecorder.shared.endTally()
        let listed = stalls.values
        let stallMs = listed.map { Int($0.0 * 1000) }
        var line = String(format: "WINPERF phase=%@ wall=%.1fs frames=%d hitches=%d hitchMs=%d maxGapMs=%d p99GapMs=%.1f gaps>100=%d cpu=%.2fs stalls>=50ms=%d stallMs=%d",
                          phase as NSString, wall, counter.frames, counter.hitches, Int(counter.hitchSeconds * 1000),
                          Int(counter.maxGap * 1000), counter.p99GapMs, counter.gapsOver100, cpu,
                          listed.count, stallMs.reduce(0, +))
        line += "\nWINPERF   notes: " + notes.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        for (hop, cause) in listed.prefix(8) {
            line += "\nWINPERF   stall \(Int(hop * 1000)) ms: \(cause)"
        }
        return line
    }

    // MARK: The feed

    /// Writes the seed and the live stream into the store. Not main-actor:
    /// the stream runs on a background task, like the sync engine.
    final class Feed: @unchecked Sendable {
        let store: JournalStore
        let ownSender: String
        private let lock = NSLock()
        private var _writes = 0
        private var seq: Int64 = 0
        private var rng = SplitMix(seed: 42)
        var writes: Int { lock.lock(); defer { lock.unlock() }; return _writes }

        init(store: JournalStore, ownSender: String) {
            self.store = store
            self.ownSender = ownSender
        }

        static func chatID(_ i: Int) -> String { i < WindowLiveUpdatePerfHarness.liveChats ? "perf-live-\(i)" : "perf-chat-\(i)" }

        func seed() throws {
            let now = Date()
            var convos: [ConvoSummaryDTO] = []
            for i in 0..<WindowLiveUpdatePerfHarness.chats {
                let ts = Int64((now.timeIntervalSince1970 - Double(i) * 1_800) * 1000)
                convos.append(ConvoSummaryDTO(id: Self.chatID(i), title: "Conversation \(i) about something",
                                              sessionState: i < WindowLiveUpdatePerfHarness.liveChats ? "running" : "idle", lastSeq: 0,
                                              snippet: "Last line of conversation \(i)", createdAt: ts - 86_400_000,
                                              lastTS: ts))
            }
            convos.append(ConvoSummaryDTO(id: WindowLiveUpdatePerfHarness.coordinatorID, title: "Coordinator",
                                          sessionState: "running", lastSeq: 0, snippet: "Status sweep",
                                          createdAt: Int64(now.timeIntervalSince1970 * 1000) - 86_400_000,
                                          lastTS: Int64(now.timeIntervalSince1970 * 1000)))
            try store.applyColdSnapshot(convos, headSeq: 0)
            // A real history in the open chat, so its timeline scrolls.
            var history: [JournalEvent] = []
            for n in 0..<300 {
                seq += 1
                history.append(event(convo: WindowLiveUpdatePerfHarness.openChatID, type: JournalEventType.text,
                                     sender: n % 3 == 0 ? ownSender : "agent:box-a",
                                     payload: ["body": Self.paragraph(n)],
                                     ts: now.addingTimeInterval(Double(n - 300) * 20)))
            }
            _ = try store.applyJournalBatch(history)
            try store.upsertItems((0..<WindowLiveUpdatePerfHarness.items).map { item($0, version: 0, now: now) })
            try store.upsertMissions((0..<WindowLiveUpdatePerfHarness.missions).map { mission($0, version: 0, now: now) })
        }

        /// The live stream: about six messages a second across the live
        /// chats and the Coordinator, a session status flip every couple
        /// of seconds, an item change every 1.5 s and a mission change
        /// every 3 s.
        func run() async {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(160))
                if Task.isCancelled { break }
                tick += 1
                let now = Date()
                do {
                    let target = next(WindowLiveUpdatePerfHarness.liveChats + 1)
                    let convo = target == WindowLiveUpdatePerfHarness.liveChats
                        ? WindowLiveUpdatePerfHarness.coordinatorID : Self.chatID(target)
                    let type = next(3) == 0 ? JournalEventType.toolOutput : JournalEventType.text
                    seq += 1
                    try store.applyJournal(event(convo: convo, type: type, sender: "agent:box-b",
                                                 payload: ["body": Self.paragraph(tick), "output": "ok \(tick)"], ts: now))
                    count()
                    if tick % 14 == 0 {
                        seq += 1
                        let state = tick % 28 == 0 ? "idle" : "running"
                        try store.applyJournal(event(convo: Self.chatID(next(WindowLiveUpdatePerfHarness.liveChats)),
                                                     type: JournalEventType.sessionStatus, sender: "agent:box-b",
                                                     payload: ["state": state], ts: now))
                        count()
                    }
                    if tick % 9 == 0 {
                        try store.upsertItems([item(next(80), version: tick, now: now)])
                        count()
                    }
                    if tick % 19 == 0 {
                        try store.upsertMissions([mission(next(30), version: tick, now: now)])
                        count()
                    }
                } catch {
                    print("WINPERF feed error: \(error)")
                }
            }
        }

        private func count() { lock.lock(); _writes += 1; lock.unlock() }
        private func next(_ n: Int) -> Int { lock.lock(); defer { lock.unlock() }; return Int(rng.next() % UInt64(n)) }

        private func event(convo: String, type: String, sender: String, payload: [String: Any], ts: Date) -> JournalEvent {
            JournalEvent(seq: seq, convoID: convo, ts: ts, sender: sender, type: type,
                         payloadData: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
        }

        /// The first 80 items are the busy ones: they change over the run,
        /// and every fifth of them awaits the user.
        private func item(_ i: Int, version: Int, now: Date) -> TrackerItem {
            let kinds: [ItemKind] = [.question, .task, .decision, .notice]
            let closed = i >= 400 && i % 2 == 0
            let awaiting: ItemAwaiting? = closed ? nil : ((i + version) % 5 == 0 ? .user : .agent)
            return TrackerItem(id: "perf-item-\(i)", num: 10_000 + i, kind: kinds[i % kinds.count],
                               state: closed ? .closed : .open, resolution: closed ? .done : nil, awaiting: awaiting,
                               rank: Double(i) * 1024, title: "Item \(i): something to look at",
                               originConvoID: Self.chatID(i % WindowLiveUpdatePerfHarness.chats),
                               createdAt: now.addingTimeInterval(-Double(i) * 3_600),
                               updatedAt: now.addingTimeInterval(-Double(i) * 60 + Double(version)),
                               closedAt: closed ? now.addingTimeInterval(-Double(i) * 600) : nil,
                               commentCount: version % 7, missionID: "perf-mission-\(i % WindowLiveUpdatePerfHarness.missions)",
                               missionNum: 20_000 + i % WindowLiveUpdatePerfHarness.missions)
        }

        private func mission(_ i: Int, version: Int, now: Date) -> Mission {
            Mission(id: "perf-mission-\(i)", num: 20_000 + i, title: "Mission \(i)", originConvoID: Self.chatID(i),
                    createdAt: now.addingTimeInterval(-Double(i) * 7_200),
                    updatedAt: now.addingTimeInterval(-Double(i) * 60 + Double(version)),
                    lastMilestoneAt: now.addingTimeInterval(-Double(i) * 120 + Double(version)),
                    openItems: 3 + version % 4, needsYou: (i + version) % 3, milestoneCount: 5 + version % 9,
                    status: "Working on step \(version % 5)", lastActivityAt: now)
        }

        static func paragraph(_ n: Int) -> String {
            "Update \(n): checked the build, the tests pass and the next step is the review. "
                + String(repeating: "More detail on what changed and why. ", count: 1 + n % 4)
        }
    }

    // MARK: Plumbing

    final class StallList: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(TimeInterval, String)] = []
        func append(_ hop: TimeInterval, _ cause: String) { lock.lock(); stored.append((hop, cause)); lock.unlock() }
        var values: [(TimeInterval, String)] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    final class LinkTarget: NSObject {
        var tick: ((CADisplayLink) -> Void)?
        @objc func fired(_ link: CADisplayLink) { tick?(link) }
    }

    /// Drives `body` once per frame until it returns `true`; returns the
    /// wall time taken.
    static func runLink(on window: NSWindow,
                        _ body: @escaping (CADisplayLink, CFTimeInterval, Int) -> Bool) async -> Double {
        guard let view = window.contentView else { return 0 }
        let target = LinkTarget()
        let link = view.displayLink(target: target, selector: #selector(LinkTarget.fired(_:)))
        return await withCheckedContinuation { continuation in
            var start: CFTimeInterval?
            var index = 0
            target.tick = { link in
                if start == nil { start = link.timestamp }
                index += 1
                if body(link, start!, index) {
                    link.invalidate()
                    target.tick = nil
                    continuation.resume(returning: link.timestamp - start!)
                }
            }
            link.add(to: .main, forMode: .common)
        }
    }

    static func sendScroll(to scrollView: NSScrollView, delta: CGFloat, phase: CGScrollPhase) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: Int32(delta.rounded()), wheel2: 0, wheel3: 0) else { return }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(delta))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(delta))
        if let window = scrollView.window {
            let mid = scrollView.convert(NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: nil)
            let screen = window.convertPoint(toScreen: mid)
            cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        }
        guard let event = NSEvent(cgEvent: cg) else { return }
        scrollView.scrollWheel(with: event)
    }

    static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        var found: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(visit)
        }
        visit(view)
        return found
    }

    /// The conversation list: the left-most scroll view holding a table.
    static func sidebarScrollView(in view: NSView?) -> NSScrollView? {
        scrollViews(in: view)
            .filter { $0.documentView is NSTableView && $0.frame.width > 100 }
            .min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    /// The open chat: the tallest other scroll view right of the list.
    static func timelineScrollView(in view: NSView?, excluding sidebar: NSScrollView) -> NSScrollView? {
        let listRight = sidebar.convert(sidebar.bounds, to: nil).maxX
        return scrollViews(in: view)
            .filter { $0 !== sidebar && $0.convert($0.bounds, to: nil).minX >= listRight - 1 }
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    static func spin(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return String(format: "%.1f", loads[0])
    }
}

/// A small seeded generator, so both arms of an A/B see the same stream.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
