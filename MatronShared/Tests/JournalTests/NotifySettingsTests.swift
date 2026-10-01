import XCTest
@testable import MatronJournal

/// The `/notify` contract (journal src/notify-http.js + src/notify.js): the
/// view's shape, the `PUT` bodies, the live frame, and the optimistic copy
/// matching what the journal does with each change.
final class NotifySettingsTests: XCTestCase {
    private static let viewBody: [String: Any] = [
        "mode": "custom",
        "events": ["prompts": true, "questions": true, "coordinator_done": false, "other_done": true,
                   "stopped": false, "rooms": true, "activity": false],
        "has_coordinator": true,
        "device_level": "needs_me",
        "convos": [
            ["convo_id": "c1", "level": "none", "mute_until": NSNull()],
            ["convo_id": "c2", "level": NSNull(), "mute_until": 1_790_000_000_000 as Int64],
        ],
    ]

    private func makeStubbedAPI(status: Int = 200, body: [String: Any] = viewBody) -> JournalAPI {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: "t")
    }

    private func sentBody() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as? [String: Any])
    }

    private func baseView(mode: NotifySettings.Mode = .coordinator,
                          convos: [NotifySettings.ConvoOverride] = []) -> NotifyView {
        NotifyView(settings: NotifySettings(mode: mode, events: NotifySettings.preset(mode) ?? [:],
                                            hasCoordinator: true, convos: convos),
                   deviceLevel: .all)
    }

    // MARK: - Decoding

    func testGetDecodesTheWholeView() async throws {
        let view = try await makeStubbedAPI().notifySettings()
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/notify") == true)
        XCTAssertEqual(view.settings.mode, .custom)
        XCTAssertEqual(view.settings.events[.otherDone], true)
        XCTAssertEqual(view.settings.events[.coordinatorDone], false)
        XCTAssertEqual(view.settings.events[.rooms], true)
        XCTAssertTrue(view.settings.hasCoordinator)
        XCTAssertEqual(view.deviceLevel, .needsMe)
        XCTAssertEqual(view.settings.convos, [
            .init(convoID: "c1", level: .silent, muteUntil: nil),
            .init(convoID: "c2", level: nil, muteUntil: Date(timeIntervalSince1970: 1_790_000_000)),
        ])
    }

    func testDecodeKeepsPromptsOnAndSkipsWhatItCannotRead() {
        let decoded = NotifySettings.decode([
            "mode": "all",
            "events": ["prompts": false, "questions": true, "future_kind": true],
            "convos": [["level": "all"], ["convo_id": "c3", "level": "loud"]],
        ])
        XCTAssertEqual(decoded?.isOn(.prompts), true, "prompts cannot be switched off")
        XCTAssertEqual(decoded?.events[.prompts], true)
        XCTAssertEqual(decoded?.events[.stopped], false, "a missing switch reads as off")
        XCTAssertEqual(decoded?.hasCoordinator, false)
        XCTAssertEqual(decoded?.convos, [.init(convoID: "c3", level: nil, muteUntil: nil)],
                       "a row with no id is dropped; an unknown level reads as follow-the-mode")
        XCTAssertNil(NotifySettings.decode(["mode": "loud"]))
        XCTAssertNil(NotifyView.decode(["events": [:]]))
        XCTAssertEqual(NotifyView.decode(["mode": "coordinator"])?.deviceLevel, .all,
                       "a view without device_level reads as the journal's default")
    }

    func testMalformedViewIsATransportError() async {
        do {
            _ = try await makeStubbedAPI(body: ["mode": "nope"]).notifySettings()
            XCTFail("expected a transport error")
        } catch {
            guard case .transport = error as? JournalAPIError else { return XCTFail("got \(error)") }
        }
    }

    // MARK: - PUT bodies

    func testPutBodies() async throws {
        let api = makeStubbedAPI()

        _ = try await api.updateNotify(.mode(.all))
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "PUT")
        XCTAssertEqual(try sentBody() as NSDictionary, ["mode": "all"])

        _ = try await api.updateNotify(.event(.otherDone, true))
        XCTAssertEqual(try sentBody() as NSDictionary, ["events": ["other_done": true]])

        _ = try await api.updateNotify(.deviceLevel(.off))
        XCTAssertEqual(try sentBody() as NSDictionary, ["device_level": "off"])

        _ = try await api.updateNotify(.convoLevel(convoID: "c1", .needsMe))
        XCTAssertEqual(try sentBody() as NSDictionary, ["convo": ["convo_id": "c1", "level": "needs_me"]])

        _ = try await api.updateNotify(.convoLevel(convoID: "c1", nil))
        XCTAssertEqual(try sentBody() as NSDictionary, ["convo": ["convo_id": "c1", "level": NSNull()]],
                       "follow-the-mode is an explicit null, and leaves the mute alone")

        _ = try await api.updateNotify(.convoMute(convoID: "c1", until: Date(timeIntervalSince1970: 1_790_000_000.25)))
        XCTAssertEqual(try sentBody() as NSDictionary, ["convo": ["convo_id": "c1", "mute_until": 1_790_000_000_250]],
                       "mute_until is integer epoch milliseconds")

        _ = try await api.updateNotify(.convoMute(convoID: "c1", until: nil))
        XCTAssertEqual(try sentBody() as NSDictionary, ["convo": ["convo_id": "c1", "mute_until": NSNull()]])

        _ = try await api.updateNotify(.clearConvo(convoID: "c1"))
        XCTAssertEqual(try sentBody() as NSDictionary,
                       ["convo": ["convo_id": "c1", "level": NSNull(), "mute_until": NSNull()]])
    }

    func testPutOfAConvoNotOwnedIsNotFound() async {
        do {
            _ = try await makeStubbedAPI(status: 404, body: ["error": "not_found"])
                .updateNotify(.convoLevel(convoID: "c-else", .all))
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .notFound)
        }
    }

    // MARK: - Live frame

    func testDecodesNotifyFrame() {
        let frame = ServerFrame.decode(#"""
        {"kind":"notify","settings":{"mode":"all","events":{"prompts":true,"questions":true,
         "coordinator_done":true,"other_done":true,"stopped":true,"rooms":false,"activity":false},
         "has_coordinator":false,"convos":[{"convo_id":"c1","level":"needs_me","mute_until":null}]}}
        """#)
        guard case .notify(let settings) = frame else {
            return XCTFail("expected a notify frame, got \(String(describing: frame))")
        }
        XCTAssertEqual(settings.mode, .all)
        XCTAssertEqual(settings.events, NotifySettings.preset(.all))
        XCTAssertFalse(settings.hasCoordinator)
        XCTAssertEqual(settings.convos, [.init(convoID: "c1", level: .needsMe)])
        // Malformed frames are skipped, not crashed on.
        XCTAssertNil(ServerFrame.decode(#"{"kind":"notify"}"#))
        XCTAssertNil(ServerFrame.decode(#"{"kind":"notify","settings":{"mode":"loud"}}"#))
    }

    // MARK: - Optimistic copy

    func testEventOnAPresetMovesToCustomFromThatPreset() {
        let view = NotifyChange.event(.rooms, true).applied(to: baseView(mode: .coordinator))
        XCTAssertEqual(view.settings.mode, .custom)
        var expected = NotifySettings.preset(.coordinator)!
        expected[.rooms] = true
        XCTAssertEqual(view.settings.events, expected)
        XCTAssertEqual(NotifyChange.event(.prompts, false).applied(to: baseView()).settings.events[.prompts], true,
                       "prompts stays on")
    }

    func testModeTakesThePresetAndCustomKeepsTheSwitchesShowing() {
        let all = NotifyChange.mode(.all).applied(to: baseView(mode: .coordinator))
        XCTAssertEqual(all.settings.events, NotifySettings.preset(.all))
        let custom = NotifyChange.mode(.custom).applied(to: all)
        XCTAssertEqual(custom.settings.mode, .custom)
        XCTAssertEqual(custom.settings.events, NotifySettings.preset(.all))
    }

    func testConvoChangesEditOneRowAndDropAnEmptyOne() {
        let mute = Date(timeIntervalSince1970: 2_000_000_000)
        var view = baseView(convos: [.init(convoID: "c0", level: .all)])
        view = NotifyChange.convoLevel(convoID: "c1", .needsMe).applied(to: view)
        view = NotifyChange.convoMute(convoID: "c1", until: mute).applied(to: view)
        XCTAssertEqual(view.settings.convos, [.init(convoID: "c1", level: .needsMe, muteUntil: mute),
                                              .init(convoID: "c0", level: .all)])
        view = NotifyChange.convoLevel(convoID: "c1", nil).applied(to: view)
        XCTAssertEqual(view.settings.override(for: "c1"), .init(convoID: "c1", level: nil, muteUntil: mute),
                       "clearing the level keeps the mute")
        view = NotifyChange.convoMute(convoID: "c1", until: nil).applied(to: view)
        XCTAssertNil(view.settings.override(for: "c1"), "a row with neither is gone, as the journal deletes it")
        view = NotifyChange.clearConvo(convoID: "c0").applied(to: view)
        XCTAssertTrue(view.settings.convos.isEmpty)
        XCTAssertEqual(NotifyChange.deviceLevel(.off).applied(to: view).deviceLevel, .off)
    }

    // MARK: - Mutes

    func testMuteRunsUntilItsEnd() {
        let end = Date(timeIntervalSince1970: 1_000)
        let row = NotifySettings.ConvoOverride(convoID: "c1", muteUntil: end)
        XCTAssertTrue(row.isMuted(at: end.addingTimeInterval(-1)))
        XCTAssertTrue(row.isActive(at: end.addingTimeInterval(-1)))
        XCTAssertFalse(row.isMuted(at: end), "the mute ends at mute_until, as the journal compares mute_until > now")
        XCTAssertFalse(row.isActive(at: end))
        XCTAssertTrue(NotifySettings.ConvoOverride(convoID: "c1", level: .all, muteUntil: end).isActive(at: end),
                      "a level outlives its mute")
    }

    func testMuteDurations() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        // 2026-10-01 23:30 BST.
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 23, minute: 30)))
        XCTAssertEqual(NotifyMuteDuration.oneHour.end(from: now, calendar: calendar), now.addingTimeInterval(3600))
        XCTAssertEqual(NotifyMuteDuration.eightHours.end(from: now, calendar: calendar), now.addingTimeInterval(8 * 3600))
        XCTAssertEqual(NotifyMuteDuration.untilTomorrowMorning.end(from: now, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 8)))
        // Just after midnight "tomorrow" is still the next calendar day.
        let early = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 0, minute: 30)))
        XCTAssertEqual(NotifyMuteDuration.untilTomorrowMorning.end(from: early, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 8)))
    }
}
