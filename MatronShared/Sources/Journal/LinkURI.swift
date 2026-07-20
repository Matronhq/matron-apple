import Foundation

/// The QR sign-in payload — the single place the format is known:
/// `matron://link?v=1&server=<URL-encoded base server URL>&code=XXXX-XXXX`.
/// Android carries an equivalent parser; the server never sees the URI.
public enum LinkURI {
    public enum ParseError: Error, Equatable {
        /// Not ours at all — scanner shows "Not a Matron sign-in code."
        case notALink
        /// Ours, but a future version — scanner shows "update the app".
        case unsupportedVersion
        /// Ours and v=1, but the parts don't parse.
        case malformed
    }

    public static func format(server: URL, code: String) -> String {
        var components = URLComponents()
        components.scheme = "matron"
        components.host = "link"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "server", value: server.absoluteString),
            URLQueryItem(name: "code", value: code),
        ]
        return components.url!.absoluteString
    }

    public static func parse(_ raw: String) throws -> (server: URL, code: String) {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "matron", components.host?.lowercased() == "link"
        else { throw ParseError.notALink }
        let value = { (name: String) in components.queryItems?.first(where: { $0.name == name })?.value }
        guard let version = value("v") else { throw ParseError.malformed }
        guard version == "1" else { throw ParseError.unsupportedVersion }
        guard let serverRaw = value("server"), let server = URL(string: serverRaw),
              isAllowedServerScheme(server),
              let codeRaw = value("code"), PairingCode.isPlausible(codeRaw)
        else { throw ParseError.malformed }
        return (server, PairingCode.display(codeRaw))
    }

    /// `https` is always fine; cleartext `http` is only fine for a local
    /// dev homeserver, never a real host reached over Wi-Fi/LAN — a QR
    /// code encoding cleartext http to a real IP would leak the session
    /// token to anyone on the network path. Mirrors (manually, since
    /// `ServerURLValidator` doesn't expose this as a reusable helper)
    /// `ServerURLValidator.normalize`'s `isLocalhostHost` carve-out exactly
    /// — keep the two in sync if that check ever changes.
    private static func isAllowedServerScheme(_ url: URL) -> Bool {
        switch url.scheme {
        case "https": return true
        case "http":
            let host = url.host ?? ""
            return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
        default: return false
        }
    }
}
