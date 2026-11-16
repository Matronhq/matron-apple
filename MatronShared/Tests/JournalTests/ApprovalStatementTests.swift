import CryptoKit
import XCTest
@testable import MatronJournal

/// The shared approval-key test vectors (the journal's
/// `test/fixtures/approval-vectors.json`): a throwaway key, never used for
/// anything real, and one signed statement of each kind. The app's
/// canonical JSON must reproduce each statement byte for byte from its
/// fields, and each signature must verify over those bytes.
enum ApprovalVectors {
    static let publicKey = "BEtG2OrWBwGGAoxj_bPoQTlcPt-07vs-LmTP3jaUp63BWZyHhi-WwLTuYUIlSD2ccjvmOlgAvhP3rQRZxRMFfGo"
    static let keyID = "7734f909e9f544078132cf4d9007db7ffc0b4a36a266f3e0488477995ee3552f"
    static let privateKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgqaOEaPyrULWgGII2
    I8K1o9uZmk/sYey5bvnLPX8BUNihRANCAARLRtjq1gcBhgKMY/2z6EE5XD7ftO77
    Pi5kz942lKetwVmch4YvlsC07mFCJUg9nHI75jpYAL4T960EWcUTBXxq
    -----END PRIVATE KEY-----
    """
    static let journal = "journal.example"
    static let user = "alice"
    static let nonce = "q83vEjRWeJq83vEjRWeJq83vEjRWeJq83vEjRWeJq8k"
    static let signedAt: Int64 = 1_790_000_000_000

    static let itemDigest = "ed21b0d465a1c26c16a5800898c5e792473adf2eb04fd99cdbe015cd80200702"
    static let replyDigest = "3b4138bc5f9e4d49f9eb9ca5640a6dd12589651e605f13d7086e42a8509819ef"

    static let itemTap = (
        statement: #"{"action":"Approve","item":{"id":"it_abc123","num":7,"reply_to":null},"journal":"journal.example","key_id":"7734f909e9f544078132cf4d9007db7ffc0b4a36a266f3e0488477995ee3552f","nonce":"q83vEjRWeJq83vEjRWeJq83vEjRWeJq83vEjRWeJq8k","prompt_digest":"ed21b0d465a1c26c16a5800898c5e792473adf2eb04fd99cdbe015cd80200702","signed_at":1790000000000,"subject":{"box":"box-a"},"type":"item_tap","user":"alice","v":1}"#,
        signature: "MEQCIFaRPTnhu8ClJxt8R8usnO-gMazAXPMSi8pFMtB8ZMyJAiAQzhUFk2wAweZI6owHu6evq2YY29kgFOrc_olu0Wsguw")
    static let itemTapReply = (
        statement: #"{"action":"Yes","item":{"id":"it_abc123","num":7,"reply_to":"cm_def456"},"journal":"journal.example","key_id":"7734f909e9f544078132cf4d9007db7ffc0b4a36a266f3e0488477995ee3552f","nonce":"q83vEjRWeJq83vEjRWeJq83vEjRWeJq83vEjRWeJq8k","prompt_digest":"3b4138bc5f9e4d49f9eb9ca5640a6dd12589651e605f13d7086e42a8509819ef","signed_at":1790000000000,"subject":{"box":"box-a"},"type":"item_tap","user":"alice","v":1}"#,
        signature: "MEQCIAiFHcJs1S421FyNmvDtsx-tjzSK1RisbbceXCbB5TYQAiAXdlnRbZHP01c58ncmRomnsA37rIQ_eZNjPBGxXGKLdA")
    static let consent = (
        statement: #"{"journal":"journal.example","key_id":"7734f909e9f544078132cf4d9007db7ffc0b4a36a266f3e0488477995ee3552f","nonce":"q83vEjRWeJq83vEjRWeJq83vEjRWeJq83vEjRWeJq8k","signed_at":1790000000000,"subject":{"ask":"sp_1","box":"box-a","decision":"approve","op":"spawn","task_sha256":"98fa3fff3b511b6deb8e13945bc02a59b1833ea712caf83df7e4ec77d94965e1","workdir":"/home/alice/project"},"type":"consent","user":"alice","v":1}"#,
        signature: "MEQCIGxQdXg-4gvweYtEO6KY1IrMZJmU5gTOrptlMX8phyaDAiB4EYolOyoivjuQvUSm5jQK7pIiYVvx2OTj8AlVlx3FyQ")
    static let account = (
        statement: #"{"journal":"journal.example","key_id":"7734f909e9f544078132cf4d9007db7ffc0b4a36a266f3e0488477995ee3552f","nonce":"q83vEjRWeJq83vEjRWeJq83vEjRWeJq83vEjRWeJq8k","signed_at":1790000000000,"subject":{"code":"BCDF2345","op":"link_device"},"type":"account","user":"alice","v":1}"#,
        signature: "MEYCIQDhAtCTsJVTQJXH7obpPhUsOTtrtk27qmbHBf201qauXwIhAJLDEisyEWP9kSx5pKJxxqfageDnyOEWx30LJAsOeQwn")

    static func statement(_ kind: ApprovalStatement.Kind, subject: ApprovalSubject) -> ApprovalStatement {
        ApprovalStatement(kind: kind, journal: journal, user: user, keyID: keyID, nonce: nonce,
                          signedAt: signedAt, subject: subject)
    }
}

final class ApprovalStatementTests: XCTestCase {
    // MARK: The four vectors

    func test_itemTapVector_isRebuiltByteForByte() throws {
        let statement = ApprovalVectors.statement(
            .itemTap(itemID: "it_abc123", num: 7, replyTo: nil, action: "Approve",
                     promptDigest: PromptDigest.item(title: "Deploy box-a", body: "Roll out the new build?")),
            subject: ["box": "box-a"])
        XCTAssertEqual(try statement.canonicalString(), ApprovalVectors.itemTap.statement)
    }

    func test_itemTapReplyVector_isRebuiltByteForByte() throws {
        let statement = ApprovalVectors.statement(
            .itemTap(itemID: "it_abc123", num: 7, replyTo: "cm_def456", action: "Yes",
                     promptDigest: PromptDigest.comment(body: "Also restart the service?")),
            subject: ["box": "box-a"])
        XCTAssertEqual(try statement.canonicalString(), ApprovalVectors.itemTapReply.statement)
    }

    func test_consentVector_isRebuiltFromTheAsk() throws {
        let subject = ApprovalSubjects.spawn(ask: "sp_1", box: "box-a", workdir: "/home/alice/project",
                                             task: "Run the test suite and report.")
        XCTAssertEqual(try ApprovalVectors.statement(.consent, subject: subject).canonicalString(),
                       ApprovalVectors.consent.statement)
    }

    func test_accountVector_isRebuiltByteForByte() throws {
        let subject = ApprovalSubjects.linkDevice(code: "BCDF2345")
        XCTAssertEqual(try ApprovalVectors.statement(.account, subject: subject).canonicalString(),
                       ApprovalVectors.account.statement)
    }

    func test_vectorSignatures_verifyOverOurBytes() throws {
        let raw = try XCTUnwrap(ApprovalKeyEncoding.data(base64URL: ApprovalVectors.publicKey))
        let key = try P256.Signing.PublicKey(x963Representation: raw)
        for vector in [ApprovalVectors.itemTap, ApprovalVectors.itemTapReply, ApprovalVectors.consent, ApprovalVectors.account] {
            let der = try XCTUnwrap(ApprovalKeyEncoding.data(base64URL: vector.signature))
            let signature = try P256.Signing.ECDSASignature(derRepresentation: der)
            XCTAssertTrue(key.isValidSignature(signature, for: Data(vector.statement.utf8)))
        }
    }

    // MARK: Digests

    func test_promptDigests_matchTheProtocolExamples() {
        XCTAssertEqual(PromptDigest.item(title: "Deploy box-a", body: "Roll out the new build?"), ApprovalVectors.itemDigest)
        XCTAssertEqual(PromptDigest.comment(body: "Also restart the service?"), ApprovalVectors.replyDigest)
        XCTAssertEqual(PromptDigest.comment(body: "Rotate the staging credentials?"),
                       "b433cef943063e09fe67140575a6012897118d3306f202abfd28c800a24b2b37")
    }

    // MARK: Key encodings

    func test_keyID_isTheHashOfTheUncompressedPoint() throws {
        let raw = try XCTUnwrap(ApprovalKeyEncoding.data(base64URL: ApprovalVectors.publicKey))
        XCTAssertEqual(raw.count, 65)
        XCTAssertEqual(ApprovalKeyEncoding.keyID(publicKey: raw), ApprovalVectors.keyID)
        XCTAssertEqual(ApprovalKeyEncoding.base64URL(raw), ApprovalVectors.publicKey)
        XCTAssertEqual(ApprovalKeyEncoding.fingerprint(keyID: ApprovalVectors.keyID), "7734f909")
    }

    func test_softwareKey_signsDERThatVerifies() async throws {
        let key = try SoftwareApprovalKey(pem: ApprovalVectors.privateKeyPEM)
        XCTAssertEqual(key.keyID, ApprovalVectors.keyID)
        let approval = try await ApprovalVectors.statement(.account, subject: ["op": "change_password"])
            .signed(by: key, reason: "test")
        let der = try XCTUnwrap(ApprovalKeyEncoding.data(base64URL: approval.signature))
        XCTAssertEqual(der.first, 0x30, "DER, never the raw 64-byte r‖s")
        let signature = try P256.Signing.ECDSASignature(derRepresentation: der)
        let pub = try P256.Signing.PublicKey(x963Representation: key.publicKey)
        XCTAssertTrue(pub.isValidSignature(signature, for: Data(approval.statement.utf8)))
        XCTAssertFalse(approval.signature.contains("="))
    }

    // MARK: Canonical JSON

    func test_canonicalJSON_sortsKeysByUTF16CodeUnits() throws {
        // U+FF5E sorts before U+1F600 by code point, but after it by
        // UTF-16 code unit (0xD83D < 0xFF5E), which is what RFC 8785 asks.
        let value = CanonicalJSON.Value.object(["\u{FF5E}": .int(1), "😀": .int(2), "a": .int(3), "B": .int(4)])
        XCTAssertEqual(try CanonicalJSON.string(value), #"{"B":4,"a":3,"😀":2,"～":1}"#)
    }

    func test_canonicalJSON_escapesStringsAsJSONStringifyDoes() throws {
        let value = CanonicalJSON.Value.string("a\"b\\c/d\n\t\r\u{08}\u{0C}\u{01}\u{1F}é\u{2028}")
        XCTAssertEqual(try CanonicalJSON.string(value), #""a\"b\\c/d\n\t\r\b\f\u0001\u001fé\#u{2028}""#)
    }

    func test_canonicalJSON_refusesNoncharacters() {
        // Built from their code points: Swift source cannot spell them.
        func text(_ codePoint: UInt32) -> String { "x" + String(Character(Unicode.Scalar(codePoint)!)) }
        XCTAssertThrowsError(try CanonicalJSON.string(.string(text(0xFFFE))))
        XCTAssertThrowsError(try CanonicalJSON.string(.string(text(0xFDD0))))
        XCTAssertThrowsError(try CanonicalJSON.string(.object([text(0x1FFFF): .null])))
    }

    // MARK: Subjects

    func test_subject_longValuesAreHashedUnderNameSha256() {
        let long = String(repeating: "w", count: 300)
        let subject = ApprovalSubjects.spawn(ask: "sp_1", box: "box-a", workdir: long, task: "t")
        XCTAssertNil(subject["workdir"])
        XCTAssertEqual(subject["workdir_sha256"], ApprovalSubjects.sha256(long))
        XCTAssertEqual(subject["task_sha256"], ApprovalSubjects.sha256("t"))
        // 200 exactly is still signed as itself; lengths count UTF-16 units.
        let edge = String(repeating: "😀", count: 100)
        XCTAssertEqual(ApprovalSubjects.spawn(ask: "a", box: "b", workdir: edge, task: "t")["workdir"], edge)
        let over = edge + "x"
        XCTAssertNil(ApprovalSubjects.spawn(ask: "a", box: "b", workdir: over, task: "t")["workdir"])
    }

    func test_subject_protocolExamples() {
        XCTAssertEqual(ApprovalSubjects.spawn(ask: "0d6f2c1e-8a3b-4c5d-9e7f-1a2b3c4d5e6f", box: "box-a", workdir: "~/app",
                                              task: "Run the test suite and report failures"),
                       ["op": "spawn", "ask": "0d6f2c1e-8a3b-4c5d-9e7f-1a2b3c4d5e6f", "box": "box-a", "workdir": "~/app",
                        "decision": "approve",
                        "task_sha256": "a25400641734a8a4ec570337327a4a3f0cd9934ccf2dd04a50addf5c26730fa5"])
        XCTAssertEqual(ApprovalSubjects.start(box: "box-a", workdir: "~/app", prompt: "Check the deploy logs"),
                       ["op": "start", "box": "box-a", "workdir": "~/app",
                        "prompt_sha256": "69ee4ed03967748aac3e91b0bb1e54bdd92b0bd93f52f18584b7f5fe508de0ba"])
        XCTAssertEqual(ApprovalSubjects.unlockBox(box: "box-a", minutes: 30),
                       ["op": "unlock_box", "box": "box-a", "minutes": "30"])
        XCTAssertEqual(ApprovalSubjects.setConsent(which: .transfers, on: false),
                       ["op": "set_consent", "which": "transfers", "on": "false"])
        XCTAssertEqual(ApprovalSubjects.setCoordinator(convoID: nil), ["op": "set_coordinator", "convo": ""])
        XCTAssertEqual(ApprovalSubjects.protectDevice(id: 12, on: true), ["op": "protect_device", "device": "12", "on": "true"])
    }

    func test_subject_validity() {
        XCTAssertTrue(ApprovalSubjects.isValid([:]))
        XCTAssertTrue(ApprovalSubjects.isValid(["a": ""]))
        XCTAssertFalse(ApprovalSubjects.isValid(["a": String(repeating: "x", count: 201)]))
        var many: ApprovalSubject = [:]
        for i in 0..<13 { many["k\(i)"] = "v" }
        XCTAssertFalse(ApprovalSubjects.isValid(many))
    }

    func test_subjectLines_areInSignedOrder() {
        let lines = ApprovalSubjects.lines(["op": "spawn", "box": "box-a", "ask": "sp_1"])
        XCTAssertEqual(lines.map(\.key), ["ask", "box", "op"])
        XCTAssertEqual(lines.map(\.value), ["sp_1", "box-a", "spawn"])
    }
}
