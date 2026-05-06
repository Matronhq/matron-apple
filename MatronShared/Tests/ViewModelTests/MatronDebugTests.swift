import XCTest
import os
@testable import MatronModels

final class MatronDebugTests: XCTestCase {

    /// `Logger.diag(...)` MUST NOT evaluate the autoclosure when the
    /// gate is off. Counter-side-effect probe via the autoclosure
    /// confirms the deferred-evaluation contract — without it, the
    /// "diagnostic logs are free in shipped builds" promise is broken.
    /// The `MatronDebug.$override` TaskLocal is the test seam; we
    /// don't touch the process-wide `enabled` setter so concurrent
    /// tests can't see each other's mutations.
    func test_diag_doesNotEvaluateAutoclosure_whenDisabled() {
        let logger = Logger(subsystem: "test.diag", category: "matrondebug")
        var evaluations = 0
        MatronDebug.$override.withValue(false) {
            logger.diag(self.touchAndReturn(&evaluations))
        }
        XCTAssertEqual(evaluations, 0,
                       "autoclosure must not run when MatronDebug.enabled is false — otherwise diagnostic logs cost as much as a regular notice in production")
    }

    /// Symmetry: when the gate is on, the autoclosure DOES run (and
    /// the message reaches `Logger.notice`). We can't observe the
    /// `Logger` output from a unit test cleanly, but we can at least
    /// confirm the side-effect probe fires once.
    func test_diag_evaluatesAutoclosureExactlyOnce_whenEnabled() {
        let logger = Logger(subsystem: "test.diag", category: "matrondebug")
        var evaluations = 0
        MatronDebug.$override.withValue(true) {
            logger.diag(self.touchAndReturn(&evaluations))
        }
        XCTAssertEqual(evaluations, 1,
                       "autoclosure must evaluate exactly once when enabled — additional evaluations would mean the message gets built twice (rendering + interpolation)")
    }

    /// `MatronDebug.$override` is a `@TaskLocal`, so two concurrent
    /// `withValue` scopes never see each other's value. Asserting
    /// this via `withTaskGroup` to make sure a future refactor
    /// doesn't accidentally collapse it to a global var, which would
    /// cause flaky test interactions when the test suite runs in
    /// parallel.
    func test_override_isolatedPerTaskLocalScope() async {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                MatronDebug.$override.withValue(true) {
                    MatronDebug.enabled
                }
            }
            group.addTask {
                MatronDebug.$override.withValue(false) {
                    MatronDebug.enabled
                }
            }
            var seen: [Bool] = []
            for await v in group { seen.append(v) }
            XCTAssertTrue(seen.contains(true))
            XCTAssertTrue(seen.contains(false))
        }
    }

    /// Helper that side-effects + returns a string. Used as the
    /// autoclosure body in the deferred-evaluation tests.
    private func touchAndReturn(_ counter: inout Int) -> String {
        counter += 1
        return "evaluated"
    }
}
