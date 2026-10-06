import Foundation
import Observation

public enum SessionPhase: Equatable, Codable {
    /// Before the first exit: waiting for "Вышли".
    case ready(exitIndex: Int)
    /// Walking to the door; the dog is still watching. Only the "Начать выход" of an older linked iPhone leads here:
    /// the buttons now go from the break straight to `away`.
    case leaving(exitIndex: Int, since: Date)
    /// Behind the door; countdown to the planned duration.
    case away(exitIndex: Int, since: Date, leftAt: Date)
    /// Break after an exit. It lasts until "Вышли" (past its plan, too); `nextExitIndex == nil` means the plan is
    /// finished and this is the cool-down, which ends the session when it runs out.
    case breakTime(afterExitIndex: Int, since: Date, duration: TimeInterval, nextExitIndex: Int?)
    case finished

    public var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }

    public var isOutside: Bool {
        switch self {
        case .leaving, .away: return true
        default: return false
        }
    }

    /// "Вышли" is the next step: before the first exit, or in a break with an exit after it.
    public var canGoOutside: Bool {
        switch self {
        case .ready, .leaving: return true
        case .breakTime(_, _, _, let next): return next != nil
        default: return false
        }
    }

    /// "Фальстарт" means something now: on the way out or outside.
    public var canFalseStart: Bool { canGoOutside || isOutside }
}

/// State machine of one training session. All transitions are driven by two buttons — "Вышли" / "Вернулись" and
/// "Фальстарт" — plus `tick(at:)`, called by a timer, that finishes the session when the last break runs out.
@Observable
public final class TrainingSession {
    /// The schedule; `updatePlan` replaces it while the session runs (same id, see there).
    public private(set) var plan: TrainingPlan
    public let startedAt: Date
    public private(set) var phase: SessionPhase
    public private(set) var events: [SessionEvent] = []
    public private(set) var results: [ExitResult] = []
    /// Attempt number of the current exit (increments after a false start).
    public private(set) var attempt: Int = 1
    public private(set) var finishedAt: Date?
    /// Finish the session automatically when the break after the last exit runs out.
    public var autoFinishAfterLastBreak = true
    /// Set on a mirror of a session that runs on another device (iPhone connected to a Mac): the buttons
    /// call the usual actions, but they are forwarded here instead of changing this copy, and `tick` does
    /// nothing. The owner applies the command and sends back a new `Snapshot` (`restore`). The date is when the
    /// button was pressed here, so a command that arrives late is still logged at the moment of the press.
    public var commandHandler: ((SessionCommand, Date) -> Void)?
    /// The same for `updatePlan` on a mirror: the edited schedule goes to the owner (with `quiet` and
    /// `changesSince` as given).
    public var planHandler: ((TrainingPlan, Bool, TrainingPlan?) -> Void)?

    private let clock: () -> Date
    private var currentBreakStart: Date?

    public init(plan: TrainingPlan, clock: @escaping () -> Date = Date.init) {
        self.plan = plan
        self.clock = clock
        let now = clock()
        self.startedAt = now
        self.phase = plan.exits.isEmpty ? .finished : .ready(exitIndex: 0)
        log(.sessionStarted, at: now)
    }

    // MARK: - Snapshot (sync between devices)

    /// The whole state of a session: enough to rebuild an identical copy on another device.
    public struct Snapshot: Codable, Equatable {
        public var plan: TrainingPlan
        public var startedAt: Date
        public var phase: SessionPhase
        public var events: [SessionEvent]
        public var results: [ExitResult]
        public var attempt: Int
        public var finishedAt: Date?
        public var autoFinishAfterLastBreak: Bool
        public var currentBreakStart: Date?
    }

    public var snapshot: Snapshot {
        Snapshot(plan: plan, startedAt: startedAt, phase: phase, events: events, results: results, attempt: attempt,
                 finishedAt: finishedAt, autoFinishAfterLastBreak: autoFinishAfterLastBreak,
                 currentBreakStart: currentBreakStart)
    }

    /// A copy of a session that runs elsewhere (no `sessionStarted` event is added).
    public init(snapshot: Snapshot, clock: @escaping () -> Date = Date.init) {
        self.plan = snapshot.plan
        self.startedAt = snapshot.startedAt
        self.clock = clock
        self.phase = snapshot.phase
        apply(snapshot)
    }

    /// Whether `snapshot` describes this very session (same plan and start), so `restore` can be used.
    public func isSameSession(as snapshot: Snapshot) -> Bool {
        snapshot.plan.id == plan.id && snapshot.startedAt == startedAt
    }

    /// Updates the state in place from a newer snapshot of the same session.
    public func restore(_ snapshot: Snapshot) {
        guard isSameSession(as: snapshot) else { return }
        apply(snapshot)
    }

    private func apply(_ snapshot: Snapshot) {
        if plan != snapshot.plan { plan = snapshot.plan }
        if phase != snapshot.phase { phase = snapshot.phase }
        if events != snapshot.events { events = snapshot.events }
        if results != snapshot.results { results = snapshot.results }
        if attempt != snapshot.attempt { attempt = snapshot.attempt }
        if finishedAt != snapshot.finishedAt { finishedAt = snapshot.finishedAt }
        autoFinishAfterLastBreak = snapshot.autoFinishAfterLastBreak
        currentBreakStart = snapshot.currentBreakStart
    }

    // MARK: - Derived state

    public var currentExitIndex: Int? {
        switch phase {
        case .ready(let index), .leaving(let index, _), .away(let index, _, _):
            return index
        case .breakTime(_, _, _, let next):
            return next
        case .finished:
            return nil
        }
    }

    public var currentExit: PlannedExit? {
        guard let index = currentExitIndex, plan.exits.indices.contains(index) else { return nil }
        return plan.exits[index]
    }

    /// The exit that comes after the current one (for the "next up" hint).
    public var upcomingExit: PlannedExit? {
        guard let index = currentExitIndex else { return nil }
        let next = index + 1
        guard plan.exits.indices.contains(next) else { return nil }
        return plan.exits[next]
    }

    /// Break that will follow the current exit.
    public var breakAfterCurrentExit: TimeInterval? {
        guard let index = currentExitIndex else { return nil }
        return plan.breakAfter(exitAt: index)
    }

    public var completedExitsCount: Int { results.filter { !$0.falseStart }.count }
    public var falseStartsCount: Int { results.filter { $0.falseStart }.count }
    public var isFinished: Bool { phase.isFinished }

    /// Seconds left in the current countdown (`away` / `breakTime`); negative when overdue. `nil` when there is no countdown.
    public func remaining(at now: Date) -> TimeInterval? {
        switch phase {
        case .away(let index, _, let leftAt):
            return plan.exits[index].duration - now.timeIntervalSince(leftAt)
        case .breakTime(_, let since, let duration, _):
            return duration - now.timeIntervalSince(since)
        default:
            return nil
        }
    }

    /// Seconds since the current phase began.
    public func elapsed(at now: Date) -> TimeInterval {
        switch phase {
        case .ready:
            if let currentBreakStart { return now.timeIntervalSince(currentBreakStart) }
            return now.timeIntervalSince(startedAt)
        case .leaving(_, let since):
            return now.timeIntervalSince(since)
        case .away(_, _, let leftAt):
            return now.timeIntervalSince(leftAt)
        case .breakTime(_, let since, _, _):
            return now.timeIntervalSince(since)
        case .finished:
            return (finishedAt ?? now).timeIntervalSince(startedAt)
        }
    }

    /// 0…1 progress of the current countdown, if any.
    public func progress(at now: Date) -> Double? {
        switch phase {
        case .away(let index, _, let leftAt):
            let planned = plan.exits[index].duration
            guard planned > 0 else { return nil }
            return min(1, max(0, now.timeIntervalSince(leftAt) / planned))
        case .breakTime(_, let since, let duration, _):
            guard duration > 0 else { return nil }
            return min(1, max(0, now.timeIntervalSince(since) / duration))
        default:
            return nil
        }
    }

    // MARK: - Actions

    // Every action takes `at`: when the button was pressed on another device (a linked iPhone), so the log and the
    // timeline keep that moment however late the command arrives. See `moment(_:)`.

    /// "Начать выход" of an older linked iPhone: the person heads for the door (`leaving`, then `markBehindDoor`).
    public func startExit(at time: Date? = nil) {
        if let commandHandler { commandHandler(.startExit, time ?? clock()); return }
        let now = moment(time)
        let index: Int
        switch phase {
        case .ready(let i):
            index = i
        case .breakTime(_, let since, let duration, let next):
            guard let next else { return }
            index = next
            logBreakEnd(since: since, duration: duration, at: now)
        default:
            return
        }
        closeBreak(at: now)
        phase = .leaving(exitIndex: index, since: now)
        log(.exitStarted, at: now, exitNumber: plan.exits[index].number, attempt: attempt,
            detail: tr("план \(plan.exits[index].durationDescription)", "plan \(plan.exits[index].durationDescription)"))
    }

    /// "Вышли": the door is closed behind you, the exit's countdown starts. Ends the break (or the wait before
    /// the first exit) right away.
    public func markBehindDoor(at time: Date? = nil) {
        if let commandHandler { commandHandler(.markBehindDoor, time ?? clock()); return }
        let now = moment(time)
        switch phase {
        case .leaving(let index, let since):
            phase = .away(exitIndex: index, since: since, leftAt: now)
            log(.behindDoor, at: now, exitNumber: plan.exits[index].number, attempt: attempt)
        case .ready(let index):
            closeBreak(at: now)
            goOutside(index, at: now)
        case .breakTime(_, let since, let duration, let next):
            guard let next else { return }
            logBreakEnd(since: since, duration: duration, at: now)
            closeBreak(at: now)
            goOutside(next, at: now)
        default:
            return
        }
    }

    /// "Вернулись": back inside, the break begins.
    public func endExit(at time: Date? = nil) {
        if let commandHandler { commandHandler(.endExit, time ?? clock()); return }
        finishCurrentExit(falseStart: false, at: moment(time))
    }

    /// "Фальстарт": the exit failed — take a break and repeat the same exit. Outside: back inside early. In the
    /// break (or before the first exit): the dog went to the door, or there were sounds on the way out, before
    /// "Вышли" — the attempt counts as a false start and the break starts over.
    public func resetExit(at time: Date? = nil) {
        if let commandHandler { commandHandler(.resetExit, time ?? clock()); return }
        let now = moment(time)
        switch phase {
        case .leaving, .away:
            finishCurrentExit(falseStart: true, at: now)
        case .ready(let index):
            falseStartBeforeDoor(index, at: now)
        case .breakTime(_, let since, let duration, let next):
            guard let next else { return }
            logBreakEnd(since: since, duration: duration, at: now)
            falseStartBeforeDoor(next, at: now)
        case .finished:
            return
        }
    }

    // MARK: - Editing the schedule

    /// How many exits from the start of the plan are fixed while the session runs: the ones done and the current
    /// one. An edit may change their values, but not remove or reorder them.
    public var fixedExitCount: Int {
        switch phase {
        case .ready(let index): return index
        case .leaving(let index, _), .away(let index, _, _): return index + 1
        case .breakTime(let after, _, _, _): return after + 1
        case .finished: return plan.exits.count
        }
    }

    /// Whether `newPlan` can replace the running schedule: the same plan (id), with the fixed exits still first and
    /// in their order, and an exit for the session to be at.
    public func canUpdatePlan(to newPlan: TrainingPlan) -> Bool {
        guard !phase.isFinished, newPlan.id == plan.id, newPlan.isValid else { return false }
        let fixed = fixedExitCount
        guard newPlan.exits.count >= fixed else { return false }
        if case .ready(let index) = phase, index >= newPlan.exits.count { return false }
        return newPlan.exits.prefix(fixed).map(\.id) == plan.exits.prefix(fixed).map(\.id)
    }

    /// Replaces the schedule while the session runs — e.g. every break longer when the trainer's text was read wrong
    /// and nobody noticed before the start. The current exit counts down to its new length at once, the running break
    /// takes its new length too, and exits added after the last one carry the training on. Returns false and changes
    /// nothing when the edit drops or reorders exits already done (or the current).
    ///
    /// The log gets a note with what changed. An edit applied step by step as it goes (a drag, typing) passes
    /// `quiet` for every step and `changesSince` — the plan before the edit — with the last one: one note for it all.
    @discardableResult
    public func updatePlan(_ newPlan: TrainingPlan, quiet: Bool = false, changesSince original: TrainingPlan? = nil) -> Bool {
        guard canUpdatePlan(to: newPlan) else { return false }
        if let planHandler { planHandler(newPlan, quiet, original); return true }
        var newPlan = newPlan
        newPlan.renumber()
        let changes = quiet ? [] : newPlan.changes(from: original ?? plan)
        if case .breakTime(let after, let since, _, let next) = phase {
            // A false start's break leads to the same exit again; otherwise to whatever follows now.
            let newNext = next == after ? after : (newPlan.exits.indices.contains(after + 1) ? after + 1 : nil)
            let duration = newPlan.breakAfter(exitAt: after)
            phase = .breakTime(afterExitIndex: after, since: since, duration: duration, nextExitIndex: newNext)
            if !results.isEmpty { results[results.count - 1].plannedBreak = duration }
        }
        plan = newPlan
        if !changes.isEmpty {
            log(.note, at: clock(), exitNumber: currentExit?.number,
                detail: tr("Расписание изменено: ", "Schedule changed: ") + changes.joined(separator: "; "))
        }
        return true
    }

    /// Ends the session right now (also used by the auto-finish after the last break).
    public func finish() {
        if let commandHandler { commandHandler(.finish, clock()); return }
        guard !phase.isFinished else { return }
        let now = clock()
        if phase.isOutside {
            finishCurrentExit(falseStart: false, at: now)
        }
        closeBreak(at: now)
        phase = .finished
        finishedAt = now
        log(.sessionFinished, at: now, detail: tr("выходов \(completedExitsCount) из \(plan.exits.count)",
                                                  "exits \(completedExitsCount) of \(plan.exits.count)"))
    }

    /// Called periodically. Finishes the session when the break after the last exit runs out; other breaks
    /// go on past their plan until "Вышли" (the views count the extra time up).
    public func tick(at now: Date? = nil) {
        guard commandHandler == nil, autoFinishAfterLastBreak else { return }
        let now = now ?? clock()
        guard case .breakTime(_, let since, let duration, nil) = phase, now.timeIntervalSince(since) >= duration else { return }
        finish()
    }

    public func addNote(_ text: String) {
        log(.note, at: clock(), exitNumber: currentExit?.number, detail: text)
    }

    public func noteRecording(started: Bool, fileName: String? = nil) {
        log(started ? .recordingStarted : .recordingStopped, at: clock(), detail: fileName)
    }

    public func makeRecord(recordingFileName: String?) -> TrainingRecord {
        TrainingRecord(plan: plan,
                       startedAt: startedAt,
                       finishedAt: finishedAt ?? clock(),
                       events: events,
                       results: results,
                       recordingFileName: recordingFileName)
    }

    // MARK: - Internals

    private func finishCurrentExit(falseStart: Bool, at now: Date) {
        switch phase {
        case .leaving(let index, let since):
            endAttempt(index, startedAt: since, leftAt: nil, falseStart: falseStart, at: now)
        case .away(let index, let since, let leftAt):
            endAttempt(index, startedAt: since, leftAt: leftAt, falseStart: falseStart, at: now)
        default:
            return
        }
    }

    /// When a press happened: `time` from the device it was made on, kept between the start of the current phase and
    /// now (a clock that is off, or a command for an earlier phase, never puts an event before the one it follows or
    /// in the future); without it, now.
    private func moment(_ time: Date?) -> Date {
        let now = clock()
        guard let time else { return now }
        let phaseStart: Date
        switch phase {
        case .ready: phaseStart = currentBreakStart ?? startedAt
        case .leaving(_, let since), .breakTime(_, let since, _, _): phaseStart = since
        case .away(_, _, let leftAt): phaseStart = leftAt
        case .finished: return now
        }
        return min(now, max(phaseStart, time))
    }

    /// A false start before "Вышли": an attempt that never got outside.
    private func falseStartBeforeDoor(_ index: Int, at now: Date) {
        closeBreak(at: now)
        endAttempt(index, startedAt: now, leftAt: nil, falseStart: true, at: now)
    }

    private func goOutside(_ index: Int, at now: Date) {
        phase = .away(exitIndex: index, since: now, leftAt: now)
        log(.behindDoor, at: now, exitNumber: plan.exits[index].number, attempt: attempt,
            detail: tr("план \(plan.exits[index].durationDescription)", "plan \(plan.exits[index].durationDescription)"))
    }

    /// "Перерыв окончен" when it ends by a button: early, or how far past its plan.
    private func logBreakEnd(since: Date, duration: TimeInterval, at now: Date) {
        let actual = now.timeIntervalSince(since)
        let detail: String?
        if actual < duration {
            detail = tr("досрочно, \(DurationText.clock(actual)) из \(DurationText.short(duration))",
                        "early, \(DurationText.clock(actual)) of \(DurationText.short(duration))")
        } else if actual - duration >= 1 {
            detail = tr("дольше плана, \(DurationText.clock(actual)) из \(DurationText.short(duration))",
                        "longer than planned, \(DurationText.clock(actual)) of \(DurationText.short(duration))")
        } else {
            detail = nil
        }
        log(.breakEnded, at: now, detail: detail)
    }

    private func endAttempt(_ index: Int, startedAt since: Date, leftAt: Date?, falseStart: Bool, at now: Date) {
        let exit = plan.exits[index]
        let plannedBreak = plan.breakAfter(exitAt: index)
        let result = ExitResult(number: exit.number,
                                attempt: attempt,
                                plannedDuration: exit.duration,
                                untilStanding: exit.untilStanding,
                                startedAt: since,
                                leftAt: leftAt,
                                endedAt: now,
                                falseStart: falseStart,
                                plannedBreak: plannedBreak)
        results.append(result)

        let detail = leftAt == nil && since == now
            ? tr("до двери", "before the door")
            : tr("за дверью \(DurationText.clock(result.awayDuration)), всего \(DurationText.clock(result.totalDuration))",
                 "outside \(DurationText.clock(result.awayDuration)), total \(DurationText.clock(result.totalDuration))")
        log(falseStart ? .falseStart : .exitEnded, at: now, exitNumber: exit.number, attempt: attempt, detail: detail)

        let nextIndex: Int?
        if falseStart {
            nextIndex = index
            attempt += 1
        } else {
            nextIndex = plan.exits.indices.contains(index + 1) ? index + 1 : nil
            attempt = 1
        }

        currentBreakStart = now
        phase = .breakTime(afterExitIndex: index, since: now, duration: plannedBreak, nextExitIndex: nextIndex)
        log(.breakStarted, at: now, detail: tr("план \(DurationText.short(plannedBreak))", "plan \(DurationText.short(plannedBreak))")
            + (nextIndex == nil ? tr(", последний", ", last") : ""))
    }

    private func closeBreak(at now: Date) {
        guard let start = currentBreakStart, !results.isEmpty else { return }
        results[results.count - 1].actualBreak = now.timeIntervalSince(start)
        currentBreakStart = nil
    }

    /// Keeps the log in time order: a press from an iPhone may be older than a note or a recording event logged
    /// while its command was on the way.
    private func log(_ kind: SessionEventKind, at time: Date, exitNumber: Int? = nil, attempt: Int? = nil, detail: String? = nil) {
        let event = SessionEvent(time: time, kind: kind, exitNumber: exitNumber, attempt: attempt, detail: detail)
        let index = events.lastIndex { $0.time <= time }.map { $0 + 1 } ?? 0
        events.insert(event, at: index)
    }
}

/// A button press on a session, sent to the device that owns it (an edited schedule goes as
/// `SyncCommand.updateSessionPlan`).
public enum SessionCommand: String, Codable, CaseIterable {
    case startExit, markBehindDoor, endExit, resetExit, finish

    /// Applies the command to a session owned by this device; `time` is when it was pressed (the owner's clock).
    public func apply(to session: TrainingSession, at time: Date? = nil) {
        switch self {
        case .startExit: session.startExit(at: time)
        case .markBehindDoor: session.markBehindDoor(at: time)
        case .endExit: session.endExit(at: time)
        case .resetExit: session.resetExit(at: time)
        case .finish: session.finish()
        }
    }
}
