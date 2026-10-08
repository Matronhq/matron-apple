import XCTest
@testable import MatronViewModels
@testable import MatronJournal

/// Settings ▸ Devices ▸ New sessions: a box's default agent, model and
/// effort (journal `PUT /devices/:id/defaults`, live as `box_defaults`).
@MainActor
final class DevicesViewModelBoxDefaultsTests: XCTestCase {
    private func box(_ id: Int64, _ defaults: BoxDefaults?) -> DeviceDTO {
        DeviceDTO(id: id, kind: "agent", name: "box-\(id)", createdAt: id, cursor: 0, lag: 0,
                  lastSeenAt: nil, isSelf: false, defaults: defaults)
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func loaded(_ fake: FakeDevicesProvider,
                        updates: (@Sendable () -> AsyncStream<BoxDefaultsUpdate>)? = nil) async -> DevicesViewModel {
        let vm = DevicesViewModel(api: fake, boxDefaultsUpdates: updates, onSelfRevoked: {})
        await vm.refresh()
        return vm
    }

    func test_editorShowsOnlyForAgentBoxesTheJournalReportsDefaultsFor() async {
        let fake = FakeDevicesProvider()
        fake.rosters = [[
            box(9, BoxDefaults(agent: "codex")),
            box(10, nil),
            DeviceDTO(id: 1, kind: "client", name: "mac", createdAt: 0, cursor: 0, lag: 0,
                      lastSeenAt: nil, isSelf: true),
        ]]
        let vm = await loaded(fake)
        XCTAssertTrue(vm.showsBoxDefaults(for: vm.devices.first { $0.id == 9 }!))
        XCTAssertFalse(vm.showsBoxDefaults(for: vm.devices.first { $0.id == 10 }!),
                       "no defaults key = an older journal: nothing to edit")
        XCTAssertFalse(vm.showsBoxDefaults(for: vm.devices.first { $0.id == 1 }!))
    }

    func test_pickShowsAtOnceThenTheJournalsAnswer() async {
        let fake = FakeDevicesProvider()
        fake.rosters = [[box(9, BoxDefaults(agent: "claude", model: "opus", effort: "high"))]]
        fake.storedBoxDefaults[9] = BoxDefaults(agent: "claude", model: "opus", effort: "high")
        fake.holdBoxDefaults = true
        let vm = await loaded(fake)

        let saving = Task { await vm.setBoxDefault(.agent, to: "codex", for: vm.devices[0]) }
        await waitUntil(fake.heldBoxDefaults == 1)
        // Optimistic, and the model goes with the agent like on the server.
        XCTAssertEqual(vm.devices[0].defaults, BoxDefaults(agent: "codex", model: nil, effort: "high"))

        fake.releaseBoxDefaults()
        await saving.value
        XCTAssertEqual(fake.boxDefaultsCalls.map(\.picks), [[.init(.agent, "codex")]])
        XCTAssertEqual(vm.devices[0].defaults, BoxDefaults(agent: "codex", model: nil, effort: "high"))
        XCTAssertNil(vm.errorMessage)
    }

    func test_unchangedPickSendsNothing() async {
        let fake = FakeDevicesProvider()
        fake.rosters = [[box(9, BoxDefaults(agent: "claude"))]]
        let vm = await loaded(fake)
        await vm.setBoxDefault(.agent, to: "claude", for: vm.devices[0])
        XCTAssertTrue(fake.boxDefaultsCalls.isEmpty)
    }

    func test_refusedPickGoesBackAndSaysWhy() async {
        let fake = FakeDevicesProvider()
        fake.rosters = [[box(9, BoxDefaults(agent: "codex", model: "gpt-5.1-codex"))]]
        fake.boxDefaultsError = .http(status: 400, message: "bad_model")
        let vm = await loaded(fake)

        await vm.setBoxDefault(.model, to: "nope!", for: vm.devices[0])
        XCTAssertEqual(vm.devices[0].defaults, BoxDefaults(agent: "codex", model: "gpt-5.1-codex"),
                       "a refused pick snaps back to what the journal holds")
        XCTAssertEqual(vm.errorMessage?.contains("box-9"), true)
        XCTAssertEqual(vm.errorMessage?.contains("model"), true)
        XCTAssertTrue(vm.boxDefaultsSupported)
    }

    func test_notFoundHidesTheEditor() async {
        let fake = FakeDevicesProvider()
        fake.rosters = [[box(9, BoxDefaults())]]
        fake.boxDefaultsError = .notFound
        let vm = await loaded(fake)

        await vm.setBoxDefault(.agent, to: "codex", for: vm.devices[0])
        XCTAssertFalse(vm.boxDefaultsSupported)
        XCTAssertFalse(vm.showsBoxDefaults(for: vm.devices[0]))
        XCTAssertEqual(vm.devices[0].defaults, BoxDefaults())
    }

    func test_liveFrameAppliesToItsBox() async {
        let fake = FakeDevicesProvider()
        fake.rosters = [[box(9, BoxDefaults()), box(10, BoxDefaults(agent: "claude"))]]
        let (stream, continuation) = AsyncStream<BoxDefaultsUpdate>.makeStream()
        let vm = await loaded(fake, updates: { stream })
        let listening = Task { await vm.listenForBoxDefaults() }

        continuation.yield(BoxDefaultsUpdate(deviceID: 9, defaults: BoxDefaults(agent: "codex", effort: "xhigh")))
        await waitUntil(vm.devices.first { $0.id == 9 }?.defaults?.agent == "codex")
        XCTAssertEqual(vm.devices.first { $0.id == 9 }?.defaults, BoxDefaults(agent: "codex", effort: "xhigh"))
        XCTAssertEqual(vm.devices.first { $0.id == 10 }?.defaults, BoxDefaults(agent: "claude"),
                       "another box is untouched")

        // A box the roster does not hold (yet) is ignored, not appended.
        continuation.yield(BoxDefaultsUpdate(deviceID: 77, defaults: BoxDefaults(agent: "codex")))
        continuation.finish()
        await listening.value
        XCTAssertEqual(vm.devices.map(\.id).sorted(), [9, 10])
    }

    /// Bugbot on PR 332: agent then model is the normal flow. The model
    /// picked while the agent's PUT is on the wire must survive that PUT's
    /// echo and answer, and reach the journal.
    func test_modelPickedDuringTheAgentSaveIsSentNextAndSurvivesTheEcho() async {
        let fake = FakeDevicesProvider()
        fake.rosters = [[box(9, BoxDefaults(agent: "claude", model: "opus"))]]
        fake.storedBoxDefaults[9] = BoxDefaults(agent: "claude", model: "opus")
        fake.holdBoxDefaults = true
        let (stream, continuation) = AsyncStream<BoxDefaultsUpdate>.makeStream()
        let vm = await loaded(fake, updates: { stream })
        let listening = Task { await vm.listenForBoxDefaults() }

        let saving = Task { await vm.setBoxDefault(.agent, to: "codex", for: vm.devices[0]) }
        await waitUntil(fake.heldBoxDefaults == 1)
        // Picked while the agent's PUT is in flight: queued, shown at once,
        // and this call returns without a PUT of its own.
        await vm.setBoxDefault(.model, to: "gpt-5.1-codex", for: vm.devices[0])
        XCTAssertEqual(fake.boxDefaultsCalls.count, 1, "one save at a time per box")
        XCTAssertEqual(vm.devices[0].defaults, BoxDefaults(agent: "codex", model: "gpt-5.1-codex"))

        // The first PUT's echo lands before its answer: held back, not shown.
        continuation.yield(BoxDefaultsUpdate(deviceID: 9, defaults: BoxDefaults(agent: "codex")))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.devices[0].defaults?.model, "gpt-5.1-codex", "an echo must not wipe a queued pick")

        fake.releaseBoxDefaults()
        await waitUntil(fake.heldBoxDefaults == 1 && fake.boxDefaultsCalls.count == 2)
        XCTAssertEqual(vm.devices[0].defaults, BoxDefaults(agent: "codex", model: "gpt-5.1-codex"),
                       "the answer shows with the queued pick on top")
        XCTAssertEqual(fake.boxDefaultsCalls.last?.picks, [.init(.model, "gpt-5.1-codex")])
        fake.releaseBoxDefaults()
        await saving.value

        XCTAssertEqual(fake.storedBoxDefaults[9], BoxDefaults(agent: "codex", model: "gpt-5.1-codex"))
        XCTAssertEqual(vm.devices[0].defaults, BoxDefaults(agent: "codex", model: "gpt-5.1-codex"))
        XCTAssertNil(vm.errorMessage)

        // With no save running, frames show again.
        continuation.yield(BoxDefaultsUpdate(deviceID: 9, defaults: BoxDefaults(agent: "claude")))
        await waitUntil(vm.devices[0].defaults?.agent == "claude")
        XCTAssertEqual(vm.devices[0].defaults, BoxDefaults(agent: "claude"))
        continuation.finish()
        await listening.value
    }

    func test_picksQueuedDuringASaveTravelTogether() async {
        let fake = FakeDevicesProvider()
        fake.rosters = [[box(9, BoxDefaults(agent: "claude"))]]
        fake.storedBoxDefaults[9] = BoxDefaults(agent: "claude")
        fake.holdBoxDefaults = true
        let vm = await loaded(fake)

        let saving = Task { await vm.setBoxDefault(.effort, to: "high", for: vm.devices[0]) }
        await waitUntil(fake.heldBoxDefaults == 1)
        await vm.setBoxDefault(.model, to: "opus", for: vm.devices[0])
        // A new agent drops the queued model (it was a Claude alias)…
        await vm.setBoxDefault(.agent, to: "codex", for: vm.devices[0])
        // …and a model picked after it travels with it.
        await vm.setBoxDefault(.model, to: "gpt-5.1-codex", for: vm.devices[0])
        await vm.setBoxDefault(.effort, to: "minimal", for: vm.devices[0])
        fake.releaseBoxDefaults()
        await waitUntil(fake.heldBoxDefaults == 1 && fake.boxDefaultsCalls.count == 2)
        XCTAssertEqual(fake.boxDefaultsCalls.last?.picks,
                       [.init(.agent, "codex"), .init(.model, "gpt-5.1-codex"), .init(.effort, "minimal")])
        fake.releaseBoxDefaults()
        await saving.value
        XCTAssertEqual(vm.devices[0].defaults, BoxDefaults(agent: "codex", model: "gpt-5.1-codex", effort: "minimal"))
        XCTAssertEqual(fake.storedBoxDefaults[9], vm.devices[0].defaults)
    }

    func test_refusalFallsBackToTheLatestFrameHeldDuringTheSave() async {
        let fake = FakeDevicesProvider()
        fake.rosters = [[box(9, BoxDefaults(agent: "claude"))]]
        fake.holdBoxDefaults = true
        fake.boxDefaultsError = .transport("offline")
        let (stream, continuation) = AsyncStream<BoxDefaultsUpdate>.makeStream()
        let vm = await loaded(fake, updates: { stream })
        let listening = Task { await vm.listenForBoxDefaults() }

        let saving = Task { await vm.setBoxDefault(.effort, to: "max", for: vm.devices[0]) }
        await waitUntil(fake.heldBoxDefaults == 1)
        // Another device sets the box while this PUT is in flight: held.
        continuation.yield(BoxDefaultsUpdate(deviceID: 9, defaults: BoxDefaults(agent: "codex")))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.devices[0].defaults, BoxDefaults(agent: "claude", effort: "max"))
        fake.releaseBoxDefaults()
        await saving.value

        XCTAssertEqual(vm.devices[0].defaults, BoxDefaults(agent: "codex"),
                       "nothing was written: the newest journal state is the held frame")
        XCTAssertNotNil(vm.errorMessage)
        continuation.finish()
        await listening.value
    }
}
