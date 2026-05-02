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
        guard let scheme = components.scheme, scheme == "https" else {
            throw ValidationError.insecureScheme
        }
        guard let host = components.host, !host.isEmpty else {
            throw ValidationError.noHost
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
