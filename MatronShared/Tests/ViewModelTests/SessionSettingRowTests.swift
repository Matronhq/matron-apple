import XCTest
import MatronModels
@testable import MatronViewModels

/// The iPhone ⓘ sheet's Model / Effort rows (decision #2972): built from
/// the bridge-published option lists on the chat's status, and a choice
/// becomes the `/model` / `/effort` command the user would have typed.
final class SessionSettingRowTests: XCTestCase {
    private let opus = SessionStatus.Option(value: "opus", label: "Opus")
    private let sonnet = SessionStatus.Option(value: "sonnet", label: "Sonnet")
    private let high = SessionStatus.Option(value: "high", label: "High")
    private let xhigh = SessionStatus.Option(value: "xhigh", label: nil)

    func testNoStatusMeansNoRows() {
        XCTAssertEqual(SessionSettingRow.rows(for: nil), [])
    }

    func testAbsentOrEmptyOptionsHideTheirRow() {
        XCTAssertEqual(SessionSettingRow.rows(for: SessionStatus(model: "opus")), [])
        XCTAssertEqual(SessionSettingRow.rows(for: SessionStatus(model: "opus", modelOptions: [], effortLevels: [])), [])
        let effortOnly = SessionSettingRow.rows(for: SessionStatus(effortLevels: [high]))
        XCTAssertEqual(effortOnly.map(\.kind), [.effort])
    }

    func testRowsCarryTheirOptionsAndCurrentValueInOrder() {
        let rows = SessionSettingRow.rows(for: SessionStatus(model: "sonnet", modelOptions: [opus, sonnet],
                                                              effortLevels: [high, xhigh], effort: "xhigh"))
        XCTAssertEqual(rows.map(\.kind), [.model, .effort])
        XCTAssertEqual(rows.map(\.title), ["Model", "Effort"])
        XCTAssertEqual(rows[0].options, [opus, sonnet])
        XCTAssertEqual(rows[0].currentValue, "sonnet")
        XCTAssertEqual(rows[0].currentLabel, "Sonnet", "a known value shows its label")
        XCTAssertEqual(rows[1].currentLabel, "xhigh", "an unlabelled option shows its value")
    }

    func testCurrentShowsTheRawValueWhenNoOptionMatches() {
        let row = SessionSettingRow.rows(for: SessionStatus(model: "claude-fable-5", modelOptions: [opus]))[0]
        XCTAssertEqual(row.currentLabel, "claude-fable-5")
        XCTAssertFalse(row.isCurrent(opus))
    }

    func testUnknownCurrentIsNil() {
        let row = SessionSettingRow.rows(for: SessionStatus(effortLevels: [high]))[0]
        XCTAssertNil(row.currentLabel)
        XCTAssertFalse(row.isCurrent(high))
    }

    func testIsCurrentMatchesValueOrLabelCaseInsensitively() {
        let row = SessionSettingRow.rows(for: SessionStatus(model: "Opus", modelOptions: [opus, sonnet]))[0]
        XCTAssertTrue(row.isCurrent(opus))
        XCTAssertFalse(row.isCurrent(sonnet))
    }

    func testDuplicateValuesCollapseToTheFirst() {
        let row = SessionSettingRow.rows(for: SessionStatus(modelOptions: [opus, SessionStatus.Option(value: "OPUS", label: "Again"), sonnet]))[0]
        XCTAssertEqual(row.options, [opus, sonnet])
    }

    func testChoosingSendsTheTypedCommand() {
        let rows = SessionSettingRow.rows(for: SessionStatus(modelOptions: [opus], effortLevels: [xhigh]))
        XCTAssertEqual(rows[0].command(for: opus), "/model opus")
        XCTAssertEqual(rows[1].command(for: xhigh), "/effort xhigh")
    }
}
