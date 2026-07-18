import Foundation

/// The rendezvous QR payload — the single place the format is known:
/// `matron://rlink?v=1&rid=<26-char rid>`. The reverse of `LinkURI`: this QR
/// is SHOWN by a signed-out device and SCANNED by a signed-in phone. It
/// carries only the rendezvous id — never the poll secret, never a server.
/// Android carries an equivalent parser; the relay never sees the URI.
public enum RendezvousURI {
    public enum ParseError: Error, Equatable {
        /// Not ours at all — scanner shows "Not a Matron link code."
        case notALink
        /// Ours, but a future version — scanner shows "update the app".
        case unsupportedVersion
        /// Ours and v=1, but the rid doesn't parse.
        case malformed
    }

    private static let prefix = "matron://rlink?"
    // Same alphabet as PairingCode / link codes; 26 chars ≈ 128 bits.
    private static let ridPattern = "^[0-9BCDFGHJKMNPQRSTVWXYZ]{26}$"

    public static func format(rid: String) -> String {
        "\(prefix)v=1&rid=\(rid)" // rid alphabet needs no percent-encoding
    }

    public static func parse(_ raw: String) throws -> String {
        guard raw.hasPrefix(prefix) else { throw ParseError.notALink }
        var params: [String: String] = [:]
        for pair in raw.dropFirst(prefix.count).split(separator: "&") {
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
            params[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
                .removingPercentEncoding ?? ""
        }
        guard let version = params["v"] else { throw ParseError.malformed }
        guard version == "1" else { throw ParseError.unsupportedVersion }
        guard let rid = params["rid"], rid.range(of: ridPattern, options: .regularExpression) != nil else {
            throw ParseError.malformed
        }
        return rid
    }
}
