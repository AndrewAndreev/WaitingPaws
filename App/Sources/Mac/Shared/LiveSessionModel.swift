#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Everything the Mac training window shows, derived from `TrainingSession` at a given moment
/// (recomputed by a `TimelineView` twice a second).
struct LiveSessionModel {
    let session: TrainingSession
    let now: Date
    var recordingSince: Date?

    init(session: TrainingSession, now: Date, recordingSince: Date?) {
        self.session = session
        self.now = now
        self.recordingSince = recordingSince
    }

    var plan: TrainingPlan { session.plan }
    var phase: SessionPhase { session.phase }

    var isBreak: Bool { if case .breakTime = phase { return true }; return false }
    var isAway: Bool { if case .away = phase { return true }; return false }
    var isLeaving: Bool { if case .leaving = phase { return true }; return false }
    var isReady: Bool { if case .ready = phase { return true }; return false }
    var isFinished: Bool { phase.isFinished }

    var remaining: TimeInterval? { session.remaining(at: now) }
    var overdue: Bool { (remaining ?? 0) < 0 }
    var progress: Double { session.progress(at: now) ?? 0 }

    /// Past the plan — an exit or a break — the iPhone's yellow (`Theme.overtime`), never the false start's orange.
    var tint: Color {
        if overdue { return Theme.overtime }
        if isBreak { return MacPalette.blue }
        if isFinished { return MacPalette.green }
        return MacPalette.pink
    }

    /// Big readout: countdown (counting up past the plan with a "+"), or elapsed time on the way to the door.
    var timerText: String {
        switch phase {
        case .ready: return DurationText.clock(session.currentExit?.duration ?? 0)
        case .leaving: return DurationText.clock(session.elapsed(at: now))
        case .away, .breakTime:
            let r = remaining ?? 0
            return r < 0 ? "+" + DurationText.clock(-r) : DurationText.clock(r)
        case .finished: return DurationText.clock(session.elapsed(at: now))
        }
    }

    var title: String {
        switch phase {
        case .ready, .leaving, .away: return String(localized: "Выход \(session.currentExit?.number ?? 0)")
        case .breakTime(_, _, _, let next): return next == nil ? String(localized: "Последний перерыв") : String(localized: "Перерыв")
        case .finished: return String(localized: "Тренировка завершена")
        }
    }

    /// "За дверью", "сверх плана"…: what the timer is doing, next to the title.
    var phaseName: String {
        if overdue { return String(localized: "сверх плана") }
        switch phase {
        case .ready: return String(localized: "перед выходом")
        case .leaving: return String(localized: "к двери")
        case .away: return String(localized: "за дверью")
        case .breakTime: return String(localized: "осталось")
        case .finished: return String(localized: "готово")
        }
    }

    /// Outside: the plan of this exit. In a break: the next exit — the same lines as the readout.
    var subtitle: String {
        switch phase {
        case .ready, .leaving, .away:
            var parts = [String(localized: "План \(session.currentExit?.durationDescription ?? "")")]
            if session.attempt > 1 { parts.append(String(localized: "попытка \(session.attempt)")) }
            return parts.joined(separator: " · ")
        case .breakTime(_, _, _, let next):
            if let next {
                let exit = plan.exits[next]
                return session.attempt > 1
                    ? String(localized: "Следующий выход \(exit.number) — \(exit.durationDescription) · попытка \(session.attempt)")
                    : String(localized: "Следующий выход \(exit.number) — \(exit.durationDescription)")
            }
            return String(localized: "Выходы закончились: «Ещё выход» или «Завершить»")
        case .finished:
            return String(localized: "выходов \(session.completedExitsCount) из \(plan.exits.count) · фальстартов \(session.falseStartsCount)")
        }
    }

    var recordingText: String? {
        recordingSince.map { DurationText.clock(now.timeIntervalSince($0)) }
    }

    var sessionElapsed: String { DurationText.clock(now.timeIntervalSince(session.startedAt)) }

    /// When the first exit started: the plan's start on the timeline. Before it, now — the plan slides along until
    /// the first «Вышли» (the wait before the first exit says nothing).
    var planStart: Date {
        if let first = session.results.first { return first.leftAt ?? first.startedAt }
        switch phase {
        case .leaving(_, let since): return since
        case .away(_, _, let leftAt): return leftAt
        default: return now
        }
    }

    /// How far the session is from the plan laid out from the first exit (+ behind, − ahead): when the current exit
    /// started, or — in a break — when the next one can start at the earliest.
    var drift: TimeInterval? {
        guard let index = session.currentExitIndex, index <= plan.exits.count else { return nil }
        var planned: TimeInterval = 0
        for i in 0..<index { planned += plan.exits[i].duration + plan.breakAfter(exitAt: i) }
        let actual: Date
        switch phase {
        case .leaving(_, let since): actual = since
        case .away(_, _, let leftAt): actual = leftAt
        case .breakTime(_, let since, let duration, _): actual = max(now, since.addingTimeInterval(duration))
        default: actual = now
        }
        return actual.timeIntervalSince(planStart) - planned
    }

    /// Rough finish time: what is left of the plan from now.
    var eta: Date {
        guard let index = session.currentExitIndex else { return now }
        var left: TimeInterval = max(0, remaining ?? 0)
        for i in index..<plan.exits.count {
            if i > index || isBreak || isReady { left += plan.exits[i].duration }
            if i < plan.exits.count - 1 { left += plan.breakAfter(exitAt: i) }
        }
        return now.addingTimeInterval(left)
    }

    struct Action {
        let title: String
        let icon: StepIcon.Kind
        var tint: Color? = nil
    }

    /// The next step (Space): «Вышли», «Вернулись», or «Завершить» in the last break.
    var primary: Action? {
        switch phase {
        case .away: return Action(title: String(localized: "Вернулись"), icon: .backInside, tint: MacPalette.blue)
        case .breakTime(_, _, _, nil): return Action(title: String(localized: "Завершить"), icon: .symbol("flag.checkered"))
        case .ready, .leaving, .breakTime: return Action(title: String(localized: "Вышли"), icon: .outside)
        case .finished: return nil
        }
    }

    // MARK: - Plan rows

    enum RowState: Equatable { case done, current, upcoming }

    struct Row: Identifiable {
        let id: UUID
        let index: Int
        let exit: PlannedExit
        let state: RowState
        /// Successful attempt, if any.
        let result: ExitResult?
        let falseStarts: Int
        let breakAfter: TimeInterval
        let ownBreak: Bool
        let isLast: Bool
        /// Break right after this exit is running now.
        let breakActive: Bool
    }

    var rows: [Row] {
        let current = session.currentExitIndex
        var breakAfterIndex: Int? = nil
        if case .breakTime(let after, _, _, _) = phase { breakAfterIndex = after }
        return plan.exits.enumerated().map { index, exit in
            let attempts = session.results.filter { $0.number == exit.number }
            let ok = attempts.first { !$0.falseStart }
            let state: RowState
            if let current {
                state = index < current ? .done : (index == current ? (ok != nil ? .done : .current) : .upcoming)
            } else {
                state = .done
            }
            return Row(id: exit.id, index: index, exit: exit, state: state, result: ok,
                       falseStarts: attempts.filter(\.falseStart).count,
                       breakAfter: plan.breakAfter(exitAt: index), ownBreak: exit.breakAfter != nil,
                       isLast: index == plan.exits.count - 1, breakActive: breakAfterIndex == index)
        }
    }

    // MARK: - Log

    struct LogLine: Identifiable {
        let id: UUID
        let time: String
        let title: String
        let detail: String?
        let symbol: String
        let tint: Color
    }

    var log: [LogLine] {
        session.events.map { event in
            let (symbol, tint): (String, Color) = switch event.kind {
            case .sessionStarted: ("play.circle", .secondary)
            case .exitStarted: ("figure.walk", MacPalette.pink)
            case .behindDoor: ("door.left.hand.closed", MacPalette.pink)
            case .exitEnded: ("checkmark.circle.fill", MacPalette.green)
            case .falseStart: ("arrow.uturn.backward.circle.fill", MacPalette.orange)
            case .breakStarted, .breakEnded: ("pause.circle", MacPalette.blue)
            case .recordingStarted, .recordingStopped: ("record.circle", MacPalette.red)
            case .sessionFinished: ("flag.checkered", MacPalette.green)
            case .note: ("text.bubble", .secondary)
            }
            var title = event.kind.title
            if let n = event.exitNumber, [.exitStarted, .behindDoor, .exitEnded, .falseStart].contains(event.kind) {
                if let a = event.attempt, a > 1 {
                    title = String(localized: "\(event.kind.title) · выход \(n), попытка \(a)")
                } else {
                    title = String(localized: "\(event.kind.title) · выход \(n)")
                }
            }
            return LogLine(id: event.id, time: MacFormat.timeSeconds.string(from: event.time), title: title,
                           detail: event.kind == .recordingStarted ? nil : event.detail, symbol: symbol, tint: tint)
        }
    }
}
#endif
