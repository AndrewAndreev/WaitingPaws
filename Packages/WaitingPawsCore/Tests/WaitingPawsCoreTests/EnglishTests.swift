import XCTest
@testable import WaitingPawsCore

/// The app in English (every device language other than Russian): schedules, durations, the trainer's log.
final class EnglishTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CoreLanguage.current = .en
    }

    override func tearDown() {
        CoreLanguage.current = .ru
        super.tearDown()
    }

    private let sample = """
    🐶 Monday training - Anna/Andrew - 25.10.2026
    ➡️ All breaks 2 minutes
    Exit 1 - 5 seconds
    Exit 2 - 10 seconds
    Break 5 minutes
    3rd exit - 30 seconds OR until the dog stands up
    Exit 4 - 0 seconds (step out and come right back)
    Stay calm at the door.
    """

    func testEnglishSchedule() {
        let plan = PlanParser.parse(sample)
        XCTAssertEqual(plan.title, "Monday training")
        XCTAssertEqual(plan.trainers, "Anna/Andrew")
        XCTAssertNotNil(plan.date)
        XCTAssertEqual(plan.defaultBreak, 120)
        XCTAssertEqual(plan.exits.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(plan.exits.map(\.duration), [5, 10, 30, 0])
        XCTAssertEqual(plan.exits[1].breakAfter, 300)
        XCTAssertTrue(plan.exits[2].untilStanding)
        XCTAssertFalse(plan.exits[0].untilStanding)
        XCTAssertEqual(plan.exits[3].note, "step out and come right back")
        XCTAssertEqual(plan.notes, ["All breaks 2 minutes", "Stay calm at the door."])
    }

    func testDottedDatesAreDayFirstInEnglishToo() {
        let plan = PlanParser.parse("Sunday training - Anna - 04.10.2026\nExit 1 - 5 seconds")
        let parts = Calendar(identifier: .gregorian).dateComponents([.day, .month], from: plan.date!)
        XCTAssertEqual(parts.day, 4)
        XCTAssertEqual(parts.month, 10)
    }

    func testRussianScheduleStillParsesInEnglishUI() {
        let plan = PlanParser.parse("Тренировка\nВсе перерывы 3 минуты\n1 выход - 5 секунд\n2 выход - 1 минута ИЛИ до вставания")
        XCTAssertEqual(plan.exits.map(\.duration), [5, 60])
        XCTAssertTrue(plan.exits[1].untilStanding)
        XCTAssertEqual(plan.defaultBreak, 180)
    }

    func testWordsContainingOrDoNotCutTheDuration() {
        let exit = PlanParser.parseExit("Exit 1 - 30 seconds (door closed)")
        XCTAssertEqual(exit?.duration, 30)
        XCTAssertEqual(exit?.note, "door closed")
    }

    func testDurations() {
        XCTAssertEqual(DurationText.short(90), "1 min 30 s")
        XCTAssertEqual(DurationText.short(3_660), "1 h 1 min")
        XCTAssertEqual(DurationText.compact(90), "1m30")
        XCTAssertEqual(DurationText.parse("2 minutes"), 120)
        XCTAssertEqual(DurationText.parse("1 min 30 sec"), 90)
        XCTAssertEqual(TrainingPlan().title, "Training")
    }

    func testTrainerLogInEnglish() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let plan = TrainingPlan(exits: [
            PlannedExit(number: 1, duration: 5),
            PlannedExit(number: 2, duration: 30, untilStanding: true)
        ])
        let session = TrainingSession(plan: plan, clock: { now })
        session.startExit(); session.markBehindDoor(); now += 2; session.resetExit()
        now += 60; session.startExit(); session.markBehindDoor(); now += 5; session.endExit()
        now += 120; session.tick()
        session.startExit(); session.markBehindDoor(); now += 30; session.endExit(); session.finish()
        let text = SessionLogFormatter.text(for: session.makeRecord(recordingFileName: nil))
        let lines = text.components(separatedBy: "\n").filter { $0.hasPrefix("Exit ") }
        XCTAssertEqual(lines, [
            "Exit 1 — 5 s: false start, outside 0:02 ❌ · break 1:00 (plan 2 min)",
            "Exit 1 — 5 s, attempt 2: outside 0:05 ✅ · break 2:00",
            "Exit 2 — 30 s or until the dog stands: outside 0:30 ✅",
        ])
        XCTAssertTrue(text.contains("exits 2 of 2 · false starts 1"))
    }
}
