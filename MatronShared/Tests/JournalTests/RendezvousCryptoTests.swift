import XCTest
@testable import MatronJournal

final class RendezvousCryptoTests: XCTestCase {
    // The cross-language interop vector — the SAME literals are asserted in
    // the Android suite so a Swift-sealed box opens under Kotlin and vice
    // versa. AES-256-GCM, framing nonce(12)‖ciphertext‖tag(16), base64url.
    private let vectorKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    private let vectorBox = "oKGio6SlpqeoqaqrnToPSDe9Z81AX6W7cw6wrUqDdnP61jZC-XZH6w_HEC-xGSrdgwAwUjv5JvIrSLDNcjZwf1rpOAMFFZLM4JJwtKZY9E-Fmmfg"
    private let vectorPlaintext = #"{"server":"https://chat.example.com","code":"2345-6789"}"#

    func test_base64URL_roundTrips_andStripsPadding() {
        let raw = Data([0x00, 0x01, 0x02, 0x03, 0xff, 0xfe])
        let encoded = Base64URL.encode(raw)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertEqual(Base64URL.decode(encoded), raw)
    }

    func test_generateKey_is32RandomBytes() {
        let a = RendezvousCrypto.generateKey()
        let b = RendezvousCrypto.generateKey()
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(b.count, 32)
        XCTAssertNotEqual(a, b)
    }

    func test_seal_then_open_roundTrips() throws {
        let key = RendezvousCrypto.generateKey()
        let plaintext = Data(vectorPlaintext.utf8)
        let box = try RendezvousCrypto.seal(plaintext, key: key)
        // framing: 12-byte nonce + ciphertext + 16-byte tag
        XCTAssertEqual(box.count, 12 + plaintext.count + 16)
        XCTAssertEqual(try RendezvousCrypto.open(box, key: key), plaintext)
    }

    func test_open_theSharedInteropVector() throws {
        let key = try XCTUnwrap(Base64URL.decode(vectorKey))
        let box = try XCTUnwrap(Base64URL.decode(vectorBox))
        let plaintext = try RendezvousCrypto.open(box, key: key)
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), vectorPlaintext)
    }

    func test_open_tamperedBox_throws() throws {
        let key = RendezvousCrypto.generateKey()
        var box = try RendezvousCrypto.seal(Data(vectorPlaintext.utf8), key: key)
        box[box.count - 1] ^= 0x01 // flip a tag bit
        XCTAssertThrowsError(try RendezvousCrypto.open(box, key: key))
    }

    func test_open_wrongKey_throws() throws {
        let box = try RendezvousCrypto.seal(Data(vectorPlaintext.utf8), key: RendezvousCrypto.generateKey())
        XCTAssertThrowsError(try RendezvousCrypto.open(box, key: RendezvousCrypto.generateKey()))
    }

    func test_open_truncatedInput_throwsCleanly() {
        let key = RendezvousCrypto.generateKey()
        XCTAssertThrowsError(try RendezvousCrypto.open(Data([0x00, 0x01, 0x02]), key: key))
    }
}
