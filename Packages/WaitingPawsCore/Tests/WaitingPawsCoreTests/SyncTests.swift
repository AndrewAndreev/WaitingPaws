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
        mirror.commandHandler = { command, _ in sent.append(command) }

        mirror.endExit()
        XCTAssertEqual(sent, [.endExit])
        if case .breakTime = mirror.phase {} else { XCTFail("the press shows at once, got \(mirror.phase)") }

        // The owner applies the command and its next snapshot is the mirror's state.
        sent.forEach { $0.apply(to: owner) }
        mirror.restore(owner.snapshot)
        XCTAssertEqual(mirror.snapshot, owner.snapshot)

        // Breaks end on the owner only.
        clock.advance(400)
        mirror.tick()
        if case .breakTime = mirror.phase {} else { XCTFail("mirror must not tick") }
        XCTAssertEqual(mirror.snapshot, owner.snapshot)
    }

    /// Weak Wi-Fi: a state the owner sent before the command reached it (a note, the recording) arrives after the
    /// press. The press stays on screen on top of it, and the owner's own changes show too.
    func testAPressOutlivesAStateSentBeforeIt() {
        let clock = Clock()
        let owner = runningSession(clock) // outside on exit 2 for 12 s
        let mirror = TrainingSession(snapshot: owner.snapshot, clock: { clock.now })
        var sent: [(SessionCommand, Date)] = []
        mirror.commandHandler = { sent.append(($0, $1)) }

        mirror.endExit()
        clock.advance(1)
        owner.noteRecording(started: true, fileName: "a.mp4")
        mirror.restore(owner.snapshot)
        if case .breakTime = mirror.phase {} else { XCTFail("the press must not be undone, got \(mirror.phase)") }
        XCTAssertEqual(mirror.events.last?.kind, .recordingStarted)
        XCTAssertEqual(mirror.results.count, owner.results.count + 1)

        clock.advance(2)
        sent.forEach { $0.0.apply(to: owner, at: $0.1) }
        mirror.restore(owner.snapshot)
        XCTAssertEqual(mirror.snapshot, owner.snapshot)
        XCTAssertEqual(owner.results.last?.endedAt, sent[0].1, "logged at the press, 3 s before it arrived")
    }

    /// Two quick presses: the owner's answer to the first keeps the second on screen.
    func testQuickPressesConfirmedOneByOne() {
        let clock = Clock()
        let owner = runningSession(clock)
        owner.endExit()
        let mirror = TrainingSession(snapshot: owner.snapshot, clock: { clock.now })
        var sent: [(SessionCommand, Date)] = []
        mirror.commandHandler = { sent.append(($0, $1)) }

        mirror.markBehindDoor()
        clock.advance(1)
        mirror.resetExit()
        guard case .breakTime(_, _, _, let next) = mirror.phase else { return XCTFail("expected a break") }
        XCTAssertEqual(next, 2, "a false start repeats exit 3")
        XCTAssertEqual(mirror.attempt, 2)

        sent[0].0.apply(to: owner, at: sent[0].1)
        mirror.restore(owner.snapshot)
        XCTAssertEqual(mirror.attempt, 2, "the second press is still shown")
        XCTAssertEqual(mirror.falseStartsCount, owner.falseStartsCount + 1)

        sent[1].0.apply(to: owner, at: sent[1].1)
        mirror.restore(owner.snapshot)
        XCTAssertEqual(mirror.snapshot, owner.snapshot)
    }

    /// A press on the owner at the same moment wins: the mirror's press, made on the old state, gives way to the
    /// owner's snapshot (the command itself is then applied — or not — by the owner).
    func testThePressOnTheOwnerWins() {
        let clock = Clock()
        let owner = runningSession(clock)
        owner.endExit()
        let mirror = TrainingSession(snapshot: owner.snapshot, clock: { clock.now })
        mirror.commandHandler = { _, _ in }

        mirror.markBehindDoor()
        XCTAssertTrue(mirror.phase.isOutside)
        owner.resetExit() // the dog went to the door: false start on the Mac
        mirror.restore(owner.snapshot)
        XCTAssertEqual(mirror.snapshot, owner.snapshot)
    }

    /// A press the owner never takes stops showing after `predictionLifetime`; one that changes nothing is not kept.
    func testAnUnansweredPressExpires() {
        let clock = Clock()
        let owner = runningSession(clock)
        let mirror = TrainingSession(snapshot: owner.snapshot, clock: { clock.now })
        mirror.commandHandler = { _, _ in }

        mirror.markBehindDoor() // already outside: nothing to show
        XCTAssertEqual(mirror.snapshot, owner.snapshot)

        mirror.endExit()
        clock.advance(TrainingSession.predictionLifetime - 1)
        mirror.tick()
        if case .breakTime = mirror.phase {} else { XCTFail("still waiting for the owner, got \(mirror.phase)") }
        clock.advance(1)
        mirror.tick()
        XCTAssertEqual(mirror.snapshot, owner.snapshot)
    }

    /// «Завершить» on a mirror: «Готово» at once, until the owner's state without the session arrives.
    func testFinishOnTheMirrorShowsAtOnce() {
        let clock = Clock()
        let owner = runningSession(clock)
        let mirror = TrainingSession(snapshot: owner.snapshot, clock: { clock.now })
        var sent: [SessionCommand] = []
        mirror.commandHandler = { command, _ in sent.append(command) }
        mirror.finish()
        XCTAssertEqual(sent, [.finish])
        XCTAssertTrue(mirror.isFinished)
        mirror.restore(owner.snapshot)
        XCTAssertTrue(mirror.isFinished)
    }

    /// A press on the iPhone whose command reaches the Mac seconds later is still logged when it was pressed.
    func testALateCommandKeepsTheMomentOfThePress() throws {
        let clock = Clock()
        let owner = runningSession(clock) // outside for 12 s
        let mirror = TrainingSession(snapshot: owner.snapshot, clock: { clock.now })
        var sent: [(SessionCommand, Date)] = []
        mirror.commandHandler = { sent.append(($0, $1)) }
        mirror.endExit()
        let pressed = clock.now

        clock.advance(6) // Wi-Fi trouble
        let message = SyncMessage.command(.session(sent[0].0, at: sent[0].1))
        guard case .command(.session(let command, let time)) = try SyncMessage.decode(message.encoded()) else {
            return XCTFail("no command")
        }
        command.apply(to: owner, at: time)
        XCTAssertEqual(owner.results.last?.endedAt, pressed)
        guard case .breakTime(_, let since, _, _) = owner.phase else { return XCTFail("expected a break") }
        XCTAssertEqual(since, pressed)
        XCTAssertEqual(owner.remaining(at: clock.now), 294, "the 5 min break has run for 6 s already")
    }

    /// A time from a clock that is off never goes before the current phase or into the future.
    func testPressTimeStaysWithinThePhase() {
        let clock = Clock()
        let owner = runningSession(clock)
        guard case .away(_, _, let leftAt) = owner.phase else { return XCTFail("expected outside") }
        owner.endExit(at: leftAt.addingTimeInterval(-30))
        XCTAssertEqual(owner.results.last?.endedAt, leftAt)

        owner.markBehindDoor(at: clock.now.addingTimeInterval(90))
        guard case .away(_, _, let outside) = owner.phase else { return XCTFail("expected outside") }
        XCTAssertEqual(outside, clock.now)
        XCTAssertEqual(owner.events.map(\.time), owner.events.map(\.time).sorted())
    }

    /// A button press from an iPhone built before press times still decodes (the Mac uses its own now).
    func testCommandWithoutPressTimeStillDecodes() throws {
        var json = try JSONSerialization.jsonObject(with: SyncMessage.command(.session(.endExit, at: Date())).encoded()) as! [String: Any]
        var command = (json["command"] as! [String: Any])["_0"] as! [String: Any]
        var session = command["session"] as! [String: Any]
        session.removeValue(forKey: "at")
        command["session"] = session
        json["command"] = ["_0": command]
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(try SyncMessage.decode(data), .command(.session(.endExit, at: nil)))
    }

    func testClockOffsetFromTheFastestState() {
        var clock = SyncClock()
        let local = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(clock.hostTime(for: local), local, "no sample yet: the clocks are trusted")
        // The host is 2 s ahead; the states took 0.5 s, 0.05 s and 1.2 s to arrive.
        clock.sample(hostTime: local.addingTimeInterval(2), receivedAt: local.addingTimeInterval(0.5))
        clock.sample(hostTime: local.addingTimeInterval(12), receivedAt: local.addingTimeInterval(10.05))
        clock.sample(hostTime: local.addingTimeInterval(20), receivedAt: local.addingTimeInterval(19.2))
        XCTAssertEqual(clock.offset ?? 0, 1.95, accuracy: 0.001)
        XCTAssertEqual(clock.hostTime(for: local.addingTimeInterval(30)).timeIntervalSince(local), 31.95, accuracy: 0.001)
    }

    /// An edit on the Mac (here a step of a drag) reaches a linked iPhone with the next state: its plan and its
    /// countdown follow at once.
    func testAnEditOnTheHostReachesTheMirror() throws {
        let clock = Clock()
        let owner = runningSession(clock) // outside on exit 2 for 12 s
        let mirror = TrainingSession(snapshot: owner.snapshot, clock: { clock.now })
        var edited = owner.plan
        edited.exits[1].duration = 90
        XCTAssertTrue(owner.updatePlan(edited, quiet: true))

        let message = SyncMessage.state(SyncState(session: owner.snapshot, recordingSince: nil, cameraReady: true,
                                                  cameraTitle: "Прихожая", streamName: "hall", lastRecord: nil, sentAt: clock.now))
        guard case .state(let state) = try SyncMessage.decode(message.encoded()), let snapshot = state.session else {
            return XCTFail("no state")
        }
        mirror.restore(snapshot)
        XCTAssertEqual(mirror.plan.exits[1].duration, 90)
        XCTAssertEqual(mirror.remaining(at: clock.now), 78)
        XCTAssertEqual(mirror.snapshot, owner.snapshot)
    }

    func testRestoreIgnoresAnotherSession() {
        let clock = Clock()
        let a = runningSession(clock)
        let b = TrainingSession(plan: plan(), clock: { clock.now })
        let before = a.snapshot
        a.restore(b.snapshot)
        XCTAssertEqual(a.snapshot, before)
    }

    /// A schedule pasted on either side travels both ways before the start.
    func testPendingPlanTravelsBothWays() throws {
        let plan = plan()
        let state = SyncMessage.state(SyncState(session: nil, recordingSince: nil, cameraReady: true, cameraTitle: "Прихожая",
                                                streamName: "hall", lastRecord: nil, pendingPlan: plan))
        guard case .state(let decoded) = try SyncMessage.decode(state.encoded()) else { return XCTFail("no state") }
        XCTAssertEqual(decoded.pendingPlan, plan)

        for command in [SyncCommand.setPendingPlan(plan), .setPendingPlan(nil), .updateSessionPlan(plan),
                        .updateSessionPlan(plan, quiet: true), .updateSessionPlan(plan, since: plan)] {
            XCTAssertEqual(try SyncMessage.decode(SyncMessage.command(command).encoded()), .command(command))
        }
    }

    /// A state from a Mac built before schedules were synced still decodes (no pending schedule).
    func testStateWithoutPendingPlanStillDecodes() throws {
        let old = SyncState(session: nil, recordingSince: nil, cameraReady: false, cameraTitle: "", streamName: "", lastRecord: nil)
        var json = try JSONSerialization.jsonObject(with: SyncMessage.state(old).encoded()) as! [String: Any]
        var payload = (json["state"] as! [String: Any])["_0"] as! [String: Any]
        payload.removeValue(forKey: "pendingPlan")
        json["state"] = ["_0": payload]
        guard case .state(let decoded) = try SyncMessage.decode(JSONSerialization.data(withJSONObject: json)) else {
            return XCTFail("no state")
        }
        XCTAssertNil(decoded.pendingPlan)
    }

    /// The camera on screen travels both ways: the Mac's in its state, the iPhone's switch as a command. A state from
    /// a Mac before that has no camera in it, which tells the iPhone not to send the command.
    func testShownCameraTravelsBothWays() throws {
        let state = SyncState(session: nil, recordingSince: nil, cameraReady: true, cameraTitle: "Прихожая", streamName: "hall",
                              lastRecord: nil, secondStreamName: "room", showsSecondCamera: true)
        guard case .state(let decoded) = try SyncMessage.decode(SyncMessage.state(state).encoded()) else {
            return XCTFail("no state")
        }
        XCTAssertEqual(decoded.showsSecondCamera, true)
        for command in [SyncCommand.showCamera(second: true), .showCamera(second: false)] {
            XCTAssertEqual(try SyncMessage.decode(SyncMessage.command(command).encoded()), .command(command))
        }

        var json = try JSONSerialization.jsonObject(with: SyncMessage.state(state).encoded()) as! [String: Any]
        var payload = (json["state"] as! [String: Any])["_0"] as! [String: Any]
        payload.removeValue(forKey: "showsSecondCamera")
        json["state"] = ["_0": payload]
        guard case .state(let old) = try SyncMessage.decode(JSONSerialization.data(withJSONObject: json)) else {
            return XCTFail("no state")
        }
        XCTAssertNil(old.showsSecondCamera)
    }

    func testHostInfoTXTRoundTrip() {
        let info = SyncHostInfo(name: "MacBook Андрея", cameraTitle: "Прихожая", cameraReady: true, sessionRunning: true, currentExit: 6)
        XCTAssertEqual(SyncHostInfo(name: info.name, txt: info.txt), info)
    }
}
