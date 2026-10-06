import XCTest
@testable import WaitingPawsCore

final class TrainingSessionTests: XCTestCase {
    /// These tests check the Russian texts (the default language of the app's first users).
    override func setUp() {
        super.setUp()
        CoreLanguage.current = .ru
    }

    private var now = Date(timeIntervalSince1970: 1_000_000)

    private func makeSession() -> TrainingSession {
        let plan = TrainingPlan(exits: [
            PlannedExit(number: 1, duration: 5),
            PlannedExit(number: 2, duration: 30, untilStanding: true, breakAfter: 300)
        ])
        return TrainingSession(plan: plan, clock: { self.now })
    }

    private func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

    func testHappyPath() {
        let session = makeSession()
        XCTAssertEqual(session.phase, .ready(exitIndex: 0))
        XCTAssertTrue(session.phase.canGoOutside)

        // "Вышли" goes straight outside: no walk to the door in between.
        session.markBehindDoor()
        XCTAssertEqual(session.phase, .away(exitIndex: 0, since: now, leftAt: now))
        XCTAssertEqual(session.events.last?.kind, .behindDoor)
        XCTAssertEqual(session.events.last?.detail, "план 5 с")
        advance(2)
        XCTAssertEqual(session.remaining(at: now), 3)
        advance(5)
        XCTAssertEqual(session.remaining(at: now), -2)
        session.endExit()

        XCTAssertEqual(session.results.count, 1)
        XCTAssertEqual(session.results[0].awayDuration, 7)
        XCTAssertEqual(session.results[0].totalDuration, 7)
        XCTAssertFalse(session.results[0].falseStart)
        guard case .breakTime(let after, _, let duration, let next) = session.phase else { return XCTFail("expected break") }
        XCTAssertEqual(after, 0)
        XCTAssertEqual(duration, 120)
        XCTAssertEqual(next, 1)

        // The break runs past its plan until "Вышли": the time left goes negative.
        advance(131)
        session.tick(at: now)
        guard case .breakTime = session.phase else { return XCTFail("the break should go on") }
        XCTAssertEqual(session.remaining(at: now), -11)

        session.markBehindDoor()
        XCTAssertEqual(session.results[0].actualBreak, 131)
        XCTAssertEqual(session.events.first { $0.kind == .breakEnded }?.detail, "дольше плана, 2:11 из 2 мин")
        XCTAssertEqual(session.phase, .away(exitIndex: 1, since: now, leftAt: now))
        advance(20)
        session.endExit()

        guard case .breakTime(_, _, let lastBreak, let lastNext) = session.phase else { return XCTFail("expected last break") }
        XCTAssertEqual(lastBreak, 300)
        XCTAssertNil(lastNext)
        XCTAssertFalse(session.phase.canGoOutside)
        XCTAssertFalse(session.phase.canFalseStart)

        advance(300)
        session.tick(at: now)
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.completedExitsCount, 2)
        XCTAssertEqual(session.events.last?.kind, .sessionFinished)
    }

    func testEarlyBreakEnd() {
        let session = makeSession()
        session.markBehindDoor(); advance(5); session.endExit()
        advance(90)
        session.markBehindDoor()
        XCTAssertEqual(session.events.first { $0.kind == .breakEnded }?.detail, "досрочно, 1:30 из 2 мин")
        XCTAssertEqual(session.results[0].actualBreak, 90)
    }

    /// "Фальстарт" in a break: the dog went to the door (or there were sounds on the way out) before "Вышли".
    func testFalseStartInBreakStartsTheBreakOver() {
        let session = makeSession()
        session.markBehindDoor(); advance(5); session.endExit()
        advance(100)
        XCTAssertTrue(session.phase.canFalseStart)
        session.resetExit()

        XCTAssertEqual(session.results.count, 2)
        XCTAssertEqual(session.results[0].actualBreak, 100)
        let failed = session.results[1]
        XCTAssertEqual(failed.number, 2)
        XCTAssertTrue(failed.falseStart)
        XCTAssertNil(failed.leftAt)
        XCTAssertEqual(failed.startedAt, now)
        XCTAssertEqual(session.attempt, 2)
        XCTAssertEqual(session.events.first { $0.kind == .falseStart }?.detail, "до двери")
        // A new break (the one after exit 2), then exit 2 again.
        XCTAssertEqual(session.phase, .breakTime(afterExitIndex: 1, since: now, duration: 300, nextExitIndex: 1))

        advance(300)
        session.markBehindDoor(); advance(30); session.endExit(); session.finish()
        let lines = SessionLogFormatter.text(for: session.makeRecord(recordingFileName: nil))
            .components(separatedBy: "\n").filter { $0.contains(" выход — ") }
        XCTAssertEqual(lines, [
            "1 выход — 5 с: за дверью 0:05 ✅ · перерыв 1:40 (план 2 мин)",
            "2 выход — 30 с или до вставания: фальстарт до двери ❌ · перерыв 5:00",
            "2 выход — 30 с или до вставания, попытка 2: за дверью 0:30 ✅",
        ])
    }

    func testFalseStartBeforeTheFirstExit() {
        let session = makeSession()
        advance(20)
        session.resetExit()
        XCTAssertEqual(session.results.count, 1)
        XCTAssertTrue(session.results[0].falseStart)
        XCTAssertEqual(session.attempt, 2)
        XCTAssertEqual(session.phase, .breakTime(afterExitIndex: 0, since: now, duration: 120, nextExitIndex: 0))
    }

    /// An older linked iPhone still sends "Начать выход" and then "За дверью".
    func testLegacyWalkToTheDoor() {
        let session = makeSession()
        session.startExit()
        XCTAssertEqual(session.phase, .leaving(exitIndex: 0, since: now))
        advance(3)
        session.markBehindDoor()
        advance(5)
        session.endExit()
        XCTAssertEqual(session.results[0].awayDuration, 5)
        XCTAssertEqual(session.results[0].totalDuration, 8)
    }

    /// The common break was read wrong and is noticed in the first break: every break gets longer, this one too.
    func testEditingTheScheduleDuringABreak() {
        let session = makeSession()
        session.markBehindDoor(); advance(5); session.endExit()
        advance(60)
        var edited = session.plan
        edited.defaultBreak = 180
        edited.exits[1].duration = 45
        XCTAssertTrue(session.updatePlan(edited))
        XCTAssertEqual(session.phase, .breakTime(afterExitIndex: 0, since: now.addingTimeInterval(-60), duration: 180, nextExitIndex: 1))
        XCTAssertEqual(session.remaining(at: now), 120)
        XCTAssertEqual(session.results[0].plannedBreak, 180)
        XCTAssertEqual(session.events.last?.kind, .note)
        XCTAssertEqual(session.events.last?.detail, "Расписание изменено: перерывы 2 мин → 3 мин; выход 2: 30 с или до вставания → 45 с или до вставания")

        session.markBehindDoor()
        advance(10)
        XCTAssertEqual(session.remaining(at: now), 35)
    }

    /// A drag applies every step at once (the timer follows it) and logs the whole edit once, when it is let go.
    func testAnEditInStepsIsLoggedOnce() {
        let session = makeSession()
        session.markBehindDoor()
        advance(3)
        let before = session.plan
        let notes = session.events.filter { $0.kind == .note }.count
        for duration in [6.0, 8, 10] {
            var step = session.plan
            step.exits[0].duration = duration
            XCTAssertTrue(session.updatePlan(step, quiet: true))
            XCTAssertEqual(session.remaining(at: now), duration - 3)
        }
        XCTAssertEqual(session.events.filter { $0.kind == .note }.count, notes)
        var last = session.plan
        last.exits[0].duration = 12
        session.updatePlan(last, changesSince: before)
        XCTAssertEqual(session.events.filter { $0.kind == .note }.count, notes + 1)
        XCTAssertEqual(session.events.last?.detail, "Расписание изменено: выход 1: 5 с → 12 с")
    }

    func testEditingKeepsTheExitsAlreadyDone() {
        let session = makeSession()
        session.markBehindDoor(); advance(5); session.endExit()
        advance(120); session.markBehindDoor()
        XCTAssertEqual(session.fixedExitCount, 2)

        var dropped = session.plan
        dropped.exits.removeFirst()
        XCTAssertFalse(session.updatePlan(dropped), "exit 1 is done")
        var reordered = session.plan
        reordered.exits.swapAt(0, 1)
        XCTAssertFalse(session.updatePlan(reordered))
        XCTAssertEqual(session.plan.exits.count, 2)

        // One more exit after the last: the cool-down becomes a break before it.
        var longer = session.plan
        longer.exits.append(PlannedExit(number: 3, duration: 10))
        XCTAssertTrue(session.updatePlan(longer))
        advance(30); session.endExit()
        guard case .breakTime(_, _, let duration, let next) = session.phase else { return XCTFail("expected break") }
        XCTAssertEqual(duration, 300)
        XCTAssertEqual(next, 2)
        XCTAssertEqual(session.events.first { $0.kind == .note }?.detail, "Расписание изменено: добавлен выход 3 — 10 с")
    }

    func testRemovingTheNextExitDuringABreak() {
        let session = makeSession()
        session.markBehindDoor(); advance(5); session.endExit()
        var shorter = session.plan
        shorter.exits.removeLast()
        XCTAssertTrue(session.updatePlan(shorter))
        guard case .breakTime(_, _, _, let next) = session.phase else { return XCTFail("expected break") }
        XCTAssertNil(next, "no exit left: the break is the last one")
    }

    func testMirrorSendsTheEditedSchedule() {
        let owner = makeSession()
        let mirror = TrainingSession(snapshot: owner.snapshot, clock: { self.now })
        var sent: TrainingPlan?
        mirror.planHandler = { plan, _, _ in sent = plan }
        var edited = mirror.plan
        edited.defaultBreak = 90
        XCTAssertTrue(mirror.updatePlan(edited))
        XCTAssertEqual(mirror.plan.defaultBreak, 120, "the owner applies it")
        owner.updatePlan(try! XCTUnwrap(sent))
        mirror.restore(owner.snapshot)
        XCTAssertEqual(mirror.plan.defaultBreak, 90)
    }

    func testStandingRuleFromNotes() {
        var plan = TrainingPlan(exits: [PlannedExit(number: 1, duration: 30, untilStanding: true)])
        XCTAssertNil(plan.standingDelay)
        XCTAssertEqual(plan.standingRule, "собака встала — сразу возвращайтесь")
        plan.notes = ["Все перерывы 2 минуты", "🟡 Если встала - входим через 15 секунд от вставания"]
        XCTAssertEqual(plan.standingDelay, 15)
        XCTAssertEqual(plan.standingRule, "собака встала — возвращайтесь через 15 с")
        plan.notes = ["If she stands up in the first 10 seconds, come back in 20 seconds"]
        XCTAssertEqual(plan.standingDelay, 20)
        plan.notes = ["Вернуться можно минимум через 20-30 минут после окончания тренировки"]
        XCTAssertNil(plan.standingDelay)
    }

    func testFalseStartRepeatsExit() {
        let session = makeSession()
        session.markBehindDoor()
        advance(1)
        session.resetExit()

        XCTAssertEqual(session.results.count, 1)
        XCTAssertTrue(session.results[0].falseStart)
        XCTAssertEqual(session.attempt, 2)
        guard case .breakTime(_, _, _, let next) = session.phase else { return XCTFail("expected break") }
        XCTAssertEqual(next, 0)

        session.markBehindDoor() // early, before the break ends
        XCTAssertEqual(session.phase, .away(exitIndex: 0, since: now, leftAt: now))
        XCTAssertEqual(session.events.filter { $0.kind == .breakEnded }.count, 1)
        session.endExit()
        XCTAssertEqual(session.results[1].attempt, 2)
        XCTAssertEqual(session.attempt, 1)
        XCTAssertEqual(session.currentExitIndex, 1)
    }

    func testFinishWhileOutsideClosesExit() {
        let session = makeSession()
        session.markBehindDoor()
        advance(4)
        session.finish()
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.results.count, 1)
        XCTAssertEqual(session.results[0].awayDuration, 4)
        XCTAssertEqual(session.finishedAt, now)
    }

    func testLogFormatterIncludesEverything() {
        let session = makeSession()
        session.markBehindDoor(); advance(5); session.endExit(); session.finish()
        let record = session.makeRecord(recordingFileName: "video.mp4")
        let text = SessionLogFormatter.text(for: record)
        XCTAssertFalse(text.contains("video.mp4"), "the file name is no use to the trainer")
        XCTAssertTrue(text.contains("1 выход — 5 с: за дверью 0:05 ✅"))
        XCTAssertFalse(text.contains("перерыв"), "the break after the last exit only ends the session")
    }

    func testLogFormatterOneLinePerAttempt() {
        let session = makeSession()
        session.markBehindDoor(); advance(2); session.resetExit()
        advance(60); session.markBehindDoor(); advance(5); session.endExit()
        advance(120); session.tick()
        session.markBehindDoor(); advance(30); session.endExit(); session.finish()
        let lines = SessionLogFormatter.text(for: session.makeRecord(recordingFileName: nil))
            .components(separatedBy: "\n").filter { $0.contains(" выход — ") }
        XCTAssertEqual(lines, [
            "1 выход — 5 с: фальстарт, за дверью 0:02 ❌ · перерыв 1:00 (план 2 мин)",
            "1 выход — 5 с, попытка 2: за дверью 0:05 ✅ · перерыв 2:00",
            "2 выход — 30 с или до вставания: за дверью 0:30 ✅",
        ])
    }
}
