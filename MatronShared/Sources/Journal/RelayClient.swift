import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one shared piece of Matron infrastructure. Forks: change this constant.
public enum MatronRelay {
    public static let baseURL = URL(string: "https://push.matron.chat")!
}

public struct Rendezvous: Equatable, Sendable {
    public let rid: String
    public let secret: String
    public let expiresIn: Int
    public init(rid: String, secret: String, expiresIn: Int) {
        self.rid = rid; self.secret = secret; self.expiresIn = expiresIn
    }
}

public enum RendezvousPollResult: Equatable, Sendable {
    case waiting
    case offered(box: Data)
}

public enum RelayError: Error, Equatable {
    case notFound      // unknown/expired rendezvous — regenerate
    case conflict      // someone offered first
    case forbidden     // secret mismatch (should never happen for the creator)
    case rateLimited
    case transport(String)
}

/// Talks to the shared relay's rendezvous endpoints. Unauthenticated by
/// design — the relay carries only an opaque, app-encrypted offer box,
/// never a token or a readable {server, code}, and the approve tap on the
/// signed-in phone remains the only credential gate.
public protocol RelayRendezvousing: Sendable {
    func createRendezvous() async throws -> Rendezvous
    func pollRendezvous(rid: String, secret: String) async throws -> RendezvousPollResult
    func offerRendezvous(rid: String, box: Data) async throws
}

public struct RelayClient: RelayRendezvousing {
    let baseURL: URL
    let urlSession: URLSession

    public init(baseURL: URL = MatronRelay.baseURL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func createRendezvous() async throws -> Rendezvous {
        let (data, status) = try await send(Self.createRequest(baseURL: baseURL))
        return try Self.mapCreate(status: status, data: data)
    }

    public func pollRendezvous(rid: String, secret: String) async throws -> RendezvousPollResult {
        let (data, status) = try await send(Self.pollRequest(baseURL: baseURL, rid: rid, secret: secret))
        return try Self.mapPoll(status: status, data: data)
    }

    public func offerRendezvous(rid: String, box: Data) async throws {
        let (_, status) = try await send(Self.offerRequest(baseURL: baseURL, rid: rid, box: box))
        try Self.mapOffer(status: status)
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw RelayError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw RelayError.transport("not HTTP") }
        return (data, http.statusCode)
    }

    // MARK: - Pure request builders / response mappers (unit-tested)

    static func createRequest(baseURL: URL) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("link/rendezvous"))
        request.httpMethod = "POST"
        return request
    }

    static func pollRequest(baseURL: URL, rid: String, secret: String) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent("link/rendezvous/\(rid)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "secret", value: secret)]
        return URLRequest(url: components.url!)
    }

    static func offerRequest(baseURL: URL, rid: String, box: Data) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("link/rendezvous/\(rid)/offer"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["box": Base64URL.encode(box)])
        return request
    }

    static func mapCreate(status: Int, data: Data) throws -> Rendezvous {
        try mapError(status, success: 201)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rid = obj["rid"] as? String,
              let secret = obj["secret"] as? String,
              let expiresIn = obj["expires_in"] as? Int else {
            throw RelayError.transport("malformed relay response")
        }
        return Rendezvous(rid: rid, secret: secret, expiresIn: expiresIn)
    }

    static func mapPoll(status: Int, data: Data) throws -> RendezvousPollResult {
        if status == 204 { return .waiting }
        try mapError(status, success: 200)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let boxString = obj["box"] as? String,
              let box = Base64URL.decode(boxString) else {
            throw RelayError.transport("malformed relay response")
        }
        return .offered(box: box)
    }

    static func mapOffer(status: Int) throws {
        try mapError(status, success: 204)
    }

    private static func mapError(_ status: Int, success: Int) throws {
        switch status {
        case success: return
        case 404: throw RelayError.notFound
        case 409: throw RelayError.conflict
        case 403: throw RelayError.forbidden
        case 429: throw RelayError.rateLimited
        default: throw RelayError.transport("HTTP \(status)")
        }
    }
}
