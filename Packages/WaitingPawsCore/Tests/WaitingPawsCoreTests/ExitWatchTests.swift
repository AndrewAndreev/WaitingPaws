import XCTest
@testable import WaitingPawsCore

final class ExitWatchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CoreLanguage.current = .ru
    }

    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let liesDown = EarlyEntry(event: "Легла", delay: 20, tone: .green)
    private let walksOff = EarlyEntry(event: "Встала и пошла", delay: 30, tone: .yellow)

    private func watch() -> ExitWatch { ExitWatch(exitID: UUID(), attempt: 1) }
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testNothingMarkedIsThePlan() {
        let watch = watch()
        XCTAssertTrue(watch.isEmpty)
        XCTAssertEqual(watch.verdict(at: at(5), quietNeeded: 30), .plan)
        XCTAssertNil(watch.nextChange(after: at(5), quietNeeded: 30))
    }

    func testConditionCountsDownThenAllowsComingIn() {
        var watch = watch()
        watch.mark(liesDown, at: at(10))
        XCTAssertEqual(watch.verdict(at: at(15), quietNeeded: nil), .comeBackIn(15, entry: liesDown))
        XCTAssertEqual(watch.nextChange(after: at(15), quietNeeded: nil), at(30))
        XCTAssertEqual(watch.verdict(at: at(30), quietNeeded: nil), .canComeIn(entry: liesDown))
        XCTAssertNil(watch.nextChange(after: at(31), quietNeeded: nil))
    }

    func testATapMeansSeenNowAndClearTakesEverythingBack() {
        var watch = watch()
        watch.mark(liesDown, at: at(10))
        watch.mark(walksOff, at: at(12))
        XCTAssertEqual(watch.entry, walksOff)
        XCTAssertEqual(watch.verdict(at: at(12), quietNeeded: nil), .comeBackIn(30, entry: walksOff))
        // The same chip again: seen again, the countdown starts over (not taken back).
        watch.mark(walksOff, at: at(20))
        XCTAssertEqual(watch.verdict(at: at(20), quietNeeded: nil), .comeBackIn(30, entry: walksOff))
        watch.markBarking(at: at(21))
        watch.clear()
        XCTAssertTrue(watch.isEmpty)
        XCTAssertEqual(watch.verdict(at: at(22), quietNeeded: 30), .plan)
    }

    func testRightAwayAndUnreadTimes() {
        var watch = watch()
        let standsUp = EarlyEntry.untilStanding
        watch.mark(standsUp, at: at(10))
        XCTAssertEqual(watch.verdict(at: at(10), quietNeeded: nil), .canComeIn(entry: standsUp))

        let couple = EarlyEntry(event: "Легла", delay: nil, detail: "через пару минут от укладки")
        watch.mark(couple, at: at(20))
        XCTAssertEqual(watch.verdict(at: at(65), quietNeeded: nil), .comeBackAfter("через пару минут", elapsed: 45, entry: couple))
    }

    func testBarkingHoldsEverythingQuietCountsFromWhenSheStopped() {
        var watch = watch()
        watch.mark(liesDown, at: at(0))
        watch.markBarking(at: at(10))
        XCTAssertTrue(watch.watchesQuiet)
        XCTAssertEqual(watch.verdict(at: at(25), quietNeeded: 30), .barking(needed: 30))
        XCTAssertNil(watch.nextChange(after: at(25), quietNeeded: 30))
        // She stopped at 25 s: the quiet counts from there.
        watch.markQuiet(at: at(25))
        XCTAssertEqual(watch.verdict(at: at(40), quietNeeded: 30), .waitForQuiet(quiet: 15, needed: 30))
        XCTAssertEqual(watch.nextChange(after: at(40), quietNeeded: 30), at(55))
        // Barked again: no count until she stops again.
        watch.markBarking(at: at(45))
        XCTAssertEqual(watch.verdict(at: at(60), quietNeeded: 30), .barking(needed: 30))
        watch.markQuiet(at: at(60))
        // Quiet long enough, the condition's time is up too.
        XCTAssertEqual(watch.verdict(at: at(90), quietNeeded: 30), .canComeIn(entry: liesDown))
    }

    func testQuietAloneAllowsComingIn() {
        var watch = watch()
        watch.markQuiet(at: at(0))
        XCTAssertEqual(watch.verdict(at: at(29), quietNeeded: 30), .waitForQuiet(quiet: 29, needed: 30))
        XCTAssertEqual(watch.verdict(at: at(30), quietNeeded: 30), .canComeIn(entry: nil))
        // No time in the rule: the quiet just counts up.
        XCTAssertEqual(watch.verdict(at: at(90), quietNeeded: nil), .waitForQuiet(quiet: 90, needed: nil))
        watch.clear()
        XCTAssertEqual(watch.verdict(at: at(90), quietNeeded: nil), .plan)
    }

    func testQuietTimeFromTheRule() {
        let plan = PlanParser.parse("""
        1 выход - 15 секунд
        🚩 Если залаяла, завыла - ждём, входим когда молчала 30 секунд
        """)
        XCTAssertEqual(plan.doNotEnterRule?.quietTime, 30)

        let english = PlanParser.parse("""
        Exit 1 - 15 seconds
        🚩 If she barks or howls - wait, come in once she has been quiet for 1 minute
        """)
        XCTAssertEqual(english.doNotEnterRule?.quietTime, 60)

        let noTime = PlanParser.parse("""
        1 выход - 15 секунд
        🚩 Если залаяла, завыла - ни в коем случае не входить, ждём когда станет чуть спокойнее
        """)
        XCTAssertNotNil(noTime.doNotEnterRule)
        XCTAssertNil(noTime.doNotEnterRule?.quietTime)
    }
}
