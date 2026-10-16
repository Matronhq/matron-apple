import XCTest
import MatronModels
@testable import MatronEvents

/// The hand-over card (`mission_handover`) and the contributor level on a
/// mission share. Unlike the other people cards, the hand-over carries what
/// the app needs to answer it itself: the brief, the counts and — on the
/// owner's side — the files, which the owner may leave behind.
final class MissionHandoverCardTests: XCTestCase {
    private func ownerPayload() -> [String: Any] {
        [
            "kind": "mission_handover", "direction": "out", "grant_id": "gr_9", "level": "owner",
            "owner": ["user_id": 1, "name": "alice"],
            "grantee": ["name": "bob", "address": "bob"],
            "subject": ["kind": "mission", "id": "ms_1", "num": 42, "title": "Cover editor"],
            "brief": "  Where it stands: the editor ships.\nNext: the print proofs.  ",
            "preview": [
                "missions": 1, "milestones": 4, "items": 6, "comments": 12,
                "attachments": [
                    ["media_id": "md_1", "name": "proof.pdf", "mime": "application/pdf", "size": 240_000, "item_num": 12],
                    ["media_id": "md_2", "name": "cover.png", "mime": "image/png", "size": 1_200_000, "item_num": 14],
                    ["media_id": "", "name": "no id"],
                ],
            ],
            "from_device_id": 3, "from_name": "box-a", "from_convo_id": "c1",
        ]
    }

    private func recipientPayload() -> [String: Any] {
        [
            "kind": "mission_handover", "direction": "in", "grant_id": "gr_9", "level": "owner",
            "owner": ["user_id": 1, "name": "alice"],
            "grantee": ["name": "bob", "address": "bob"],
            "subject": ["kind": "mission", "title": "Cover editor"],
            "brief": "Where it stands.",
            "preview": ["missions": 1, "milestones": 4, "items": 6, "comments": 12, "attachments": 2],
        ]
    }

    func testTheOwnersCardNamesTheRecipientAndListsTheFiles() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: ownerPayload()))
        XCTAssertEqual(card.kind, .missionHandover)
        XCTAssertEqual(card.direction, .outgoing)
        XCTAssertEqual(card.personName, "bob")
        XCTAssertEqual(card.askID, "gr_9")
        XCTAssertEqual(card.consentKind, "handover")
        XCTAssertEqual(card.consentLink, .handover(id: "gr_9"))
        XCTAssertEqual(card.consentLink?.url, "matron://consent/handover/gr_9")
        XCTAssertEqual(card.title, "Mission hand-over")
        XCTAssertEqual(card.headline, "Your agent asks to hand this mission over to bob.")
        XCTAssertEqual(card.missionTitle, "Cover editor")

        let handover = try XCTUnwrap(card.handover)
        XCTAssertEqual(handover.subjectKind, .mission)
        XCTAssertEqual(handover.subjectNum, 42)
        XCTAssertEqual(handover.brief, "Where it stands: the editor ships.\nNext: the print proofs.")
        XCTAssertEqual(handover.milestones, 4)
        XCTAssertEqual(handover.items, 6)
        XCTAssertEqual(handover.comments, 12)
        // A file without an id cannot be left behind, so it is not listed.
        XCTAssertEqual(handover.attachments.map(\.mediaID), ["md_1", "md_2"])
        XCTAssertEqual(handover.attachments[0], .init(mediaID: "md_1", name: "proof.pdf", mime: "application/pdf",
                                                      size: 240_000, itemNum: 12))
        XCTAssertEqual(handover.attachmentCount, 2)
    }

    func testTheRecipientsCardNamesTheOwnerAndCountsTheFiles() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: recipientPayload()))
        XCTAssertEqual(card.direction, .incoming)
        XCTAssertEqual(card.personName, "alice")
        XCTAssertEqual(card.headline, "alice wants to hand a mission over to you.")
        let handover = try XCTUnwrap(card.handover)
        XCTAssertNil(handover.subjectNum)
        XCTAssertTrue(handover.attachments.isEmpty)
        XCTAssertEqual(handover.attachmentCount, 2)
        XCTAssertEqual(handover.countsLine(), "4 milestones · 6 items · 12 comments · 2 files")
    }

    func testAProjectHandOverCountsItsMissions() throws {
        var payload = recipientPayload()
        payload["subject"] = ["kind": "project", "title": "Spring launch"]
        payload["preview"] = ["missions": 3, "milestones": 1, "items": 0, "comments": 0, "attachments": 0]
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: payload))
        XCTAssertEqual(card.title, "Project hand-over")
        XCTAssertEqual(card.headline, "alice wants to hand a project over to you.")
        XCTAssertEqual(card.handover?.countsLine(), "3 missions · 1 milestone")
    }

    func testCountsFollowTheTickedFiles() throws {
        let handover = try XCTUnwrap(PersonConsentCard.parse(payload: ownerPayload())?.handover)
        XCTAssertEqual(handover.countsLine(includedAttachments: 1), "4 milestones · 6 items · 12 comments · 1 file")
        XCTAssertEqual(handover.countsLine(includedAttachments: 0), "4 milestones · 6 items · 12 comments")
    }

    func testAnEmptyPreviewStillSaysSomething() {
        XCTAssertEqual(MissionHandoverDetails(brief: "b").countsLine(), "Nothing but the brief")
    }

    func testTheExcludedFilesAreTheUntickedOnesInCardOrder() throws {
        let handover = try XCTUnwrap(PersonConsentCard.parse(payload: ownerPayload())?.handover)
        XCTAssertEqual(handover.excludedMediaIDs(included: ["md_1", "md_2"]), [])
        XCTAssertEqual(handover.excludedMediaIDs(included: ["md_1"]), ["md_2"])
        XCTAssertEqual(handover.excludedMediaIDs(included: []), ["md_1", "md_2"])
    }

    func testAThinPayloadIsStillAHandOverCard() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: ["kind": "mission_handover"]))
        XCTAssertEqual(card.direction, .incoming)
        XCTAssertEqual(card.personLabel, "Another person")
        XCTAssertNil(card.consentLink)
        XCTAssertEqual(card.handover?.brief, "")
        XCTAssertEqual(card.handover?.missions, 1)
    }

    func testTheMirrorKeepsTheHandOverDetails() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: ownerPayload()))
        let paired = card.withMirror(.open(itemID: "it_1"))
        XCTAssertEqual(paired.handover, card.handover)
        XCTAssertEqual(paired.level, "owner")
    }

    // MARK: Keep contributing

    func testTheKeepLevelIsReadUnlessTheAskSaysContribute() throws {
        XCTAssertEqual(PersonConsentCard.parse(payload: ownerPayload())?.handover?.keepLevel, .read)
        for (raw, expected) in [("contribute", MissionHandoverDetails.KeepLevel.contribute), ("read", .read),
                                ("owner", .read), ("", .read)] {
            var payload = ownerPayload()
            payload["keep_level"] = raw
            XCTAssertEqual(PersonConsentCard.parse(payload: payload)?.handover?.keepLevel, expected, raw)
        }
    }

    func testTheOwnersSwitchStartsFromTheAsk() throws {
        var payload = ownerPayload()
        payload["keep_level"] = "contribute"
        XCTAssertEqual(PersonConsentCard.parse(payload: payload)?.handover?.keepContributing, true)
        payload["keep_level"] = "read"
        XCTAssertEqual(PersonConsentCard.parse(payload: payload)?.handover?.keepContributing, false)
    }

    func testTheOwnersHintFollowsTheSwitch() {
        XCTAssertEqual(MissionHandoverDetails.keepHint(keepContributing: false), "You keep read access to their copy")
        XCTAssertEqual(MissionHandoverDetails.keepHint(keepContributing: true),
                       "You can keep adding milestones, items and comments")
        XCTAssertEqual(MissionHandoverDetails.keepSwitchLabel, "Keep contributing after the hand-over")
    }

    func testTheRecipientIsToldWhatTheOwnerKeeps() throws {
        var payload = recipientPayload()
        payload["keep_level"] = "contribute"
        XCTAssertEqual(PersonConsentCard.parse(payload: payload)?.keepLine,
                       "alice stays on as a contributor; you can end that any time.")
        payload["keep_level"] = "read"
        XCTAssertEqual(PersonConsentCard.parse(payload: payload)?.keepLine, "alice keeps read access.")
        payload.removeValue(forKey: "keep_level")
        XCTAssertEqual(PersonConsentCard.parse(payload: payload)?.keepLine, "alice keeps read access.")
    }

    func testOnlyTheRecipientsHandOverCardHasAKeepLine() throws {
        var owner = ownerPayload()
        owner["keep_level"] = "contribute"
        XCTAssertNil(PersonConsentCard.parse(payload: owner)?.keepLine)
        XCTAssertNil(PersonConsentCard.parse(payload: share(level: "contribute", direction: "in"))?.keepLine)
    }

    // MARK: Contributors

    private func share(level: String?, direction: String) -> [String: Any] {
        var payload: [String: Any] = [
            "kind": "mission_share", "direction": direction, "grant_id": "gr_1",
            "owner": ["user_id": 1, "name": "alice"], "grantee": ["name": "bob", "address": "bob"],
            "mission": ["id": "m_1", "num": 4, "title": "Cover editor"],
        ]
        if let level { payload["level"] = level }
        return payload
    }

    func testAContributeShareSaysTheyCanContribute() throws {
        let out = try XCTUnwrap(PersonConsentCard.parse(payload: share(level: "contribute", direction: "out")))
        XCTAssertTrue(out.canContribute)
        XCTAssertEqual(out.accessLine, "Can contribute")
        XCTAssertEqual(out.headline, "Your agent asks to share a mission with bob, who can contribute.")
        let incoming = try XCTUnwrap(PersonConsentCard.parse(payload: share(level: "contribute", direction: "in")))
        XCTAssertEqual(incoming.headline, "alice wants to share a mission with you. You can contribute.")
    }

    func testAReadShareStaysReadOnly() throws {
        for level in ["read", nil] {
            let card = try XCTUnwrap(PersonConsentCard.parse(payload: share(level: level, direction: "out")))
            XCTAssertFalse(card.canContribute)
            XCTAssertEqual(card.accessLine, "Read-only")
            XCTAssertEqual(card.headline, "Your agent asks to share a mission with bob, read-only.")
        }
    }

    func testOnlyAShareHasAnAccessLine() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: ownerPayload()))
        XCTAssertNil(card.accessLine)
    }

    // MARK: Markers

    func testAMilestoneMarkerNamesItsContributor() throws {
        let marker = try XCTUnwrap(MilestoneMarkerEvent.parse(payload: [
            "milestone_id": "ml_1", "num": 7, "kind": "progress", "title": "Proofs in",
            "mission_id": "ms_1", "mission_num": 3, "by": "agent",
            "person": ["name": "bob", "via": "agent"],
        ]))
        XCTAssertEqual(marker.person, Contributor(name: "bob", via: .agent))
        let own = try XCTUnwrap(MilestoneMarkerEvent.parse(payload: [
            "milestone_id": "ml_2", "num": 8, "kind": "progress", "title": "Mine",
            "mission_id": "ms_1", "mission_num": 3, "by": "agent",
        ]))
        XCTAssertNil(own.person)
    }

    func testAClosedOrLeftMarkerSaysWhoItWasHandedTo() throws {
        let closed = try XCTUnwrap(MissionMarkerEvent.parse(payload: [
            "mission_id": "ms_1", "num": 3, "action": "closed", "by": "user", "handed_over": ["to": "bob"],
        ]))
        XCTAssertEqual(closed.handedOverTo, "bob")
        let left = try XCTUnwrap(MissionMarkerEvent.parse(payload: [
            "mission_id": "ms_1", "num": 3, "action": "left", "by": "agent", "handed_over": ["to": " "],
        ]))
        XCTAssertNil(left.handedOverTo)
        let plain = try XCTUnwrap(MissionMarkerEvent.parse(payload: [
            "mission_id": "ms_1", "num": 3, "action": "closed", "by": "user",
        ]))
        XCTAssertNil(plain.handedOverTo)
    }
}
