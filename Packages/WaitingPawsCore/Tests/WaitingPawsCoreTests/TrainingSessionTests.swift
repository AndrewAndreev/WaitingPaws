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

        session.startExit()
        advance(3)
        session.markBehindDoor()
        advance(2)
        XCTAssertEqual(session.remaining(at: now), 3)
        advance(5)
        XCTAssertEqual(session.remaining(at: now), -2)
        session.endExit()

        XCTAssertEqual(session.results.count, 1)
        XCTAssertEqual(session.results[0].awayDuration, 7)
        XCTAssertEqual(session.results[0].totalDuration, 10)
        XCTAssertFalse(session.results[0].falseStart)
        guard case .breakTime(let after, _, let duration, let next) = session.phase else { return XCTFail("expected break") }
        XCTAssertEqual(after, 0)
        XCTAssertEqual(duration, 120)
        XCTAssertEqual(next, 1)

        // Break runs out → ready for exit 2.
        advance(121)
        session.tick(at: now)
        XCTAssertEqual(session.phase, .ready(exitIndex: 1))

        advance(10)
        session.startExit()
        XCTAssertEqual(session.results[0].actualBreak, 131)
        session.markBehindDoor()
        advance(20)
        session.endExit()

        guard case .breakTime(_, _, let lastBreak, let lastNext) = session.phase else { return XCTFail("expected last break") }
        XCTAssertEqual(lastBreak, 300)
        XCTAssertNil(lastNext)

        advance(300)
        session.tick(at: now)
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.completedExitsCount, 2)
        XCTAssertEqual(session.events.last?.kind, .sessionFinished)
    }

    func testFalseStartRepeatsExit() {
        let session = makeSession()
        session.startExit()
        session.markBehindDoor()
        advance(1)
        session.resetExit()

        XCTAssertEqual(session.results.count, 1)
        XCTAssertTrue(session.results[0].falseStart)
        XCTAssertEqual(session.attempt, 2)
        guard case .breakTime(_, _, _, let next) = session.phase else { return XCTFail("expected break") }
        XCTAssertEqual(next, 0)

        session.startExit() // early, before the break ends
        XCTAssertEqual(session.phase, .leaving(exitIndex: 0, since: now))
        XCTAssertEqual(session.events.filter { $0.kind == .breakEnded }.count, 1)
        session.endExit()
        XCTAssertEqual(session.results[1].attempt, 2)
        XCTAssertEqual(session.attempt, 1)
        XCTAssertEqual(session.currentExitIndex, 1)
    }

    func testFinishWhileOutsideClosesExit() {
        let session = makeSession()
        session.startExit()
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
        session.startExit(); session.markBehindDoor(); advance(5); session.endExit(); session.finish()
        let record = session.makeRecord(recordingFileName: "video.mp4")
        let text = SessionLogFormatter.text(for: record)
        XCTAssertFalse(text.contains("video.mp4"), "the file name is no use to the trainer")
        XCTAssertTrue(text.contains("1 выход — 5 с: за дверью 0:05 ✅"))
        XCTAssertFalse(text.contains("перерыв"), "the break after the last exit only ends the session")
    }

    func testLogFormatterOneLinePerAttempt() {
        let session = makeSession()
        session.startExit(); session.markBehindDoor(); advance(2); session.resetExit()
        advance(60); session.startExit(); session.markBehindDoor(); advance(5); session.endExit()
        advance(120); session.tick()
        session.startExit(); session.markBehindDoor(); advance(30); session.endExit(); session.finish()
        let lines = SessionLogFormatter.text(for: session.makeRecord(recordingFileName: nil))
            .components(separatedBy: "\n").filter { $0.contains(" выход — ") }
        XCTAssertEqual(lines, [
            "1 выход — 5 с: фальстарт, за дверью 0:02 ❌ · перерыв 1:00 (план 2 мин)",
            "1 выход — 5 с, попытка 2: за дверью 0:05 ✅ · перерыв 2:00",
            "2 выход — 30 с или до вставания: за дверью 0:30 ✅",
        ])
    }
}
