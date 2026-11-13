import MatronDesignSystem
import MatronModels
import MatronViewModels

/// What the item page's host does the same way on iOS (`ItemDetailHost`)
/// and the Mac (`MacItemDetailHost`): its reply rows and buttons, and where
/// a tapped item or consent link goes.
@MainActor
enum ItemDetailHostHelpers {
    /// The thread's buttons for replies the agent hasn't got yet — Send
    /// now, Cancel, and Edit and resend — wired to `vm`.
    static func replyDelivery(_ vm: ItemDetailViewModel) -> ItemDetailView.ReplyDeliveryActions {
        .init(sendQueuedNow: { id in Task { await vm.sendQueuedReplyNow(commentID: id) } },
              cancelQueued: { id in Task { await vm.cancelQueuedReply(commentID: id) } },
              editAndResend: { vm.editAndResend(commentID: $0) },
              sendPendingNow: { Task { await vm.sendPendingNow() } },
              cancelPending: { id in Task { await vm.cancelPendingReply(localID: id) } },
              editQueued: { id in Task { await vm.editQueuedReply(commentID: id) } },
              cancelQueuedEdit: { Task { await vm.cancelQueuedReplyEdit() } })
    }

    /// Replies still settling (`sendingReplies`) as "Sending…" rows —
    /// attempts 0, no error — skipping any whose outbox row already shows.
    static func sending(_ vm: ItemDetailViewModel) -> [ItemDetailView.PendingComment] {
        let shown = Set(vm.pendingComments.map(\.localID))
        return vm.sendingReplies.filter { !shown.contains($0.localID) }.map {
            .init(id: $0.localID, body: $0.body, attachmentCount: $0.attachmentCount, attempts: 0, lastError: nil)
        }
    }

    /// A tapped `matron://item/<n>` link, resolved by the shared
    /// `TrackerItemLinkResolver`: a known number opens, a number this device
    /// still doesn't have leaves the item on screen and says so in the
    /// tracker alert. A link to the item already on screen (`shownItemID`)
    /// is a no-op rather than a second identical push.
    static func trackerItemLinkOutcome(num: Int, shownItemID: String, deps: AppDependencies?,
                                       session: UserSession) async -> TrackerItemLinkOutcome {
        guard let deps else { return .ignore }
        let outcome = await deps.trackerItemLinkOutcome(num: num, session: session)
        if case .open(let id) = outcome, id == shownItemID { return .ignore }
        return outcome
    }

    /// A consent chip: a spawn ask's card lives in the item's origin
    /// conversation (the card itself is already drawn inline above the
    /// body — the chip is the way to the timeline around it); a chat ask's
    /// card lives in the room it is about. A person-to-person ask's card
    /// sits beside its mirror, in the item's origin conversation.
    static func openConsent(_ consent: ConsentLink, originConvoID: String?,
                            openConversation: (String) -> Void) {
        switch consent {
        case .spawn, .contact, .share, .room, .session, .handover, .invite:
            guard let originConvoID else { return }
            openConversation(originConvoID)
        case .chat(let roomID, _):
            openConversation(roomID)
        }
    }
}
