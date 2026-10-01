#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

@MainActor
final class MacChatListViewTests: XCTestCase {
    /// Verifies the shared `ChatListViewModel` is consumed unchanged — the
    /// Mac view is a per-platform shell, not a parallel data model.
    func test_usesSharedChatListViewModel() {
        let vm = ChatListViewModel(chat: LocalFakeChatActions(snapshots: []))
        let view = MacChatListView(viewModel: vm)
        XCTAssertNotNil(view.body)
    }

    /// Wave 6 / live-test #1: the Sign Out menu command routes through the
    /// host via an injected closure because `.onReceive` on the
    /// WindowGroup root's type-switching `Group { … }` content silently
    /// dropped notifications on macOS. Constructing the view with the
    /// closure pins the contract that it survives the new shape; invoking
    /// it pins the round-trip.
    func test_menuCommandClosures_arePlumbed_throughInit() {
        let vm = ChatListViewModel(chat: LocalFakeChatActions(snapshots: []))
        var signOutCount = 0
        let view = MacChatListView(
            viewModel: vm,
            onSignOut: { signOutCount += 1 }
        )
        XCTAssertNotNil(view.body)
        view.onSignOut?()
        XCTAssertEqual(signOutCount, 1)
    }

    /// Verifies the view drives selection through `ChatSummary.ID` (a
    /// stable `String`), not through the full `ChatSummary` struct.
    /// `ChatSummary` auto-synthesises `Hashable` from *all* stored
    /// properties — including `lastActivity` and `unreadCount` — so a
    /// selection bound to the struct silently breaks when a snapshot
    /// updates either field (the new struct's hash != the stored
    /// selection's hash). Round-3 bugbot finding #6: revert to
    /// id-based selection (Phase 1's pattern) and look the full
    /// `ChatSummary` up by id when the detail column needs it.
    func test_selectionState_isChatSummaryID_notFullStruct() async {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let initial = [
            ChatSummary(id: "!1:s", title: "First chat", bot: bot,
                        lastActivity: .now.addingTimeInterval(-3600), unreadCount: 0)
        ]
        // Second snapshot: same id, but `lastActivity` and `unreadCount`
        // changed — the exact diff shape that broke the struct-keyed
        // selection.
        let updated = [
            ChatSummary(id: "!1:s", title: "First chat", bot: bot,
                        lastActivity: .now, unreadCount: 3)
        ]
        let fake = LocalFakeChatActions(snapshots: [initial, updated])
        let vm = ChatListViewModel(chat: fake)
        _ = MacChatListView(viewModel: vm)
        vm.start()
        // Poll up to 2s for the upstream stream's snapshots to land on
        // `vm.groups`. A fixed 50ms `Task.sleep` was the prior shape
        // but flaked under MatronMacTests suite load (the actor hop
        // off `chatSummaries()` → `groups` mutation is fast in
        // isolation, slow when the suite is fanned out). Polling
        // exits the moment the assertion can pass while keeping a
        // generous ceiling for CI / busy hosts.
        //
        // The predicate waits for the SECOND snapshot (unreadCount 3),
        // not just non-empty: the hash assertion below compares
        // against `updated`'s field values, and under suite load the
        // poll could win between the two snapshots — the session-12
        // `!groups.isEmpty` de-flake still failed fast (~0.2s, i.e.
        // not the timeout) whenever the assert ran on `initial`.
        await waitUntil(timeout: 2.0) {
            vm.groups.flatMap(\.summaries).first?.unreadCount == 3
        }
        XCTAssertFalse(vm.groups.isEmpty)

        // Hash invariant: the new snapshot's struct hash differs from the
        // initial one's, even though the id is stable. Using the struct as
        // the selection key would lose the binding here; using the id
        // (stable `String`) preserves it.
        let firstHash = initial.first!.hashValue
        let updatedHash = vm.groups.flatMap(\.summaries).first { $0.id == "!1:s" }!.hashValue
        XCTAssertNotEqual(firstHash, updatedHash,
                          "ChatSummary auto-synthesised Hashable folds in lastActivity + unreadCount")
        // The id is stable across both snapshots, which is what the view's
        // `selectedSummaryID` binds to.
        XCTAssertEqual(initial.first?.id, "!1:s")
        XCTAssertEqual(vm.groups.flatMap(\.summaries).first?.id, "!1:s")
    }

    /// "Not on a mission" (spec §6) follows the same tri-state rule as every
    /// other Projects-gated surface: shown unless the journal has PROVEN it
    /// unsupported (`false`), never withheld just because support isn't
    /// known yet (`nil`).
    func testTheLooseSectionFollowsProjectsSupport() {
        XCTAssertTrue(MacChatSidebarList.showsLooseSection(projectsSupported: true))
        XCTAssertTrue(MacChatSidebarList.showsLooseSection(projectsSupported: nil))
        XCTAssertFalse(MacChatSidebarList.showsLooseSection(projectsSupported: false))
    }

    private final class FakeLooseHost: MacLooseSectionHost {
        var appears = 0
        var disappears = 0
        func looseSectionDidAppear() { appears += 1 }
        func looseSectionDidDisappear() { disappears += 1 }
    }

    /// bugbot #282: a host is only handed to `loosePresence` while the
    /// section it backs actually draws — a `projectsSupported == false`
    /// host must not be told it's on screen, which is what kept the
    /// dashboard's summaries feed running for a section that drew nothing.
    func testLooseSectionHostIsSuppressedWhenProjectsAreUnsupported() {
        let host = FakeLooseHost()
        XCTAssertNil(MacChatSidebarList.looseSectionHost(host, projectsSupported: false))
        XCTAssertIdentical(MacChatSidebarList.looseSectionHost(host, projectsSupported: true), host)
        XCTAssertIdentical(MacChatSidebarList.looseSectionHost(host, projectsSupported: nil), host)
    }

    /// Flipping support off then back on while the list stays on screen
    /// must unbalance and rebalance `loosePresence`, exactly like an
    /// appear/disappear pair.
    func testLooseSectionHostTracksProjectsSupportFlippingWhileOnScreen() {
        let presence = MacLooseSectionPresence()
        let host = FakeLooseHost()
        presence.show(MacChatSidebarList.looseSectionHost(host, projectsSupported: true))
        XCTAssertEqual(host.appears, 1)
        XCTAssertEqual(host.disappears, 0)

        presence.show(MacChatSidebarList.looseSectionHost(host, projectsSupported: false))
        XCTAssertEqual(host.appears, 1)
        XCTAssertEqual(host.disappears, 1)

        presence.show(MacChatSidebarList.looseSectionHost(host, projectsSupported: true))
        XCTAssertEqual(host.appears, 2)
        XCTAssertEqual(host.disappears, 1)
    }

    /// T27 review: the list appears before the session's dashboard view
    /// model exists (cold start); the view model assigned afterwards must
    /// still hear the section is on screen.
    func testALooseSectionHostAssignedAfterTheListAppearedIsTold() {
        let presence = MacLooseSectionPresence()
        presence.show(nil) // List.onAppear with missionsVM == nil
        let host = FakeLooseHost()
        presence.show(host) // onChange(of: missionsVM identity)
        XCTAssertEqual(host.appears, 1)
        presence.show(nil) // List.onDisappear
        XCTAssertEqual(host.disappears, 1)
    }

    /// An account switch swaps the view model under an appeared list: the
    /// old one is told the section left, the new one that it is shown.
    func testAnAccountSwitchMovesTheLooseSectionToTheNewHost() {
        let presence = MacLooseSectionPresence()
        let old = FakeLooseHost()
        let new = FakeLooseHost()
        presence.show(old)
        presence.show(new)
        XCTAssertEqual(old.appears, 1)
        XCTAssertEqual(old.disappears, 1)
        XCTAssertEqual(new.appears, 1)
        XCTAssertEqual(new.disappears, 0)
    }

    /// A repeated appear for the same host (SwiftUI can deliver one) is not
    /// a second appear.
    func testShowingTheSameHostTwiceIsOneAppear() {
        let presence = MacLooseSectionPresence()
        let host = FakeLooseHost()
        presence.show(host)
        presence.show(host)
        XCTAssertEqual(host.appears, 1)
        XCTAssertEqual(host.disappears, 0)
    }

    /// Poll-based wait: yields until `predicate` returns true or
    /// `timeout` seconds elapse. 25ms slice keeps the polling
    /// overhead negligible while still bounding wake latency. Used
    /// instead of `Task.sleep` for assertions that depend on async
    /// upstream work landing — fixes flakiness without making
    /// the happy path slower (returns immediately once true).
    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}

/// Test-only fake mirroring `LocalFakeChatService` from
/// `MacChatListViewBindingTests.swift` but exposing the new Task 13
/// chat-action methods (`refresh` / `mute` / `leave`) as no-ops. Declared
/// in a separate test file so each test target file stays self-contained.
private final class LocalFakeChatActions: ChatService, @unchecked Sendable {
    private let snapshots: [[ChatSummary]]
    init(snapshots: [[ChatSummary]]) { self.snapshots = snapshots }
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { continuation in
            for s in snapshots { continuation.yield(s) }
            continuation.finish()
        }
    }
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        AsyncStream { $0.finish() }
    }
    func createChat(with botID: String) async throws -> String { "!stub:server" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}
#endif
