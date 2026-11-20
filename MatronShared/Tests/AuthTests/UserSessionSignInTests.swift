import XCTest
import MatronModels

final class UserSessionSignInTests: XCTestCase {
    private func session(user: String = "alice", device: String = "23", host: String = "https://chat.example.com",
                         token: String = "t") -> UserSession {
        UserSession(userID: user, deviceID: device, homeserverURL: URL(string: host)!, accessToken: token)
    }

    func test_sameDevice_isSameSignIn_evenWithANewToken() {
        // An account unlock gives the same device a new token.
        XCTAssertTrue(session(token: "old").isSameSignIn(as: session(token: "new")))
    }

    func test_newDevice_forTheSameUser_isAnotherSignIn() {
        // Signed out, then linked again by QR: same user, new device id.
        XCTAssertFalse(session(device: "23").isSameSignIn(as: session(device: "26")))
    }

    func test_sameUserAndDevice_onAnotherJournal_isAnotherSignIn() {
        XCTAssertFalse(session(host: "https://a.example.com").isSameSignIn(as: session(host: "https://b.example.com")))
    }

    func test_storeFileName_isPerSignIn() {
        XCTAssertEqual(session(device: "26").journalStoreFileName, "alice.d26.sqlite")
        XCTAssertNotEqual(session(device: "26").journalStoreFileName, session(device: "27").journalStoreFileName)
        XCTAssertEqual(session().legacyJournalStoreFileName, "alice.sqlite")
    }

    func test_storeFileName_dropsPathCharactersFromTheDeviceID() {
        XCTAssertEqual(session(device: "../x/1").journalStoreFileName, "alice.dx1.sqlite")
    }
}
