import XCTest
@testable import MatronMac

/// PR4 review I1 (host half), M1 and M2: the shell-held project page view
/// model, and the order of the page's bodies.
@MainActor
final class MacProjectPageSlotTests: XCTestCase {
    final class FakeModel: MacProjectPageModel {
        var projectID: String
        var starts = 0
        var stops = 0
        init(_ projectID: String) { self.projectID = projectID }
        func start() { starts += 1 }
        func stop() { stops += 1 }
    }

    private final class Owner {}
    private let ownerA = Owner()
    private let ownerB = Owner()
    private var a: ObjectIdentifier { ObjectIdentifier(ownerA) }
    private var b: ObjectIdentifier { ObjectIdentifier(ownerB) }

    // MARK: - M1: Back reuses the view model

    func testBackFromAMissionPageReusesAndRestartsTheStoppedViewModel() {
        var slot = MacProjectPageSlot<FakeModel>()
        var builds = 0
        let build = { () -> FakeModel in builds += 1; return FakeModel("pj_1") }

        slot.show(projectID: "pj_1", owner: a, build: build)
        slot.pageDidDisappear(owner: a) // a mission page replaces it
        slot.show(projectID: "pj_1", owner: a, build: build) // Back

        XCTAssertEqual(builds, 1, "Back must reuse the view model, so its detail-pass throttle applies")
        XCTAssertEqual(slot.model?.starts, 2, "a reused, stopped view model is started again")
        XCTAssertEqual(slot.model?.stops, 1)
    }

    func testARunningViewModelIsNotRestarted() {
        var slot = MacProjectPageSlot<FakeModel>()
        let model = FakeModel("pj_a")
        slot.show(projectID: "pj_a", owner: a) { model }
        model.projectID = "pj_c" // the cached row says A merged into C
        slot.show(projectID: "pj_c", owner: a) { XCTFail("a redirected view model is reused"); return FakeModel("x") }
        XCTAssertEqual(model.starts, 1, "restarting would cancel the redirect's own refresh")
    }

    func testAnotherProjectBuildsAFreshViewModelAndStopsTheOld() {
        var slot = MacProjectPageSlot<FakeModel>()
        let first = FakeModel("pj_1")
        slot.show(projectID: "pj_1", owner: a) { first }
        let second = FakeModel("pj_2")
        slot.show(projectID: "pj_2", owner: a) { second }
        XCTAssertTrue(slot.model === second)
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(second.starts, 1)
    }

    /// The `.id(ObjectIdentifier(vm))` rule: a new session's dashboard view
    /// model is a new page, and must never reuse the old session's model.
    func testANewOwnerBuildsAFreshViewModel() {
        var slot = MacProjectPageSlot<FakeModel>()
        let old = FakeModel("pj_1")
        slot.show(projectID: "pj_1", owner: a) { old }
        XCTAssertNil(slot.current(projectID: "pj_1", owner: b))
        let new = FakeModel("pj_1")
        slot.show(projectID: "pj_1", owner: b) { new }
        XCTAssertTrue(slot.model === new)
        XCTAssertEqual(old.stops, 1)
    }

    /// An account switch can mount the new page before the old page's
    /// `onDisappear` runs; that late disappear must not stop the new model.
    func testTheOldOwnersLateDisappearLeavesTheNewModelRunning() {
        var slot = MacProjectPageSlot<FakeModel>()
        slot.show(projectID: "pj_1", owner: a) { FakeModel("pj_1") }
        let new = FakeModel("pj_1")
        slot.show(projectID: "pj_1", owner: b) { new }
        slot.pageDidDisappear(owner: a)
        XCTAssertEqual(new.stops, 0)
        XCTAssertTrue(slot.isRunning)
    }

    func testResetStopsAndDropsTheModel() {
        var slot = MacProjectPageSlot<FakeModel>()
        let model = FakeModel("pj_1")
        slot.show(projectID: "pj_1", owner: a) { model }
        slot.reset()
        XCTAssertNil(slot.model)
        XCTAssertNil(slot.builtFor)
        XCTAssertEqual(model.stops, 1)
    }

    func testCurrentIsNilForAnotherProject() {
        var slot = MacProjectPageSlot<FakeModel>()
        let model = FakeModel("pj_1")
        slot.show(projectID: "pj_1", owner: a) { model }
        XCTAssertTrue(slot.current(projectID: "pj_1", owner: a) === model)
        XCTAssertNil(slot.current(projectID: "pj_2", owner: a),
                     "Back/Forward changes the page's id a frame before .task swaps the model")
    }

    // MARK: - M2: the redirect guard

    /// A redirect that lands before the page first renders the model's own
    /// id (`onChange` sees nil → C) is still the page's redirect.
    func testARedirectBeforeTheFirstRenderIsKept() {
        var slot = MacProjectPageSlot<FakeModel>()
        slot.show(projectID: "pj_a", owner: a) { FakeModel("pj_a") }
        XCTAssertEqual(slot.redirect(to: "pj_c", pageProjectID: "pj_a"), "pj_c")
    }

    /// A view model built for A, whose redirect lands after the user moved
    /// to B, must not clobber B.
    func testAStaleViewModelsRedirectIsDropped() {
        var slot = MacProjectPageSlot<FakeModel>()
        slot.show(projectID: "pj_a", owner: a) { FakeModel("pj_a") }
        XCTAssertNil(slot.redirect(to: "pj_c", pageProjectID: "pj_b"))
    }

    func testFollowingTheRedirectAcceptsTheModelForItsNewProject() {
        var slot = MacProjectPageSlot<FakeModel>()
        let model = FakeModel("pj_a")
        slot.show(projectID: "pj_a", owner: a) { model }
        model.projectID = "pj_c"
        slot.show(projectID: "pj_c", owner: a) { FakeModel("x") }
        XCTAssertEqual(slot.builtFor, "pj_c")
        XCTAssertNil(slot.redirect(to: "pj_c", pageProjectID: "pj_c"), "no redirect to the page it is on")
        model.projectID = "pj_d" // C later merges into D
        XCTAssertEqual(slot.redirect(to: "pj_d", pageProjectID: "pj_c"), "pj_d")
    }

    func testNoRedirectWithoutAnID() {
        var slot = MacProjectPageSlot<FakeModel>()
        slot.show(projectID: "pj_a", owner: a) { FakeModel("pj_a") }
        XCTAssertNil(slot.redirect(to: nil, pageProjectID: "pj_a"))
    }

    // MARK: - I1: the page's bodies, in order

    func testContentStateOrder() {
        typealias P = MacProjectPage
        XCTAssertEqual(P.contentState(hasPage: true, isMissing: true, loadFailed: true), .page)
        XCTAssertEqual(P.contentState(hasPage: false, isMissing: true, loadFailed: true), .missing)
        XCTAssertEqual(P.contentState(hasPage: false, isMissing: false, loadFailed: true), .loadFailed,
                       "a failed cold load offers Try again, not an endless spinner")
        XCTAssertEqual(P.contentState(hasPage: false, isMissing: false, loadFailed: false), .loading)
    }
}
