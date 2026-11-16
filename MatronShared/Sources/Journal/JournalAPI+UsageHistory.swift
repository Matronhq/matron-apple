import Foundation
import MatronModels

extension JournalAPI {
    /// `GET /usage/history`: each account's weekly meters over the last
    /// `weeks` weeks. A journal that predates the route answers 404
    /// (`JournalAPIError.notFound`).
    public func usageHistory(weeks: Int) async throws -> UsageHistory {
        let object = try await request(path: "/usage/history",
                                       query: [URLQueryItem(name: "weeks", value: String(weeks))])
        guard let history = UsageHistory.parse(object) else {
            throw JournalAPIError.transport("malformed usage history response")
        }
        return history
    }
}
