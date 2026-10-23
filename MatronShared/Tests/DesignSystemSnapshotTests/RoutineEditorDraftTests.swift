import XCTest
import MatronModels
@testable import MatronDesignSystem

/// The editor changes an allowance_expiring routine's percent only: the
/// journal's reset window has to go back exactly as it came.
final class RoutineEditorDraftTests: XCTestCase {
    private func routine(_ trigger: RoutineTrigger) -> Routine {
        Routine(id: "rt_6", name: "spare-allowance", title: "Spare weekly allowance", trigger: trigger,
                prompt: "Routine spare-allowance: follow the playbook.",
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    func testEditingThePercentKeepsTheWindow() {
        var draft = RoutineEditorView.Draft(routine: routine(.allowanceExpiring(pct: 70, fromHours: 5, toHours: 9)))
        XCTAssertEqual(draft.triggerKind, .allowanceExpiring)
        XCTAssertEqual(draft.threshold, 70)
        draft.threshold = 60
        let sent = draft.routineDraft(isNew: false)
        XCTAssertEqual(sent.trigger, .allowanceExpiring(pct: 60, fromHours: 5, toHours: 9))
        let body = sent.requestBody["trigger"] as? [String: Any]
        XCTAssertEqual(body?["pct"] as? Int, 60)
        XCTAssertEqual(body?["from_hours"] as? Double, 5)
        XCTAssertEqual(body?["to_hours"] as? Double, 9)
    }

    func testANewSpareAllowanceRoutineSendsNoWindow() {
        var draft = RoutineEditorView.Draft()
        draft.mode = .trigger
        draft.triggerKind = .allowanceExpiring
        draft.threshold = RoutineTrigger.Kind.allowanceExpiring.defaultTrigger.threshold
        XCTAssertEqual(draft.trigger, .allowanceExpiring(pct: 70, fromHours: nil, toHours: nil))
        XCTAssertEqual(draft.trigger.words, "When a weekly limit resets within 6–12 h and is under 70%")
        XCTAssertEqual(RoutineEditorView.thresholdLabel(draft.trigger), "Weekly limit under 70%")
    }
}
