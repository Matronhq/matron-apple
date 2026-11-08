import XCTest

/// Settings → People against local journals with federation on: making an
/// invite link and withdrawing it, opening someone else's link (and the
/// refusals), and Approve on an agent's invite ask showing the link once.
/// Skips unless the journal answers on `RIG_PORT`. The links come in from
/// the runner's environment (`TEST_RUNNER_INVITE_LINK`, the https
/// `TEST_RUNNER_WEB_INVITE_LINK` and friends), minted
/// fresh by the script that seeds the journals; a test whose link is unset
/// skips. Screenshots go to `SHOT_DIR` when set.
final class PeopleUITests: XCTestCase {
    static let lifetimeNote = "Send this link to them yourself. It is shown only now, works once and lasts 7 days. Nobody becomes a contact until they open it and accept."
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var port: String { env["RIG_PORT"] ?? "9810" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let url = URL(string: "http://127.0.0.1:\(port)/snapshot"), Self.answers(url) else {
            throw XCTSkip("rig not running (127.0.0.1:\(port))")
        }
        app = XCUIApplication()
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    /// Whether anything answers at `url` within two seconds.
    private static func answers(_ url: URL) -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = response != nil
            done.signal()
        }.resume()
        return done.wait(timeout: .now() + 3) == .success && ok
    }

    private func shot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }

    private func link(_ key: String) throws -> URL {
        guard let raw = env[key], let url = URL(string: raw) else { throw XCTSkip("\(key) not set") }
        return url
    }

    private func openPeople() {
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let settings = app.buttons["more.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        // The Settings form is lazy: the row exists only once scrolled to.
        let people = app.buttons["settings.people"].firstMatch
        var tries = 0
        while !(people.waitForExistence(timeout: 2) && people.isHittable) && tries < 8 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(people.isHittable, "Settings ▸ People")
        people.tap()
    }

    func test_inviteShowsTheLinkOnce_andWithdraws() {
        openPeople()
        let invite = app.buttons["people.invite"].firstMatch
        XCTAssertTrue(invite.waitForExistence(timeout: 10))
        shot("people-list")
        invite.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", Self.lifetimeNote)).firstMatch.waitForExistence(timeout: 10))
        shot("people-invite-link")
        app.buttons["Done"].firstMatch.tap()
        let withdraw = app.buttons.matching(identifier: "people.invite.withdraw")
        XCTAssertTrue(withdraw.firstMatch.waitForExistence(timeout: 5), "the new invite is listed under Open invites")
        app.swipeUp()
        shot("people-open-invites")
        let before = withdraw.count
        withdraw.firstMatch.tap()
        let gone = NSPredicate(format: "count < %d", before)
        expectation(for: gone, evaluatedWith: withdraw)
        waitForExpectations(timeout: 10)
    }

    func test_openingALinkShowsWhoItIsFrom_thenAccepts() throws {
        let url = try link("INVITE_LINK")
        app.open(url)
        let address = app.staticTexts["people.add.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["people.add.fingerprint"].exists)
        XCTAssertTrue(app.staticTexts["Compare this fingerprint with them another way, in person or on a call, before you accept."].exists)
        shot("people-add-contact")
        app.buttons["people.add.accept"].tap()
        XCTAssertTrue(app.staticTexts["Sent. You become contacts when their journal confirms."].waitForExistence(timeout: 15))
        shot("people-add-accepted")
    }

    /// The https link, pasted: WhatsApp and mail make it tappable, but
    /// a link from another journal opens that journal's page, so pasting
    /// stays the way in.
    func test_pastingTheHttpsLinkShowsWhoItIsFrom() throws {
        let raw = try link("WEB_INVITE_LINK").absoluteString
        openPeople()
        let open = app.buttons["people.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(raw)
        shot("people-paste-https-link")
        app.alerts.buttons["Open"].tap()
        XCTAssertTrue(app.staticTexts["people.add.address"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["people.add.fingerprint"].exists)
        shot("people-add-contact-https")
        app.buttons["Cancel"].firstMatch.tap()
    }

    func test_aLinkWithTheWrongKeyIsRefused() throws {
        app.open(try link("BAD_FP_LINK"))
        let refused = app.staticTexts["This link's fingerprint does not match their journal. Do not accept it; ask them for a new link."]
        XCTAssertTrue(refused.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["people.add.accept"].exists, "nothing to accept")
        shot("people-add-fingerprint-mismatch")
    }

    func test_anUnreachableJournalIsSaid() throws {
        let url = try link("UNREACHABLE_LINK")
        app.open(url)
        XCTAssertTrue(app.staticTexts["Their journal could not be reached. Try again later."].waitForExistence(timeout: 40))
        shot("people-add-unreachable")
    }

    func test_ownLinkIsRefused() throws {
        app.open(try link("OWN_LINK"))
        XCTAssertTrue(app.staticTexts["This link is from your own journal. Add people here by name instead."].waitForExistence(timeout: 15))
        shot("people-add-own-journal")
    }

    func test_approvingAnAgentsAskShowsTheLinkOnce() throws {
        app.open(try link("ASK_ITEM_URL"))
        let approve = app.buttons["Approve"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 15))
        shot("people-ask-item")
        approve.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", Self.lifetimeNote)).firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Shown only on this device, this once."].exists)
        shot("people-ask-approved-link")
    }
}
