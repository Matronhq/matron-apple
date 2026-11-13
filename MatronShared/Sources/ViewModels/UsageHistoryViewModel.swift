import Foundation
import os
import MatronJournal
import MatronModels

/// What the usage history reads.
public protocol UsageHistoryProviding: Sendable {
    func usageHistory(weeks: Int) async throws -> UsageHistory
}

/// Production adapter over the session's `JournalAPI`.
public struct JournalUsageHistoryService: UsageHistoryProviding {
    private let api: JournalAPI

    public init(api: JournalAPI) {
        self.api = api
    }

    public func usageHistory(weeks: Int) async throws -> UsageHistory {
        try await api.usageHistory(weeks: weeks)
    }
}

/// The Boxes screen's usage history: per account, how much of each week's
/// allowance went unused. Read once when shown and again on a pull or a
/// return to the screen; it changes once a week per account.
@Observable @MainActor
public final class UsageHistoryViewModel {
    public private(set) var history: UsageHistory?
    public private(set) var hasLoaded = false
    public private(set) var errorMessage: String?
    /// The chosen meter's id (`UsageMeterChoice.id`).
    public var choiceID = UsageMeterChoice.primaryID

    private let api: any UsageHistoryProviding
    private static let logger = Logger(subsystem: "chat.matron", category: "usage-history")

    public init(api: any UsageHistoryProviding) {
        self.api = api
    }

    public func load() async {
        do {
            history = try await api.usageHistory(weeks: UsageHistoryTable.defaultWeeks)
            errorMessage = nil
        } catch JournalAPIError.notFound {
            errorMessage = "This journal doesn't keep usage history yet. It needs an update."
        } catch {
            Self.logger.error("usage history load failed: \(String(describing: error), privacy: .public)")
            errorMessage = "Couldn't load the usage history. Try again."
        }
        hasLoaded = true
    }

    public var choices: [UsageMeterChoice] {
        history.map(UsageHistoryTable.choices(for:)) ?? []
    }

    /// The chosen meter, falling back to the headline one if the choice
    /// has gone (its last account dropped out of the window).
    public var choice: UsageMeterChoice {
        choices.first { $0.id == choiceID } ?? UsageMeterChoice(id: UsageMeterChoice.primaryID, title: "All models")
    }

    public func table(now: Date = Date()) -> UsageHistoryTable {
        UsageHistoryTable.build(history ?? UsageHistory(accounts: []), choice: choice, now: now)
    }
}
