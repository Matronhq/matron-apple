import XCTest
@testable import MatronModels

final class BotCommandCatalogTests: XCTestCase {
    func test_filter_emptyPrefix_returnsAll() {
        let all = BotCommandCatalog.claudeBridge
        let filtered = BotCommandCatalog.filter(all, byPrefix: "")
        XCTAssertEqual(filtered.count, all.count)
    }

    func test_filter_matchesPrefixCaseInsensitive() {
        let filtered = BotCommandCatalog.filter(BotCommandCatalog.claudeBridge, byPrefix: "/STA")
        XCTAssertTrue(filtered.contains { $0.trigger == "/start" })
        XCTAssertTrue(filtered.contains { $0.trigger == "/status" })
        XCTAssertFalse(filtered.contains { $0.trigger == "/stop" })
    }

    func test_filter_acceptsBangPrefix() {
        let filtered = BotCommandCatalog.filter(BotCommandCatalog.claudeBridge, byPrefix: "!resu")
        XCTAssertTrue(filtered.contains { $0.trigger == "/resume" })
    }

    func test_filter_noMatch_returnsEmpty() {
        let filtered = BotCommandCatalog.filter(BotCommandCatalog.claudeBridge, byPrefix: "/doesnotexist")
        XCTAssertTrue(filtered.isEmpty)
    }

    /// Pins the claude-native passthrough commands the palette must surface
    /// (Dan, 2026-07-15): context/compaction plus account login/logout —
    /// the bridge forwards these into the session rather than intercepting.
    func test_claudeBridge_includesContextAndAccountCommands() {
        let triggers = Set(BotCommandCatalog.claudeBridge.map(\.trigger))
        for expected in ["/context", "/compact", "/login", "/logout"] {
            XCTAssertTrue(triggers.contains(expected), "catalog must include \(expected)")
        }
    }

    /// Pins the 2026-08-05 palette audit against the bridge's command set:
    /// /timer and /switch were missing entirely, and the rescue keystrokes
    /// must be the bang forms — the bridge only intercepts "!esc"/"!enter";
    /// a typed "/esc" passes through into the agent's terminal as junk.
    func test_claudeBridge_includesTimerSwitchAndBangRescues() {
        let triggers = Set(BotCommandCatalog.claudeBridge.map(\.trigger))
        for expected in ["/timer", "/switch", "!esc", "!enter"] {
            XCTAssertTrue(triggers.contains(expected), "catalog must include \(expected)")
        }
        XCTAssertFalse(triggers.contains("/esc"), "slash-form esc is not a bridge command")
    }

    func test_claudeBridge_isNonEmpty_andHasUniqueTriggers() {
        let all = BotCommandCatalog.claudeBridge
        XCTAssertFalse(all.isEmpty)
        XCTAssertEqual(Set(all.map(\.trigger)).count, all.count, "command triggers must be unique")
    }
}
