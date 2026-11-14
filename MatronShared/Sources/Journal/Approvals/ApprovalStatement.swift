import CryptoKit
import Foundation

// Approval keys (step-up): the statement a device signs, and the encodings
// around it. Pure: no keychain, no network, no UI. The journal's protocol
// document ("Approval keys (step-up)") is the contract, and the shared test
// vectors pin every byte of what is built here.

/// RFC 8785 canonical JSON for what a statement can hold: strings,
/// integers, `null` and objects. No whitespace, object keys sorted by
/// UTF-16 code units, strings written as ECMAScript's `JSON.stringify`
/// writes them.
public enum CanonicalJSON {
    public indirect enum Value: Equatable, Sendable {
        case string(String)
        case int(Int64)
        case null
        case object([String: Value])
    }

    public enum Failure: Error, Equatable {
        /// A string or key holds a Unicode noncharacter, which the journal
        /// refuses in a statement.
        case noncharacter
    }

    public static func string(_ value: Value) throws -> String {
        var out = ""
        try write(value, into: &out)
        return out
    }

    private static func write(_ value: Value, into out: inout String) throws {
        switch value {
        case .null: out += "null"
        case .int(let n): out += String(n)
        case .string(let s): try writeString(s, into: &out)
        case .object(let members):
            out += "{"
            var first = true
            for key in sortedKeys(members.keys) {
                if !first { out += "," }
                first = false
                try writeString(key, into: &out)
                out += ":"
                try write(members[key]!, into: &out)
            }
            out += "}"
        }
    }

    /// Keys in the order they are signed: by UTF-16 code units, which is
    /// not Swift's own string order.
    static func sortedKeys<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }

    private static func writeString(_ s: String, into out: inout String) throws {
        out += "\""
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0xFDD0...0xFDEF).contains(v) || (v & 0xFFFE) == 0xFFFE { throw Failure.noncharacter }
            switch v {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0..<0x20: out += String(format: "\\u%04x", v)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

/// What an action is about: a flat object of strings, shown to the user
/// line by line and signed exactly as shown.
public typealias ApprovalSubject = [String: String]

/// One statement, before it is serialised and signed.
public struct ApprovalStatement: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A button on an item (`replyTo` nil) or on a follow-up question
        /// (`replyTo` the asking comment's id).
        case itemTap(itemID: String, num: Int, replyTo: String?, action: String, promptDigest: String)
        /// An ask aimed at a protected box: spawn, chat invite, transfer.
        case consent
        /// An account action, or a request to a box (unlock, clear lockdown).
        case account

        public var wireType: String {
            switch self {
            case .itemTap: return "item_tap"
            case .consent: return "consent"
            case .account: return "account"
            }
        }
    }

    public var kind: Kind
    /// The journal's host, as `GET /approval-keys` gives it.
    public var journal: String
    /// The account's name, as signed in with.
    public var user: String
    public var keyID: String
    public var nonce: String
    /// When the device signed, in ms, by its own clock.
    public var signedAt: Int64
    public var subject: ApprovalSubject

    public init(kind: Kind, journal: String, user: String, keyID: String, nonce: String, signedAt: Int64,
                subject: ApprovalSubject) {
        self.kind = kind; self.journal = journal; self.user = user; self.keyID = keyID
        self.nonce = nonce; self.signedAt = signedAt; self.subject = subject
    }

    /// The string that is signed, sent, stored and forwarded, byte for byte.
    public func canonicalString() throws -> String {
        var members: [String: CanonicalJSON.Value] = [
            "v": .int(1),
            "type": .string(kind.wireType),
            "journal": .string(journal),
            "user": .string(user),
            "key_id": .string(keyID),
            "nonce": .string(nonce),
            "signed_at": .int(signedAt),
            "subject": .object(subject.mapValues { .string($0) }),
        ]
        if case let .itemTap(itemID, num, replyTo, action, promptDigest) = kind {
            members["item"] = .object([
                "id": .string(itemID), "num": .int(Int64(num)),
                "reply_to": replyTo.map { .string($0) } ?? .null,
            ])
            members["action"] = .string(action)
            members["prompt_digest"] = .string(promptDigest)
        }
        return try CanonicalJSON.string(.object(members))
    }

    /// Signs the canonical string. `reason` is what the system's Face ID or
    /// Touch ID prompt says.
    public func signed(by key: any ApprovalSigningKey, reason: String) async throws -> SignedApproval {
        let statement = try canonicalString()
        let der = try await key.signature(for: Data(statement.utf8), reason: reason)
        return SignedApproval(statement: statement, signature: ApprovalKeyEncoding.base64URL(der))
    }
}

/// `approval` as every guarded route takes it: exactly these two strings.
public struct SignedApproval: Equatable, Sendable {
    public let statement: String
    public let signature: String

    public init(statement: String, signature: String) {
        self.statement = statement; self.signature = signature
    }

    public var json: [String: Any] { ["statement": statement, "signature": signature] }
}

/// The hash of the words the user was shown, so the question cannot be
/// swapped after the signature. Over the stored text, exactly as the
/// journal returns it to a client that draws inline attachments.
public enum PromptDigest {
    /// A tap on the item's own buttons.
    public static func item(title: String, body: String) -> String {
        digest(["body": .string(body), "title": .string(title)])
    }

    /// A tap on a follow-up question's buttons.
    public static func comment(body: String) -> String {
        digest(["body": .string(body)])
    }

    private static func digest(_ members: [String: CanonicalJSON.Value]) -> String {
        // A body the journal stored can hold a noncharacter; the statement
        // cannot be signed then, and an empty digest never matches.
        guard let text = try? CanonicalJSON.string(.object(members)) else { return "" }
        return ApprovalSubjects.sha256(text)
    }
}

/// Encodings of keys and signatures on the wire.
public enum ApprovalKeyEncoding {
    /// Base64url without padding.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64URL text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    /// Lowercase hex SHA-256 of the 65-byte uncompressed point.
    public static func keyID(publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }

    /// The short form shown on both devices and in the journal's notices:
    /// the first 8 characters of the key id.
    public static func fingerprint(keyID: String) -> String { String(keyID.prefix(8)) }
}

/// The subjects the protocol defines. A subject the journal publishes (on
/// a step-up item, comment or consent item) is signed as published and
/// never rebuilt here; these are for account actions, for requests to a
/// box, and for a consent ask with no item to read the subject from.
public enum ApprovalSubjects {
    public static let maxKeys = 12
    public static let maxLength = 200

    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func isValid(_ subject: ApprovalSubject) -> Bool {
        subject.count <= maxKeys
            && subject.allSatisfy { $0.key.utf16.count <= maxLength && $0.value.utf16.count <= maxLength }
    }

    /// The subject's lines in the order they are signed.
    public static func lines(_ subject: ApprovalSubject) -> [(key: String, value: String)] {
        CanonicalJSON.sortedKeys(subject.keys).map { ($0, subject[$0]!) }
    }

    /// A value that can be long: over 200 UTF-16 units it is signed as its
    /// hash under `<name>_sha256`, never shortened.
    private static func put(_ name: String, _ value: String, into subject: inout ApprovalSubject) {
        if value.utf16.count > maxLength {
            subject[name + "_sha256"] = sha256(value)
        } else {
            subject[name] = value
        }
    }

    private static func build(_ op: String, _ fields: [(String, String)], fixed: ApprovalSubject = [:]) -> ApprovalSubject {
        var subject = fixed
        subject["op"] = op
        for (name, value) in fields { put(name, value, into: &subject) }
        return subject
    }

    private static func flag(_ on: Bool) -> String { on ? "true" : "false" }

    // MARK: Consent (aimed at a protected box)

    public static func spawn(ask: String, box: String, workdir: String, task: String) -> ApprovalSubject {
        build("spawn", [("ask", ask), ("box", box), ("workdir", workdir)],
              fixed: ["task_sha256": sha256(task), "decision": "approve"])
    }

    public static func chat(roomID: String, targetDeviceID: Int64, box: String, justification: String) -> ApprovalSubject {
        build("chat", [("ask", "\(roomID)/\(targetDeviceID)"), ("box", box)],
              fixed: ["message_sha256": sha256(justification), "decision": "approve"])
    }

    public static func transfer(id: String, box: String, fileSHA256: String, size: Int64) -> ApprovalSubject {
        build("transfer", [("ask", id), ("box", box), ("file_sha256", fileSHA256)],
              fixed: ["size": String(size), "decision": "approve"])
    }

    // MARK: Account actions

    public static func changePassword() -> ApprovalSubject { ["op": "change_password"] }

    public static func pairBridge(code: String, name: String) -> ApprovalSubject {
        build("pair_bridge", [("code", code), ("name", name)])
    }

    public static func linkDevice(code: String) -> ApprovalSubject { build("link_device", [("code", code)]) }

    public static func setCoordinator(convoID: String?) -> ApprovalSubject {
        build("set_coordinator", [("convo", convoID ?? "")])
    }

    public enum ConsentSwitch: String, Sendable { case spawns, transfers }

    public static func setConsent(which: ConsentSwitch, on: Bool) -> ApprovalSubject {
        ["op": "set_consent", "which": which.rawValue, "on": flag(on)]
    }

    public enum TwoFactorAction: String, Sendable {
        case setup, enable, disable
        case recoveryCodes = "recovery_codes"
    }

    public static func twoFactor(_ action: TwoFactorAction) -> ApprovalSubject {
        ["op": "two_factor", "action": action.rawValue]
    }

    public static func protectDevice(id: Int64, on: Bool) -> ApprovalSubject {
        ["op": "protect_device", "device": String(id), "on": flag(on)]
    }

    public static func revokeDevice(id: Int64) -> ApprovalSubject { ["op": "revoke_device", "device": String(id)] }

    public static func itemStepUpOff(itemID: String) -> ApprovalSubject {
        build("item_step_up", [("item", itemID)], fixed: ["on": "false"])
    }

    /// A client's own `start` on a protected box. An absent workdir is
    /// `""` and an absent prompt hashes as `""`.
    public static func start(box: String, workdir: String?, prompt: String?) -> ApprovalSubject {
        build("start", [("box", box), ("workdir", workdir ?? "")], fixed: ["prompt_sha256": sha256(prompt ?? "")])
    }

    // MARK: Keys

    public static func enrolKey(keyID: String) -> ApprovalSubject { ["op": "enrol_key", "key_id": keyID] }
    public static func revokeKey(keyID: String) -> ApprovalSubject { ["op": "revoke_key", "key_id": keyID] }
    public static func attachKey(keyID: String) -> ApprovalSubject { ["op": "attach_key", "key_id": keyID] }

    // MARK: Requests to a box (checked by the box, not the journal)

    public static func unlockBox(box: String, minutes: Int) -> ApprovalSubject {
        build("unlock_box", [("box", box)], fixed: ["minutes": String(minutes)])
    }

    public static func clearLockdown(box: String) -> ApprovalSubject { build("clear_lockdown", [("box", box)]) }
}
