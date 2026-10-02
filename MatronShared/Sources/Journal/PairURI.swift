import Foundation

/// The agent-pairing QR payload a bridge shows next to its pair code:
/// `matron://pair?v=1&server=<URL-encoded base server URL>&code=XXXX-XXXX`.
/// Sibling of `LinkURI` (sign-in) — deliberately a separate parser, so a
/// pairing QR can never be mistaken for a sign-in one or vice versa.
public enum PairURI {
    public enum ParseError: Error, Equatable {
        /// Not a pairing QR at all.
        case notAPairURI
        /// A pairing QR from a future format version — "update the app".
        case unsupportedVersion
        /// A v=1 pairing QR whose parts don't parse.
        case malformed
    }

    public static func format(server: URL, code: String) -> String {
        var components = URLComponents()
        components.scheme = "matron"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "server", value: server.absoluteString),
            URLQueryItem(name: "code", value: code),
        ]
        return components.url!.absoluteString
    }

    /// Whether `raw` claims to be a pairing QR (scheme `matron`, host
    /// `pair`, case-insensitive), valid or not — lets a code field tell a
    /// pasted URI from a typed code, and other scanners name the QR.
    public static func isPairURI(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return components.scheme?.lowercased() == "matron" && components.host?.lowercased() == "pair"
    }

    /// Returns the server and the code in display form (`XXXX-XXXX`).
    /// Surrounding whitespace is ignored (a pasted URI often carries a
    /// trailing newline).
    public static func parse(_ raw: String) throws -> (server: URL, code: String) {
        guard isPairURI(raw),
              let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw ParseError.notAPairURI }
        let value = { (name: String) in components.queryItems?.first(where: { $0.name == name })?.value }
        guard let version = value("v") else { throw ParseError.malformed }
        guard version == "1" else { throw ParseError.unsupportedVersion }
        guard let serverRaw = value("server"), let server = URL(string: serverRaw),
              server.host?.isEmpty == false,
              LinkURI.isAllowedServerScheme(server),
              let codeRaw = value("code")
        else { throw ParseError.malformed }
        let code = PairingCode.normalize(codeRaw)
        guard code.count == PairingCode.length, code.allSatisfy(PairingCode.alphabet.contains)
        else { throw ParseError.malformed }
        return (server, PairingCode.display(code))
    }

    /// Whether two server URLs share an origin: scheme and host compared
    /// case-insensitively, port with the scheme's default filled in. Path
    /// is ignored — a trailing slash or base path must not refuse a QR from
    /// the account's own server.
    public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        origin(of: lhs) == origin(of: rhs)
    }

    /// `host` or `host:port` (port only when explicit), for messages that
    /// name a server — two dev servers on one host differ only by port.
    public static func displayHost(_ url: URL) -> String {
        let host = url.host ?? url.absoluteString
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }

    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int?
    }

    private static func origin(of url: URL) -> Origin {
        let scheme = url.scheme?.lowercased() ?? ""
        let defaultPort: Int? = switch scheme {
        case "https": 443
        case "http": 80
        default: nil
        }
        return Origin(scheme: scheme, host: url.host?.lowercased() ?? "", port: url.port ?? defaultPort)
    }
}
