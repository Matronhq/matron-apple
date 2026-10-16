import Foundation
import MatronChat
import MatronEvents

/// What one snapshot's timeline says about its consent cards and tracker
/// item cards, read in one walk before `ChatViewModel` builds its rows.
///
/// **Agent-chat cards.** Answering a chat card is an HTTP call, so the tap
/// leaves no event of its own — but the journal records the decision in the
/// card's conversation twice over: the consent item's `closed` marker (every
/// way the ask leaves `awaiting_user`: a tap on any device, the Coordinator,
/// the 24 h sweep, the room closing) and, for the Coordinator, a
/// `consent_decision` event. Reading those is what settles a card decided
/// anywhere but here, on every device, after a relaunch and for history
/// loaded later.
///
/// **Item cards.** Every `created` and `closed` item marker used to draw its
/// own card from its frozen payload, so a decided item showed twice: a
/// "Needs you" card that never cleared, and a "Done" card under it. An item
/// now shows once — at its most recent `created`/`closed` marker, in the
/// state of its most recent marker of any kind. The one-line `commented` /
/// `reopened` notes are events, not copies of the item, and stay.
///
/// **People cards.** A person-to-person card is answered only through its
/// tracker mirror, which the journal files in the same tick as the card and
/// marks with the card's consent kind (`contact`, `share`, `room`,
/// `session`) — but without naming the ask. So a card's mirror is the first
/// `created` marker of its kind after it, and the card is
/// re-stated with that item, open or closed as its latest marker says.
struct TimelineConsentFold: Equatable {
    /// Settled chat cards, keyed by the card's event id.
    var chatResolutions: [String: AgentChatCardState] = [:]
    /// The Coordinator's answer to a chat or spawn card, keyed by the
    /// card's event id: what the card's "Approved by the Coordinator —
    /// <reason>" badge reads.
    var coordinatorDecisions: [String: ConsentDecisionEvent] = [:]
    /// Ids of item-card rows superseded by a later card for the same item.
    var hiddenItemRows: Set<String> = []
    /// The surviving card per item, re-stated where a later marker changed
    /// what it should show. Keyed by row id.
    var restatedItemMarkers: [String: ItemMarkerEvent] = [:]
    /// People cards whose mirror item was found, re-stated with it. Keyed
    /// by row id; a card without a mirror in the snapshot is absent.
    var restatedPeopleCards: [String: PersonConsentCard] = [:]

    static func read(_ items: [TimelineItem]) -> TimelineConsentFold {
        var fold = TimelineConsentFold()
        // The latest chat card per ask: a renewed ask (a fresh one after a
        // decline or an expiry) reuses the key, and a decision is always
        // about the newest card for it.
        var latestChatCard: [String: String] = [:]
        // The latest spawn card per `request_id`, for the same reason.
        var latestSpawnCard: [String: String] = [:]
        // Cards not yet claimed by a consent item, oldest first — the
        // pairing for markers from journals that do not name the ask. The
        // journal files the item in the same tick it journals the card, so
        // the card's own `created` marker is the next consent marker after
        // it.
        var unpairedChatCards: [String] = []
        var chatCardForItem: [String: String] = [:]
        // Items whose `created` marker named the ask: their journal names it
        // on every close it makes, so a close that names nothing is by hand.
        var itemsNamingTheirAsk: Set<String> = []
        var lastItemCard: [String: (rowID: String, marker: ItemMarkerEvent)] = [:]
        var latestItemMarker: [String: ItemMarkerEvent] = [:]
        // People cards waiting for their mirror, oldest first, and the
        // card each mirror item was paired with. A mirror pairs with the
        // newest waiting card of its kind: its own card was journalled just
        // before it, and an older one still waiting lost its mirror.
        var unpairedPeopleCards: [(rowID: String, card: PersonConsentCard)] = []
        var peopleCardForItem: [String: (rowID: String, card: PersonConsentCard)] = [:]
        // Open or closed, by the markers that change it — a note on a
        // closed item does not reopen it.
        var itemClosed: [String: Bool] = [:]

        for item in items {
            switch item.kind {
            case .agentChatRequest(let eventID, let request):
                latestChatCard[request.askID] = eventID
                unpairedChatCards.append(eventID)

            case .agentSpawnRequest(let eventID, let request):
                latestSpawnCard[request.requestID] = eventID

            case .personConsentCard(_, let card):
                unpairedPeopleCards.append((item.id, card))

            case .consentDecision(_, let decision):
                guard let askID = decision.askID else { break }
                switch decision.kind {
                case .chat:
                    if let card = latestChatCard[askID] {
                        fold.chatResolutions[card] = .answeredByCoordinator(approved: decision.decision == .approve)
                        fold.coordinatorDecisions[card] = decision
                    }
                case .spawn:
                    if let card = latestSpawnCard[askID] { fold.coordinatorDecisions[card] = decision }
                }

            case .itemMarker(_, let marker):
                if marker.consent == "chat" {
                    fold.readChatConsentMarker(
                        marker, latestChatCard: latestChatCard,
                        unpairedChatCards: &unpairedChatCards, chatCardForItem: &chatCardForItem,
                        itemsNamingTheirAsk: &itemsNamingTheirAsk)
                }
                if marker.action == .created, let consent = marker.consent,
                   peopleCardForItem[marker.itemID] == nil,
                   let index = unpairedPeopleCards.lastIndex(where: { $0.card.consentKind == consent }) {
                    peopleCardForItem[marker.itemID] = unpairedPeopleCards.remove(at: index)
                }
                switch marker.action {
                case .closed: itemClosed[marker.itemID] = true
                case .created, .reopened: itemClosed[marker.itemID] = false
                default: break
                }
                latestItemMarker[marker.itemID] = marker
                if marker.action == .created || marker.action == .closed {
                    if let previous = lastItemCard[marker.itemID] {
                        fold.hiddenItemRows.insert(previous.rowID)
                    }
                    lastItemCard[marker.itemID] = (item.id, marker)
                }

            default:
                break
            }
        }

        for (itemID, card) in lastItemCard {
            guard let latest = latestItemMarker[itemID] else { continue }
            let restated = card.marker.restated(as: latest)
            if restated != card.marker { fold.restatedItemMarkers[card.rowID] = restated }
        }
        for (itemID, paired) in peopleCardForItem {
            let closed = itemClosed[itemID] ?? false
            fold.restatedPeopleCards[paired.rowID] = paired.card.withMirror(
                closed ? .closed(itemID: itemID) : .open(itemID: itemID))
        }
        return fold
    }

    private mutating func readChatConsentMarker(
        _ marker: ItemMarkerEvent,
        latestChatCard: [String: String],
        unpairedChatCards: inout [String],
        chatCardForItem: inout [String: String],
        itemsNamingTheirAsk: inout Set<String>
    ) {
        switch marker.action {
        case .created:
            // Only a card no other item has claimed: when this marker's own
            // card fell outside the snapshot, the latest card for the key is
            // an older ask's, already paired with its own item.
            let card: String?
            if let askID = marker.consentAsk {
                card = latestChatCard[askID].flatMap { unpairedChatCards.contains($0) ? $0 : nil }
            } else {
                card = unpairedChatCards.last
            }
            guard let card else { return }
            chatCardForItem[marker.itemID] = card
            if marker.consentAsk != nil { itemsNamingTheirAsk.insert(marker.itemID) }
            unpairedChatCards.removeAll { $0 == card }
        case .closed:
            // The item's own card first: the sweep that closes an old item
            // after its ask was renewed names the same ask as the new card.
            // Its `created` marker outside the snapshot, the key's latest
            // card stands in — but never one another item has claimed.
            let unclaimedForAsk = marker.consentAsk.flatMap { latestChatCard[$0] }
                .flatMap { unpairedChatCards.contains($0) ? $0 : nil }
            guard let card = chatCardForItem[marker.itemID] ?? unclaimedForAsk else { return }
            // A Coordinator decision already read (its `consent_decision`
            // follows the close, but a replay can reorder) keeps its badge.
            if case .answeredByCoordinator = chatResolutions[card] { return }
            if itemsNamingTheirAsk.contains(marker.itemID), marker.consentAsk == nil, marker.consentOutcome == nil {
                return
            }
            guard let resolution = Self.chatResolution(closing: marker) else { return }
            // A decision, once read, is not undone by a later close saying
            // the ask lapsed (a reopened mirror swept shut again).
            if case .answered = chatResolutions[card], resolution == .expired { return }
            chatResolutions[card] = resolution
        default:
            break
        }
    }

    /// How a consent item's closing marker settles its chat card, or `nil`
    /// when the close is not the ask's: the user can close the mirror by
    /// hand, and the ask is still waiting after that.
    ///
    /// A journal that names the ask (`consent_ask`) says how it ended in
    /// `consent_outcome`; a close carrying neither is a hand close. Older
    /// journals name neither, and say the outcome only in the closing note
    /// they wrote (matron-journal `chatConsentClosing`), so their notes are
    /// read by those fixed openings — "Approved", "Declined", "… by the
    /// Coordinator", and the lapses — and any other note is left alone.
    static func chatResolution(closing marker: ItemMarkerEvent) -> AgentChatCardState? {
        let note = marker.comment?.body ?? ""
        let byCoordinator = marker.decidedBy == "coordinator" || note.hasPrefix("Approved by the Coordinator")
            || note.hasPrefix("Declined by the Coordinator")
        let approved: Bool
        if marker.consentAsk != nil || marker.consentOutcome != nil {
            switch marker.consentOutcome {
            case "approved": approved = true
            case "denied": approved = false
            case .some: return .expired
            case nil: return nil
            }
        } else if note.hasPrefix("Approved") {
            approved = true
        } else if note.hasPrefix("Declined") {
            approved = false
        } else if lapsedNoteOpenings.contains(where: note.hasPrefix) {
            return .expired
        } else {
            return nil
        }
        return byCoordinator ? .answeredByCoordinator(approved: approved) : .answered(approved: approved)
    }

    /// `chatConsentClosing`'s notes for an ask that lapsed: expired, the
    /// room closed under it, or the ask gone.
    private static let lapsedNoteOpenings = ["Expired", "The room was closed", "Closed — "]
}
