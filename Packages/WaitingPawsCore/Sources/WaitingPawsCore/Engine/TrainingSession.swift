import Foundation
import Observation

public enum SessionPhase: Equatable {
    /// Waiting for the "Начать выход" tap.
    case ready(exitIndex: Int)
    /// Walking to the door; the dog is still watching.
    case leaving(exitIndex: Int, since: Date)
    /// Behind the door; countdown to the planned duration.
    case away(exitIndex: Int, since: Date, leftAt: Date)
    /// Break after an exit. `nextExitIndex == nil` means the plan is finished and this is the cool-down.
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
}

/// State machine of one training session. All transitions are driven by button presses
/// (plus `tick(at:)` that is called by a timer for automatic break ending).
@Observable
public final class TrainingSession {
    public let plan: TrainingPlan
    public let startedAt: Date
    public private(set) var phase: SessionPhase
    public private(set) var events: [SessionEvent] = []
    public private(set) var results: [ExitResult] = []
    /// Attempt number of the current exit (increments after a false start).
    public private(set) var attempt: Int = 1
    public private(set) var finishedAt: Date?
    /// Finish the session automatically when the break after the last exit runs out.
    public var autoFinishAfterLastBreak = true

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

    /// "Начать выход": the person heads for the door.
    public func startExit() {
        let now = clock()
        let index: Int
        switch phase {
        case .ready(let i):
            index = i
        case .breakTime(_, let since, let duration, let next):
            guard let next else { return }
            index = next
            let actual = now.timeIntervalSince(since)
            let early = actual < duration
            log(.breakEnded, at: now, detail: early ? "досрочно, \(DurationText.clock(actual)) из \(DurationText.short(duration))" : nil)
        default:
            return
        }
        closeBreak(at: now)
        phase = .leaving(exitIndex: index, since: now)
        log(.exitStarted, at: now, exitNumber: plan.exits[index].number, attempt: attempt,
            detail: "план \(plan.exits[index].durationDescription)")
    }

    /// "За дверью": the door is closed, the countdown starts.
    public func markBehindDoor() {
        guard case .leaving(let index, let since) = phase else { return }
        let now = clock()
        phase = .away(exitIndex: index, since: since, leftAt: now)
        log(.behindDoor, at: now, exitNumber: plan.exits[index].number, attempt: attempt)
    }

    /// "Выход закончен": back inside, the break begins.
    public func endExit() {
        finishCurrentExit(falseStart: false)
    }

    /// "Сбросить выход": false start — back inside, take a break and repeat the same exit.
    public func resetExit() {
        finishCurrentExit(falseStart: true)
    }

    /// Ends the session right now (also used by the auto-finish after the last break).
    public func finish() {
        guard !phase.isFinished else { return }
        let now = clock()
        if phase.isOutside {
            finishCurrentExit(falseStart: false)
        }
        closeBreak(at: now)
        phase = .finished
        finishedAt = now
        log(.sessionFinished, at: now, detail: "выходов \(completedExitsCount) из \(plan.exits.count)")
    }

    /// Called periodically. Ends breaks whose time has run out.
    public func tick(at now: Date? = nil) {
        let now = now ?? clock()
        guard case .breakTime(_, let since, let duration, let next) = phase else { return }
        guard now.timeIntervalSince(since) >= duration else { return }
        if let next {
            phase = .ready(exitIndex: next)
            log(.breakEnded, at: now)
        } else if autoFinishAfterLastBreak {
            finish()
        }
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

    private func finishCurrentExit(falseStart: Bool) {
        let now = clock()
        let index: Int
        let since: Date
        var leftAt: Date?
        switch phase {
        case .leaving(let i, let s):
            index = i; since = s
        case .away(let i, let s, let l):
            index = i; since = s; leftAt = l
        default:
            return
        }

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

        let awayText = "за дверью \(DurationText.clock(result.awayDuration)), всего \(DurationText.clock(result.totalDuration))"
        log(falseStart ? .falseStart : .exitEnded, at: now, exitNumber: exit.number, attempt: attempt, detail: awayText)

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
        log(.breakStarted, at: now, detail: "план \(DurationText.short(plannedBreak))" + (nextIndex == nil ? ", последний" : ""))
    }

    private func closeBreak(at now: Date) {
        guard let start = currentBreakStart, !results.isEmpty else { return }
        results[results.count - 1].actualBreak = now.timeIntervalSince(start)
        currentBreakStart = nil
    }

    private func log(_ kind: SessionEventKind, at time: Date, exitNumber: Int? = nil, attempt: Int? = nil, detail: String? = nil) {
        events.append(SessionEvent(time: time, kind: kind, exitNumber: exitNumber, attempt: attempt, detail: detail))
    }
}
