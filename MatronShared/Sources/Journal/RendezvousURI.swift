import Foundation

/// The rendezvous QR payload — the single place the format is known:
/// `matron://rlink?v=2&rid=<26-char rid>&k=<base64url 32-byte key>`. The
/// reverse of `LinkURI`: this QR is SHOWN by a signed-out device and SCANNED
/// by a signed-in phone. It carries the rendezvous id and the single-use
/// offer key — never the poll secret, never a server. The key never reaches
/// the relay; it travels only screen→camera. Android carries an equivalent
/// parser (rendezvous-offer-encryption spec).
public enum RendezvousURI {
    public struct Parsed: Equatable {
        public let rid: String
        public let key: Data
        public init(rid: String, key: Data) { self.rid = rid; self.key = key }
    }

    public enum ParseError: Error, Equatable {
        /// Not ours at all — scanner shows "Not a Matron link code."
        case notALink
        /// Ours, but an unsupported version — scanner shows "update the app".
        case unsupportedVersion
        /// Ours and v=2, but the rid or key doesn't parse.
        case malformed
    }

    private static let prefix = "matron://rlink?"
    private static let ridPattern = "^[0-9BCDFGHJKMNPQRSTVWXYZ]{26}$"
    private static let keyByteCount = 32

    public static func format(rid: String, key: Data) -> String {
        // rid alphabet and base64url both need no percent-encoding.
        "\(prefix)v=2&rid=\(rid)&k=\(Base64URL.encode(key))"
    }

    public static func parse(_ raw: String) throws -> Parsed {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "matron", components.host?.lowercased() == "rlink"
        else { throw ParseError.notALink }
        let value = { (name: String) in components.queryItems?.first(where: { $0.name == name })?.value }
        guard let version = value("v") else { throw ParseError.malformed }
        guard version == "2" else { throw ParseError.unsupportedVersion }
        guard let rid = value("rid"), rid.range(of: ridPattern, options: .regularExpression) != nil else {
            throw ParseError.malformed
        }
        guard let k = value("k"), let key = Base64URL.decode(k), key.count == keyByteCount else {
            throw ParseError.malformed
        }
        return Parsed(rid: rid, key: key)
    }
}
