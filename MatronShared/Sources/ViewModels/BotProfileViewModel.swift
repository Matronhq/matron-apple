import Foundation
import MatronChat
import MatronModels

/// Cross-platform view-model backing the bot-profile UI presented from the
/// chat detail's ⓘ button. Both `BotProfileView` (iOS, Task 15) and
/// `MacBotProfileSheet` (Mac, Task 15b) consume this exact type so the data
/// shape stays consistent across targets.
///
/// Phase-1's `ChatService.chatSummaries()` contract is "single snapshot then
/// completes," so the call site reads one snapshot, filters by bot, and the
/// view-model holds the result without subscribing to further updates.
/// Phase-2's eventual live-diff stream re-yields when the room list changes;
/// at that point the call site can re-construct this view-model with the
/// fresh snapshot, no internal bookkeeping required.
///
/// Sort order mirrors `ChatListViewModel.byRecencyDescending`:
///   1. Chats with a known `lastActivity` come first, newest → oldest.
///   2. Chats without `lastActivity` (timeline not yet hydrated) sort
///      *after* hydrated rooms, by title for a stable order.
@Observable
@MainActor
public final class BotProfileViewModel {
    public let bot: BotIdentity
    public let chatsForBot: [ChatSummary]

    public init(bot: BotIdentity, allSummaries: [ChatSummary]) {
        self.bot = bot
        self.chatsForBot = allSummaries
            .filter { $0.bot.matrixID == bot.matrixID }
            .sorted(by: Self.byRecencyDescending)
    }

    /// Local copy of the sort predicate — duplicating this small function
    /// avoids leaking `ChatListViewModel`'s internals into a public surface
    /// just for sharing two cases. If a third consumer ever needs the same
    /// ordering, promote it to a free function in `MatronChat`.
    private static func byRecencyDescending(_ a: ChatSummary, _ b: ChatSummary) -> Bool {
        switch (a.lastActivity, b.lastActivity) {
        case let (lhs?, rhs?): return lhs > rhs
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return a.title < b.title
        }
    }
}
