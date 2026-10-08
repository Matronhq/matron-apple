import Foundation

public enum ServerURLValidator {
    public enum ValidationError: Error, Equatable {
        case empty
        case insecureScheme
        case noHost
        case malformed
    }

    public static func normalize(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: withScheme) else {
            throw ValidationError.malformed
        }
        guard let scheme = components.scheme else {
            throw ValidationError.malformed
        }
        guard let host = components.host, !host.isEmpty else {
            throw ValidationError.noHost
        }
        // `https://` everywhere except localhost-ish dev hosts. Plain http
        // to localhost is the standard pattern for talking to a local dev
        // homeserver (Docker matron-server in tests/integration runs on
        // http://localhost:6167; Element Web + matrix-js-sdk accept the
        // same exception). Production matron-server always runs behind
        // HTTPS, so the carve-out can't expose remote credentials over
        // plaintext.
        let isLocalhostHost = host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host == "[::1]"
        if scheme == "http" {
            guard isLocalhostHost else { throw ValidationError.insecureScheme }
        } else if scheme != "https" {
            throw ValidationError.insecureScheme
        }

        var rebuilt = components
        rebuilt.path = rebuilt.path.hasSuffix("/") && rebuilt.path.count == 1 ? "" : rebuilt.path
        if rebuilt.path.hasSuffix("/") {
            rebuilt.path.removeLast()
        }
        guard let url = rebuilt.url else {
            throw ValidationError.malformed
        }
        return url
    }
}
