import Foundation
import MatronModels

/// Why `GET /briefings/latest` or `POST /briefings/refresh` did not answer
/// with a briefing. Anything else surfaces as `JournalAPIError`.
public enum BriefingsError: Error, Equatable, Sendable {
    /// 404: a journal that predates briefings. The card hides.
    case unsupported
    /// 429: asked too soon; the next ask may go at `retryAt` (`nil` when the
    /// journal did not say).
    case rateLimited(retryAt: Date?)
    /// 409 `{blocked_by: 'no_coordinator'}`: no Coordinator to ask.
    case noCoordinator
    /// 503 `{error: 'busy'}`: the firer is at its in-flight bound.
    case busy
}

extension BriefingsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "This server doesn't have briefings yet."
        case .rateLimited: return "A briefing was asked for moments ago — try again shortly."
        case .noCoordinator: return "Choose a Coordinator first."
        case .busy: return "The Coordinator is busy — try again shortly."
        }
    }
}

/// `GET /briefings/latest` and `POST /briefings/refresh` (journal
/// "Coordinator briefings"). A protocol so `LatestBriefingStore` tests fake it.
public protocol BriefingsProviding: Sendable {
    /// Throws `BriefingsError.unsupported` on a journal without the route.
    func latestBriefing() async throws -> LatestBriefing
    /// Asks the Coordinator for a fresh briefing; answers the same shape as
    /// `latestBriefing()`, with the refresh now pending. Throws
    /// `BriefingsError` for 404, 429, 409 and 503.
    func refreshBriefing() async throws -> LatestBriefing
}

extension JournalAPI: BriefingsProviding {
    public func latestBriefing() async throws -> LatestBriefing {
        let (data, response) = try await rawRequest(path: "/briefings/latest", method: "GET", body: nil)
        return try Self.decodeBriefingsAnswer(status: response.statusCode, data: data, accept: [200])
    }

    public func refreshBriefing() async throws -> LatestBriefing {
        let (data, response) = try await rawRequest(path: "/briefings/refresh", method: "POST", body: nil)
        return try Self.decodeBriefingsAnswer(status: response.statusCode, data: data, accept: [200, 202])
    }

    /// One mapping for both routes: the statuses the briefings contract
    /// names become `BriefingsError`; the rest go through the shared
    /// `JournalAPIError` mapping.
    static func decodeBriefingsAnswer(status: Int, data: Data, accept: Set<Int>) throws -> LatestBriefing {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard accept.contains(status) else {
            switch status {
            case 404:
                throw BriefingsError.unsupported
            case 429:
                let retryAt = (obj?["retry_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                throw BriefingsError.rateLimited(retryAt: retryAt)
            case 409 where obj?["blocked_by"] as? String == "no_coordinator":
                throw BriefingsError.noCoordinator
            case 503 where obj?["error"] as? String == "busy":
                throw BriefingsError.busy
            default:
                throw Self.error(status: status, data: data)
            }
        }
        guard let obj, let latest = LatestBriefing(json: obj) else {
            throw JournalAPIError.transport("malformed briefings response")
        }
        return latest
    }
}
