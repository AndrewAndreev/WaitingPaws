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

        // The last break runs over too: only «Завершить» ends the training (and its recording).
        advance(400)
        session.tick(at: now)
        XCTAssertFalse(session.isFinished)
        XCTAssertEqual(session.remaining(at: now), -100)
        session.finish()
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

    /// «Ещё выход» after the schedule's last exit: an exit without a planned time, counting up, in the log as such.
    func testOpenExitAfterTheLastOne() {
        let session = makeSession()
        session.markBehindDoor(); advance(5); session.endExit()
        advance(120); session.markBehindDoor(); advance(30); session.endExit()
        guard case .breakTime(_, _, _, nil) = session.phase else { return XCTFail("expected the last break") }

        advance(60)
        session.startOpenExit()
        XCTAssertEqual(session.plan.exits.count, 3)
        XCTAssertTrue(session.plan.exits[2].isOpen)
        guard case .away(let index, _, _) = session.phase else { return XCTFail("expected outside") }
        XCTAssertEqual(index, 2)
        advance(42)
        XCTAssertNil(session.remaining(at: now))
        XCTAssertEqual(session.elapsed(at: now), 42)
        session.endExit()
        guard case .breakTime(_, _, _, nil) = session.phase else { return XCTFail("expected a last break again") }
        session.finish()

        let log = SessionLogFormatter.text(for: session.makeRecord(recordingFileName: nil))
        XCTAssertTrue(log.contains("3 выход — без времени: за дверью 0:42 ✅"), log)
        let again = try! JSONDecoder().decode(TrainingPlan.self, from: JSONEncoder().encode(session.plan))
        XCTAssertTrue(again.exits[2].isOpen)
    }

    func testFalseStartWindowFromTheRule() {
        var plan = TrainingPlan(exits: [PlannedExit(number: 1, duration: 300)])
        XCTAssertNil(plan.falseStartWindow)
        plan.notes = ["Фальстарт: если пошла к двери в первые 20 секунд длинного выхода - сразу возвращаемся"]
        XCTAssertEqual(plan.falseStartWindow, 20)
        plan.notes = ["Фальстарт: если в течение первых 1,5 минут пошла к двери — возвращаемся"]
        XCTAssertEqual(plan.falseStartWindow, 90)
        plan.notes = ["False start: if she goes to the door in the first 30 seconds, come back"]
        XCTAssertEqual(plan.falseStartWindow, 30)
        plan.notes = ["Фальстарт: если пошла к двери — сразу возвращаемся"]
        XCTAssertNil(plan.falseStartWindow)
    }

    func testEarlyEntriesOfExits() {
        var plan = TrainingPlan(exits: [PlannedExit(number: 1, duration: 30, untilStanding: true),
                                        PlannedExit(number: 2, duration: 120)])
        // «ИЛИ до вставания» alone: come back as soon as she stands.
        XCTAssertEqual(plan.earlyEntries(of: plan.exits[0]).map(\.summary), ["встала → сразу"])
        XCTAssertEqual(plan.earlyEntries(of: plan.exits[1]), [])

        plan.commonEarlyEntries = [EarlyEntry(event: "Встала и пошла", delay: 15, tone: .yellow),
                                   EarlyEntry(event: "Легла", delay: 30, tone: .green)]
        XCTAssertEqual(plan.commonEntriesScope, .all)
        // A condition about standing up takes the place of «до вставания».
        XCTAssertEqual(plan.earlyEntries(of: plan.exits[0]).map(\.summary), ["встала и пошла → 0:15", "легла → 0:30"])
        XCTAssertTrue(plan.usesCommonEarlyEntries(plan.exits[1]))

        plan.applyCommonEarlyEntries(to: .long)
        XCTAssertEqual(plan.commonEntriesScope, .long)
        XCTAssertEqual(plan.earlyEntries(of: plan.exits[0]).map(\.summary), ["встала → сразу"])
        XCTAssertEqual(plan.earlyEntries(of: plan.exits[1]).count, 2)

        // Changed for one exit: its own copy, the common ones stay.
        plan.detachEarlyEntries(ofExitAt: 1)
        plan.exits[1].earlyEntries[1].delay = 40
        XCTAssertFalse(plan.usesCommonEarlyEntries(plan.exits[1]))
        XCTAssertEqual(plan.earlyEntries(of: plan.exits[1]).map(\.summary), ["встала и пошла → 0:15", "легла → 0:40"])
        XCTAssertEqual(plan.commonEarlyEntries[1].delay, 30)
        XCTAssertEqual(plan.changes(from: plan).count, 0)

        var edited = plan
        edited.exits[1].triggers = ["куртка"]
        edited.exits[1].note = "Ключами звякнуть за дверью"
        edited.exits[1].earlyEntries.removeLast()
        XCTAssertEqual(edited.changes(from: plan), ["выход 2: триггеры", "выход 2: ранний вход", "выход 2: заметка"])
    }

    func testExitsThatCanEndEarly() {
        // The schedule of 03.11: common conditions after the exits apply to all of them.
        var plan = TrainingPlan(exits: [PlannedExit(number: 1, duration: 5),
                                        PlannedExit(number: 5, duration: 120, untilStanding: true),
                                        PlannedExit(number: 7, duration: 480)])
        XCTAssertEqual(plan.exits.map(plan.canEndEarly), [false, true, false])
        plan.commonEarlyEntries = [EarlyEntry(event: "Встала и пошла", delay: 240, tone: .yellow),
                                   EarlyEntry(event: "Легла", delay: 120, tone: .green)]
        // 4:00 and 2:00 never come within 5 s; 2:00 isn't sooner than a 2-minute plan, but «до вставания» is.
        XCTAssertEqual(plan.exits.map(plan.canEndEarly), [false, true, true])

        // «Сразу» and a time the parser couldn't read («через пару минут») may come at any moment.
        plan.exits[0].earlyEntries = [EarlyEntry(event: "Встала")]
        XCTAssertTrue(plan.canEndEarly(plan.exits[0]))
        plan.exits[0].earlyEntries = [EarlyEntry(event: "Легла", detail: "через пару минут")]
        XCTAssertTrue(plan.canEndEarly(plan.exits[0]))

        // An extra exit has no plan to come before.
        var open = PlannedExit(number: 8, duration: 0)
        open.isOpen = true
        XCTAssertTrue(plan.canEndEarly(open))
        open.usesCommonEarlyEntries = false
        XCTAssertFalse(plan.canEndEarly(open))
    }

    func testPlanFromAnOlderBuild() throws {
        // A plan saved before conditions: «🟡 Если встала…» among the notes, no triggers or conditions in the exits.
        let json = """
        {"id":"\(UUID().uuidString)","title":"Тренировка","trainers":"","notes":["Все перерывы 2 минуты",
        "Если встала - входим через 15 секунд от вставания"],"defaultBreak":120,"rawText":"",
        "exits":[{"id":"\(UUID().uuidString)","number":1,"duration":30,"untilStanding":true}]}
        """
        let plan = try JSONDecoder().decode(TrainingPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.notes, ["Все перерывы 2 минуты"])
        XCTAssertEqual(plan.commonEarlyEntries.map(\.summary), ["встала → 0:15"])
        XCTAssertEqual(plan.earlyEntries(of: plan.exits[0]).map(\.detail), ["от вставания"])
        XCTAssertEqual(plan.exits[0].triggers, [])
        XCTAssertTrue(plan.exits[0].usesCommonEarlyEntries)

        let again = try JSONDecoder().decode(TrainingPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(again, plan)
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
