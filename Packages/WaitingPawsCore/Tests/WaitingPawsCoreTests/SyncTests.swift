import XCTest
@testable import WaitingPawsCore

final class SyncTests: XCTestCase {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
    }

    private func plan() -> TrainingPlan {
        PlanParser.parse("""
        Тренировка на воскресенье - Таня/Андрей - 04.10.2026
        Все перерывы 2 минуты
        1 выход - 10 секунд
        2 выход - 30 секунд
        Перерыв 5 минут
        3 выход - 1 минута ИЛИ до вставания
        """)
    }

    /// Owner session in the middle of things: one exit done, a false start, behind the door now.
    private func runningSession(_ clock: Clock) -> TrainingSession {
        let session = TrainingSession(plan: plan(), clock: { clock.now })
        session.startExit(); clock.advance(5); session.markBehindDoor(); clock.advance(11); session.endExit()
        clock.advance(121); session.startExit(); clock.advance(4); session.markBehindDoor(); clock.advance(8); session.resetExit()
        clock.advance(120); session.tick(); session.startExit(); clock.advance(6); session.markBehindDoor(); clock.advance(12)
        return session
    }

    func testSnapshotSurvivesJSONAndRebuildsTheSameState() throws {
        let clock = Clock()
        let owner = runningSession(clock)
        let message = SyncMessage.state(SyncState(session: owner.snapshot, recordingSince: owner.startedAt,
                                                  cameraReady: true, cameraTitle: "Прихожая", streamName: "hall",
                                                  lastRecord: nil))
        let decoded = try SyncMessage.decode(message.encoded())
        guard case .state(let state) = decoded, let snapshot = state.session else { return XCTFail("no state") }
        XCTAssertEqual(snapshot, owner.snapshot)

        let mirror = TrainingSession(snapshot: snapshot, clock: { clock.now })
        XCTAssertEqual(mirror.phase, owner.phase)
        XCTAssertEqual(mirror.attempt, 2)
        XCTAssertEqual(mirror.currentExit?.number, 2)
        XCTAssertEqual(mirror.remaining(at: clock.now), owner.remaining(at: clock.now))
        XCTAssertEqual(mirror.falseStartsCount, 1)
        XCTAssertEqual(mirror.events, owner.events)
    }

    func testMirrorForwardsButtonsAndRestoresInPlace() {
        let clock = Clock()
        let owner = runningSession(clock)
        let mirror = TrainingSession(snapshot: owner.snapshot, clock: { clock.now })
        var sent: [SessionCommand] = []
        mirror.commandHandler = { sent.append($0) }

        mirror.endExit()
        XCTAssertEqual(sent, [.endExit])
        XCTAssertTrue(mirror.phase.isOutside, "a mirror never changes on its own")

        // The owner applies the command and the mirror catches up from the next snapshot.
        sent.forEach { $0.apply(to: owner) }
        mirror.restore(owner.snapshot)
        XCTAssertEqual(mirror.snapshot, owner.snapshot)
        if case .breakTime = mirror.phase {} else { XCTFail("expected a break, got \(mirror.phase)") }

        // Breaks end on the owner only.
        clock.advance(400)
        mirror.tick()
        if case .breakTime = mirror.phase {} else { XCTFail("mirror must not tick") }
    }

    func testRestoreIgnoresAnotherSession() {
        let clock = Clock()
        let a = runningSession(clock)
        let b = TrainingSession(plan: plan(), clock: { clock.now })
        let before = a.snapshot
        a.restore(b.snapshot)
        XCTAssertEqual(a.snapshot, before)
    }

    func testHostInfoTXTRoundTrip() {
        let info = SyncHostInfo(name: "MacBook Андрея", cameraTitle: "Прихожая", cameraReady: true, sessionRunning: true, currentExit: 6)
        XCTAssertEqual(SyncHostInfo(name: info.name, txt: info.txt), info)
    }
}
