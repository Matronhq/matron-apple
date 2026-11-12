import CryptoKit
import MatronStorage
import UserNotifications
import XCTest
@testable import MatronPushContent

/// The box below was sealed by the journal's own implementation (HPKE
/// written over node's crypto) with a fixed ephemeral key, and is pinned in
/// its tests too. Opening it here with CryptoKit's HPKE shows the two agree.
final class PushBoxTests: XCTestCase {
    /// A fixture key, derived from a public string. It guards nothing.
    static let recipient = try! Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: Data(SHA256.hash(data: Data("fixture recipient".utf8))))
    static let vector = "pSB6orUR--of_qx2eAlOOaZ21Ut5_WVkw9NJ3JPhGE2q0JsD_VvSzNA6StCz9rGrWiKgFQF6uyobsVS05yZ6fYhuxU9XxTlI-PJHA6_XgxRA73hDFGeTlN-WqmuK43qJY9VfUyyoxcvJ_S7RfIJCgceCpmIO8xnQm6Apt1RuYKCcJ6vw2wWsW0dnXV2HKDHDaHZ7IJR1EzzhGaQcXftdYY1C45aLoh3_6ZVCGDz_zbXiKy96b10UIsTZcpqMBw5Ap_eBZuf2GZCaBUlDxxeJf1EI3Z17WXX8jUzMQznoVy2Etxh8oobnhG7D61pEqmStSIbp3AJJk6hvmOi2JViIWhWg59oIgWpDEisthHRrZk1XZfR14wD7EDRL2roWOHpN5Aiz0BPT91zJyX7NzyKFLA"

    func test_fixtureKey_matchesTheJournalsPublicKey() {
        XCTAssertEqual(Self.recipient.publicKey.rawRepresentation.base64URLEncodedString(),
                       "uLHqgzncBWWOwTpUixAlfi0qAZ_p0tSU6vRJv7LCvi4")
    }

    func test_opensTheJournalsVector() {
        let content = PushBox.content(of: Self.vector, with: Self.recipient)
        XCTAssertEqual(content, PushContent(
            title: "Ship the release notes?", subtitle: "Docs",
            body: "Two options: ship now, or wait for the screenshots.",
            convoID: "c-1", seq: 42, kind: "attention",
            item: .init(id: "it_1", number: 12, kind: "question", actions: ["Ship", "Wait"], replyTo: nil)))
    }

    func test_plaintextIsPaddedWithSpaces_toAMultipleOf256() throws {
        let plain = try XCTUnwrap(PushBox.open(Self.vector, with: Self.recipient))
        XCTAssertEqual(plain.count, 256)
        XCTAssertEqual(plain.last, 0x20)
    }

    func test_anotherKey_doesNotOpenIt() {
        XCTAssertNil(PushBox.open(Self.vector, with: Curve25519.KeyAgreement.PrivateKey()))
    }

    func test_anAlteredBox_doesNotOpen() throws {
        var raw = try XCTUnwrap(Data(base64URLEncoded: Self.vector))
        raw[40] ^= 1
        XCTAssertNil(PushBox.open(raw.base64URLEncodedString(), with: Self.recipient))
    }

    func test_malformedBoxes_doNotOpen() {
        for bad in ["", "abc", "not base64 !!", String(repeating: "A", count: 40),
                    String(repeating: "A", count: 4000), Self.vector + "="] {
            XCTAssertNil(PushBox.open(bad, with: Self.recipient), bad.prefix(20).description)
        }
    }

    func test_roundTrip_withCryptoKitsOwnSender() throws {
        let json = Data(#"{"v":1,"title":"T","body":"B","convo_id":"c"}"#.utf8)
        var sender = try HPKE.Sender(recipientKey: Self.recipient.publicKey,
                                     ciphersuite: .Curve25519_SHA256_ChachaPoly, info: PushBox.info)
        let sealed = try sender.seal(json)
        let box = (sender.encapsulatedKey + sealed).base64URLEncodedString()
        XCTAssertEqual(PushBox.content(of: box, with: Self.recipient)?.title, "T")
    }
}

final class PushContentTests: XCTestCase {
    private func content(_ json: String) -> PushContent? { PushContent(plaintext: Data(json.utf8)) }

    func test_minimalContent_decodes_andOptionalPartsAreNil() {
        let c = content(#"{"v":1,"title":"Docs","body":"hello","convo_id":"c-1","seq":7,"kind":"activity"}   "#)
        XCTAssertEqual(c, PushContent(title: "Docs", subtitle: nil, body: "hello", convoID: "c-1", seq: 7,
                                      kind: "activity", item: nil))
    }

    func test_unknownVersion_orMissingParts_doNotDecode() {
        XCTAssertNil(content(#"{"v":2,"title":"T","body":"B","convo_id":"c"}"#))
        XCTAssertNil(content(#"{"title":"T","body":"B","convo_id":"c"}"#))
        XCTAssertNil(content(#"{"v":1,"body":"B","convo_id":"c"}"#))
        XCTAssertNil(content(#"{"v":1,"title":"T","body":"B"}"#))
        XCTAssertNil(content(#"{"v":1,"title":"T","body":"B","convo_id":""}"#))
        XCTAssertNil(content("not json"))
        XCTAssertNil(content("[1]"))
    }

    func test_unknownKeysAreIgnored_andActionsAreCappedAndCleaned() {
        let c = content(#"{"v":1,"title":"T","body":"B","convo_id":"c","later":true,"item":{"id":"it_1","num":3,"kind":"question","actions":["A","",2,"B","C","D","E"],"reply_to":"ic_9","more":1}}"#)
        XCTAssertEqual(c?.item, .init(id: "it_1", number: 3, kind: "question", actions: ["A", "B", "C", "D"], replyTo: "ic_9"))
    }

    func test_apply_writesTextThreadAndTapTargets_andDropsTheBox() throws {
        let c = try XCTUnwrap(content(#"{"v":1,"title":"Ship?","subtitle":"Question · Docs","body":"Two options","convo_id":"c-1","seq":42,"kind":"attention","item":{"id":"it_1","num":12,"kind":"question","actions":["Ship","Wait"],"reply_to":"ic_2"}}"#))
        let n = UNMutableNotificationContent()
        n.title = "Matron"
        n.body = "Your agent needs you"
        n.userInfo = ["box": "sealed", "aps": ["thread-id": "c-1"]]
        c.apply(to: n)
        XCTAssertEqual(n.title, "Ship?")
        XCTAssertEqual(n.subtitle, "Question · Docs")
        XCTAssertEqual(n.body, "Two options")
        XCTAssertEqual(n.threadIdentifier, "c-1")
        XCTAssertEqual(n.categoryIdentifier, PushNotificationActions.categoryIdentifier(for: ["Ship", "Wait"]))
        XCTAssertNil(n.userInfo["box"])
        XCTAssertEqual(n.userInfo["room_id"] as? String, "c-1")
        XCTAssertEqual((n.userInfo["seq"] as? NSNumber)?.int64Value, 42)
        XCTAssertEqual(PushNotificationActions.answer(actionIdentifier: PushNotificationActions.actionIdentifier(1), userInfo: n.userInfo),
                       .init(itemID: "it_1", label: "Wait", replyTo: "ic_2"))
    }

    func test_apply_withoutButtons_setsNoCategory() throws {
        let c = try XCTUnwrap(content(#"{"v":1,"title":"T","body":"B","convo_id":"c","item":{"id":"it_1","num":1,"kind":"question","actions":[]}}"#))
        let n = UNMutableNotificationContent()
        c.apply(to: n)
        XCTAssertEqual(n.categoryIdentifier, "")
        XCTAssertEqual(n.userInfo[PushNotificationActions.Key.itemID] as? String, "it_1")
        XCTAssertNil(n.userInfo[PushNotificationActions.Key.itemActions])
    }
}

final class PushNotificationActionsTests: XCTestCase {
    func test_categoryIdentifier_dependsOnLabelsAndTheirOrder() {
        let a = PushNotificationActions.categoryIdentifier(for: ["Ship", "Wait"])
        XCTAssertEqual(a, PushNotificationActions.categoryIdentifier(for: ["Ship", "Wait"]))
        XCTAssertNotEqual(a, PushNotificationActions.categoryIdentifier(for: ["Wait", "Ship"]))
        XCTAssertNotEqual(a, PushNotificationActions.categoryIdentifier(for: ["ShipWait"]))
        XCTAssertTrue(a.hasPrefix("matron.item."))
    }

    func test_category_hasOneButtonPerLabel_eachNeedingUnlock_noneOpeningTheApp() {
        let category = PushNotificationActions.category(for: ["Approve", "Decline"])
        XCTAssertEqual(category.actions.map(\.title), ["Approve", "Decline"])
        XCTAssertEqual(category.actions.map(\.identifier), ["matron.item.action.0", "matron.item.action.1"])
        for action in category.actions {
            XCTAssertTrue(action.options.contains(.authenticationRequired))
            XCTAssertFalse(action.options.contains(.foreground))
        }
    }

    func test_answer_onlyForAButtonThatIsThere() {
        let info: [AnyHashable: Any] = ["item_id": "it_1", "item_actions": ["Ship", "Wait"]]
        XCTAssertEqual(PushNotificationActions.answer(actionIdentifier: "matron.item.action.0", userInfo: info),
                       .init(itemID: "it_1", label: "Ship", replyTo: nil))
        XCTAssertNil(PushNotificationActions.answer(actionIdentifier: "matron.item.action.2", userInfo: info))
        XCTAssertNil(PushNotificationActions.answer(actionIdentifier: "matron.item.action.-1", userInfo: info))
        XCTAssertNil(PushNotificationActions.answer(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: info))
        XCTAssertNil(PushNotificationActions.answer(actionIdentifier: "matron.item.action.0", userInfo: ["item_actions": ["Ship"]]))
    }

    func test_adding_keepsOtherCategories_skipsWhatIsThere_andDropsTheOldestPastTheCap() throws {
        let foreign = UNNotificationCategory(identifier: "something.else", actions: [], intentIdentifiers: [], options: [])
        var categories: Set<UNNotificationCategory> = [foreign]
        var order: [String] = []
        for index in 0..<PushNotificationActions.maxDynamicCategories {
            let next = try XCTUnwrap(PushNotificationActions.adding(labels: ["L\(index)"], to: categories, order: order))
            (categories, order) = (next.categories, next.order)
        }
        XCTAssertNil(PushNotificationActions.adding(labels: ["L3"], to: categories, order: order))
        let next = try XCTUnwrap(PushNotificationActions.adding(labels: ["New"], to: categories, order: order))
        let ids = Set(next.categories.map(\.identifier))
        XCTAssertEqual(ids.count, PushNotificationActions.maxDynamicCategories + 1)
        XCTAssertTrue(ids.contains("something.else"))
        XCTAssertTrue(ids.contains(PushNotificationActions.categoryIdentifier(for: ["New"])))
        XCTAssertFalse(ids.contains(PushNotificationActions.categoryIdentifier(for: ["L0"])))
        XCTAssertTrue(ids.contains(PushNotificationActions.categoryIdentifier(for: ["L1"])))
    }
}

final class PushKeyStoreTests: XCTestCase {
    private final class MemoryStore: SessionStore, @unchecked Sendable {
        var values: [String: String] = [:]
        var failWrites = false
        func set(_ value: String, forKey key: String) throws {
            if failWrites { throw KeychainError.unhandled(-34018) }
            values[key] = value
        }
        func get(key: String) throws -> String? { values[key] }
        func delete(key: String) throws { values[key] = nil }
    }

    func test_makesAKeyOnce_andKeepsRegisteringTheSameOne() throws {
        let store = PushKeyStore(store: MemoryStore())
        XCTAssertNil(store.privateKey())
        let first = try XCTUnwrap(store.publicKeyForRegistration())
        XCTAssertEqual(first.count, 43)
        XCTAssertEqual(store.publicKeyForRegistration(), first)
        XCTAssertEqual(store.privateKey()?.publicKey.rawRepresentation.base64URLEncodedString(), first)
    }

    func test_delete_meansTheNextRegistrationHasANewKey() throws {
        let store = PushKeyStore(store: MemoryStore())
        let first = try XCTUnwrap(store.publicKeyForRegistration())
        store.delete()
        XCTAssertNil(store.privateKey())
        XCTAssertNotEqual(store.publicKeyForRegistration(), first)
    }

    func test_aStoreThatCannotHoldTheKey_registersWithoutOne() {
        let memory = MemoryStore()
        memory.failWrites = true
        XCTAssertNil(PushKeyStore(store: memory).publicKeyForRegistration())
    }
}
