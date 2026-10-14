import XCTest
import MatronModels

final class RoutineModelTests: XCTestCase {
    func testScheduleWords() {
        let cases: [(String, String?)] = [
            ("5 7 * * *", "Every day at 07:05"),
            ("0 8,17 * * *", "Every day at 08:00 and 17:00"),
            ("0 */2 * * *", "Every 2 hours, on the hour"),
            ("15 */3 * * *", "Every 3 hours, at 15 past"),
            ("30 18 * * 1-5", "Monday to Friday at 18:30"),
            ("0 9 * * 1", "Every Monday at 09:00"),
            ("0 9 * * 1,3", "Every Monday and Wednesday at 09:00"),
            ("0 10 1 * *", "On day 1 of the month at 10:00"),
            ("0 10 1 1,7 *", "On day 1 of the month in January and July at 10:00"),
            ("*/30 * * * *", "Every 30 minutes"),
            ("0 * * * *", "Every hour, on the hour"),
            ("0 9 1 * 1", nil),
            ("0 9 * *", nil),
            ("0 9 L * *", nil),
        ]
        for (cron, words) in cases {
            XCTAssertEqual(CronWords.describe(cron), words, cron)
        }
    }

    func testTriggerWords() {
        XCTAssertEqual(RoutineTrigger.contextOver(pct: 40).words, "When a session passes 40% of its context window")
        XCTAssertEqual(RoutineTrigger.stalled(resetMinutes: 120).words,
                       "When a session stalls on a usage limit with no reset within 2 h")
        XCTAssertEqual(RoutineTrigger.stalled(resetMinutes: 90).words,
                       "When a session stalls on a usage limit with no reset within 1 h 30 min")
        XCTAssertEqual(RoutineTrigger.stalled(resetMinutes: 0).words, "When a session stalls on a usage limit")
        XCTAssertEqual(RoutineTrigger.diskUnder(pct: 20).words, "When a box drops under 20% free disk")
    }

    func testWhenWordsAddTheZoneToASchedule() {
        let routine = Routine(id: "rt_1", name: "a", title: "A", schedule: "30 18 * * 1-5", tz: "America/New_York",
                              prompt: "p", createdAt: Date(), updatedAt: Date())
        XCTAssertEqual(routine.whenWords, "Monday to Friday at 18:30 (America/New_York)")
        let odd = Routine(id: "rt_2", name: "b", title: "B", schedule: "0 9 1 * 1", prompt: "p",
                          createdAt: Date(), updatedAt: Date())
        XCTAssertEqual(odd.whenWords, "Cron 0 9 1 * 1 (Europe/London)")
    }

    func testOutcomeWords() {
        func routine(_ outcome: String?) -> Routine {
            Routine(id: "rt", name: "a", title: "A", schedule: "0 9 * * *", prompt: "p", lastOutcome: outcome,
                    createdAt: Date(), updatedAt: Date())
        }
        XCTAssertEqual(routine("applied now").lastOutcomeWords, "Delivered")
        XCTAssertEqual(routine("failed agent_unreachable").lastOutcomeWords, "Failed: agent_unreachable")
        XCTAssertTrue(routine("failed timeout").lastFireFailed)
        XCTAssertTrue(routine("missed").lastFireFailed)
        XCTAssertFalse(routine("applied deferred").lastFireFailed)
        XCTAssertNil(routine(nil).lastOutcomeWords)
    }

    func testFormRules() {
        func error(name: String = "weekly-review", title: String = "Weekly", prompt: String = "Do it.",
                   tz: String = "Europe/London", schedule: String? = "0 9 * * 1",
                   trigger: RoutineTrigger? = nil) -> String? {
            RoutineRules.formError(name: name, title: title, prompt: prompt, tz: tz, schedule: schedule, trigger: trigger)
        }
        XCTAssertNil(error())
        XCTAssertNotNil(error(name: "Weekly"))
        XCTAssertNotNil(error(name: "-weekly"))
        XCTAssertNotNil(error(title: "  "))
        XCTAssertNotNil(error(title: "two\nlines"))
        XCTAssertNotNil(error(prompt: ""))
        XCTAssertNotNil(error(prompt: String(repeating: "x", count: 2001)))
        XCTAssertNotNil(error(tz: "Mars/Olympus"))
        XCTAssertNotNil(error(schedule: "0 9 * *"))
        XCTAssertNotNil(error(schedule: "*/5 * * * *"))
        XCTAssertNotNil(error(schedule: "* 9 * * *"))
        XCTAssertNil(error(schedule: "*/15 * * * *"))
        XCTAssertNil(error(tz: "Mars/Olympus", schedule: nil, trigger: .diskUnder(pct: 20)),
                     "a triggered routine has no clock to check the zone against")
        XCTAssertNotNil(error(schedule: nil, trigger: .contextOver(pct: 100)))
        XCTAssertNotNil(error(schedule: nil, trigger: .stalled(resetMinutes: 20_000)))
        XCTAssertNil(error(schedule: nil, trigger: .stalled(resetMinutes: 0)))
    }
}
