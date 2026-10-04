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

    var tint: Color {
        if overdue { return MacPalette.orange }
        if isBreak { return MacPalette.blue }
        if isFinished { return MacPalette.green }
        return MacPalette.pink
    }

    /// Big readout: countdown, or elapsed time on the way to the door.
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

    var timerCaption: String {
        switch phase {
        case .ready: return "план"
        case .leaving: return "к двери"
        case .away: return overdue ? "сверх плана" : "до конца выхода"
        case .breakTime(_, _, _, let next):
            if let next { return "до выхода \(plan.exits[next].number)" }
            return "до конца"
        case .finished: return "всего"
        }
    }

    var title: String {
        switch phase {
        case .ready, .leaving, .away: return "Выход \(session.currentExit?.number ?? 0)"
        case .breakTime(_, _, _, let next): return next == nil ? "Последний перерыв" : "Перерыв"
        case .finished: return "Тренировка завершена"
        }
    }

    /// "За дверью", "Идём к двери"…
    var phaseName: String {
        switch phase {
        case .ready: return "Готовы"
        case .leaving: return "Идём к двери"
        case .away: return "За дверью"
        case .breakTime: return "Перерыв"
        case .finished: return "Готово"
        }
    }

    var subtitle: String {
        switch phase {
        case .ready, .leaving, .away:
            var parts = [session.currentExit?.durationDescription ?? ""]
            if session.attempt > 1 { parts.append("попытка \(session.attempt)") }
            return parts.joined(separator: " · ")
        case .breakTime(_, _, let duration, let next):
            if let next { return "\(DurationText.short(duration)) · дальше выход \(plan.exits[next].number) — \(plan.exits[next].durationDescription)" }
            return DurationText.short(duration)
        case .finished:
            return "выходов \(session.completedExitsCount) из \(plan.exits.count) · фальстартов \(session.falseStartsCount)"
        }
    }

    var positionText: String {
        guard let index = session.currentExitIndex else { return "\(plan.exits.count) из \(plan.exits.count)" }
        return "\(index + 1) из \(plan.exits.count)"
    }

    var recordingText: String? {
        recordingSince.map { DurationText.clock(now.timeIntervalSince($0)) }
    }

    var sessionElapsed: String { DurationText.clock(now.timeIntervalSince(session.startedAt)) }

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
        let symbol: String
        let key: String
        var role: ButtonRole? = nil
        var tint: Color? = nil
    }

    /// Main button for this phase (Space).
    var primary: Action? {
        switch phase {
        case .ready: return Action(title: "Начать выход \(session.currentExit?.number ?? 1)", symbol: "figure.walk", key: "Пробел")
        case .leaving: return Action(title: "За дверью", symbol: "door.left.hand.closed", key: "Пробел")
        case .away: return Action(title: "Вернулись", symbol: "checkmark", key: "Пробел", tint: MacPalette.green)
        case .breakTime(_, _, _, let next):
            if let next { return Action(title: "Начать выход \(plan.exits[next].number)", symbol: "figure.walk", key: "Пробел") }
            return Action(title: "Завершить", symbol: "flag.checkered", key: "Пробел")
        case .finished: return nil
        }
    }

    var secondary: [Action] {
        switch phase {
        case .leaving: return [Action(title: "Вернулись", symbol: "checkmark", key: "↩"),
                               Action(title: "Сброс", symbol: "arrow.uturn.backward", key: "⌫", role: .destructive)]
        case .away: return [Action(title: "Фальстарт", symbol: "arrow.uturn.backward", key: "⌫", role: .destructive)]
        case .breakTime: return [Action(title: "+1 мин", symbol: "plus", key: "⌘="),
                                 Action(title: "Завершить", symbol: "flag.checkered", key: "⌘.")]
        default: return []
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
                title += " · выход \(n)"
                if let a = event.attempt, a > 1 { title += ", попытка \(a)" }
            }
            return LogLine(id: event.id, time: MacFormat.timeSeconds.string(from: event.time), title: title,
                           detail: event.kind == .recordingStarted ? nil : event.detail, symbol: symbol, tint: tint)
        }
    }
}
#endif
