import Foundation

public enum SessionEventKind: String, Codable, CaseIterable {
    case sessionStarted
    case exitStarted
    case behindDoor
    case exitEnded
    case falseStart
    case breakStarted
    case breakEnded
    case recordingStarted
    case recordingStopped
    case sessionFinished
    case note

    public var title: String {
        switch self {
        case .sessionStarted: return tr("Тренировка начата", "Training started")
        case .exitStarted: return tr("Пошли к двери", "Walking to the door")
        case .behindDoor: return tr("За дверью", "Outside")
        case .exitEnded: return tr("Вернулись", "Back inside")
        case .falseStart: return tr("Фальстарт / сброс", "False start / reset")
        case .breakStarted: return tr("Перерыв", "Break")
        case .breakEnded: return tr("Перерыв окончен", "Break over")
        case .recordingStarted: return tr("Запись включена", "Recording started")
        case .recordingStopped: return tr("Запись остановлена", "Recording stopped")
        case .sessionFinished: return tr("Тренировка завершена", "Training finished")
        case .note: return tr("Заметка", "Note")
        }
    }
}

/// A single timestamped button press (or automatic transition) during a session.
public struct SessionEvent: Codable, Equatable, Identifiable {
    public var id: UUID
    public var time: Date
    public var kind: SessionEventKind
    public var exitNumber: Int?
    public var attempt: Int?
    public var detail: String?
    /// A `.note` the owner marked from behind the door («легла», «залаяла», «замолчала»): the log puts it on its
    /// exit's line. Absent in older records (and ignored by older builds).
    public var observed: Bool?

    public init(id: UUID = UUID(), time: Date, kind: SessionEventKind, exitNumber: Int? = nil, attempt: Int? = nil,
                detail: String? = nil, observed: Bool? = nil) {
        self.id = id
        self.time = time
        self.kind = kind
        self.exitNumber = exitNumber
        self.attempt = attempt
        self.detail = detail
        self.observed = observed
    }
}

/// Outcome of one attempt of one exit.
public struct ExitResult: Codable, Equatable, Identifiable {
    public var id: UUID
    public var number: Int
    public var attempt: Int
    public var plannedDuration: TimeInterval
    public var untilStanding: Bool
    public var startedAt: Date
    public var leftAt: Date?
    public var endedAt: Date
    public var falseStart: Bool
    public var plannedBreak: TimeInterval
    public var actualBreak: TimeInterval?
    /// An extra exit without a planned time (after the schedule's last one).
    public var isOpen: Bool

    public init(id: UUID = UUID(), number: Int, attempt: Int, plannedDuration: TimeInterval, untilStanding: Bool,
                startedAt: Date, leftAt: Date?, endedAt: Date, falseStart: Bool, plannedBreak: TimeInterval, actualBreak: TimeInterval? = nil,
                isOpen: Bool = false) {
        self.id = id
        self.number = number
        self.attempt = attempt
        self.plannedDuration = plannedDuration
        self.untilStanding = untilStanding
        self.startedAt = startedAt
        self.leftAt = leftAt
        self.endedAt = endedAt
        self.falseStart = falseStart
        self.plannedBreak = plannedBreak
        self.actualBreak = actualBreak
        self.isOpen = isOpen
    }

    private enum CodingKeys: String, CodingKey {
        case id, number, attempt, plannedDuration, untilStanding, startedAt, leftAt, endedAt, falseStart, plannedBreak,
             actualBreak, isOpen
    }

    /// Results of builds before extra exits decode as planned ones.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        number = try container.decode(Int.self, forKey: .number)
        attempt = try container.decode(Int.self, forKey: .attempt)
        plannedDuration = try container.decode(TimeInterval.self, forKey: .plannedDuration)
        untilStanding = try container.decode(Bool.self, forKey: .untilStanding)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        leftAt = try container.decodeIfPresent(Date.self, forKey: .leftAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        falseStart = try container.decode(Bool.self, forKey: .falseStart)
        plannedBreak = try container.decode(TimeInterval.self, forKey: .plannedBreak)
        actualBreak = try container.decodeIfPresent(TimeInterval.self, forKey: .actualBreak)
        isOpen = try container.decodeIfPresent(Bool.self, forKey: .isOpen) ?? false
    }

    /// Time actually spent behind the door ("За дверью" → "Вернулись").
    public var awayDuration: TimeInterval {
        guard let leftAt else { return 0 }
        return endedAt.timeIntervalSince(leftAt)
    }

    /// Whole exit from "Начать выход" to "Вернулись".
    public var totalDuration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

/// Everything worth keeping after a session: the plan, the log and the recording file name.
public struct TrainingRecord: Codable, Equatable, Identifiable {
    public var id: UUID
    public var plan: TrainingPlan
    public var startedAt: Date
    public var finishedAt: Date
    public var events: [SessionEvent]
    public var results: [ExitResult]
    public var recordingFileName: String?

    public init(id: UUID = UUID(), plan: TrainingPlan, startedAt: Date, finishedAt: Date,
                events: [SessionEvent], results: [ExitResult], recordingFileName: String? = nil) {
        self.id = id
        self.plan = plan
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.events = events
        self.results = results
        self.recordingFileName = recordingFileName
    }

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
    public var completedExits: Int { results.filter { !$0.falseStart }.count }
    public var falseStarts: Int { results.filter { $0.falseStart }.count }

    /// Longest successful stay behind the door (false starts don't count).
    public var longestStayBehindDoor: TimeInterval {
        results.filter { !$0.falseStart }.map(\.awayDuration).max() ?? 0
    }

    /// Longest exit in the trainer's plan.
    public var longestPlannedExit: TimeInterval { plan.exits.map(\.duration).max() ?? 0 }

    /// The successful exit that lasted longest behind the door: next to its time goes its own plan («2:32 · план
    /// 2:30»), not the longest one of the schedule.
    public var longestResult: ExitResult? {
        results.filter { !$0.falseStart }.max { $0.awayDuration < $1.awayDuration }
    }
}

/// Renders a record as a short plain-text report, one line per exit in the trainer's own notation
/// (in the app's language, `CoreLanguage.current`):
///
///     Тренировка на пятницу · Марк
///     25.09.2026, 18:00–18:41 (41 мин) · выходов 9 из 9 · фальстартов 1
///
///     1 выход — 2 с: за дверью 0:03 ✅ · перерыв после 2:10
///     2 выход — 5 с: фальстарт, за дверью 0:01 ❌ · перерыв после 1:00 (план 5 мин)
///     2 выход — 5 с, попытка 2: за дверью 0:06 ✅ · перерыв после 5:05 (план 5 мин)
///
///     Exit 2 — 5 s, attempt 2: outside 0:06 ✅ · break after: 5:05 (plan 5 min)
///
/// Every press is still kept in `TrainingRecord.events` (JSON); the text leaves out what the exit lines already say.
public enum SessionLogFormatter {
    public static func text(for record: TrainingRecord) -> String {
        var lines: [String] = []
        let title = record.plan.title.trimmingCharacters(in: .whitespaces)
        lines.append(record.plan.trainers.isEmpty ? title : "\(title) · \(record.plan.trainers)")

        let day = Self.day, time = Self.time
        var summary = "\(day.string(from: record.startedAt)), \(time.string(from: record.startedAt))–\(time.string(from: record.finishedAt))"
        summary += " (\(DurationText.short(record.duration)))"
        summary += tr(" · выходов \(record.completedExits) из \(record.plan.exits.count)",
                      " · exits \(record.completedExits) of \(record.plan.exits.count)")
        if record.falseStarts > 0 { summary += tr(" · фальстартов \(record.falseStarts)", " · false starts \(record.falseStarts)") }
        lines.append(summary)
        lines.append("")

        for (index, result) in record.results.enumerated() {
            var line = "\(exitName(result.number)) — "
                + (result.isOpen ? PlannedExit.openText : DurationText.short(result.plannedDuration))
            if result.untilStanding { line += " " + PlannedExit.untilStandingText }
            if result.attempt > 1 { line += tr(", попытка \(result.attempt)", ", attempt \(result.attempt)") }
            line += ": \(outcome(of: result)) \(result.falseStart ? "❌" : "✅")"
            let seen = observations(of: result, in: record)
            if !seen.isEmpty { line += " · " + seen.joined(separator: ", ") }
            // The break after the last exit only ends the session.
            if index < record.results.count - 1, let text = breakText(for: result, in: record) { line += " · \(text)" }
            lines.append(line)
        }

        let notes = record.events.filter { $0.kind == .note && $0.observed != true && !($0.detail ?? "").isEmpty }
        if !notes.isEmpty {
            lines.append("")
            for note in notes {
                let exit = note.exitNumber.map { tr(" (выход \($0))", " (exit \($0))") } ?? ""
                lines.append("\(time.string(from: note.time))\(exit): \(note.detail ?? "")")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// What the owner marked during this attempt, as moments from behind the door: «легла на 0:20», «залаяла на
    /// 0:35», «замолчала на 0:41» / "lay down at 0:20" — «легла 0:20» read as «lay down for 20 s». One form for the
    /// log, the finish, the history and the Mac.
    public static func observations(of result: ExitResult, in record: TrainingRecord) -> [String] {
        let start = result.leftAt ?? result.startedAt
        return record.events
            .filter { $0.kind == .note && $0.observed == true && $0.exitNumber == result.number && $0.attempt == result.attempt }
            .compactMap { event in
                guard let text = event.detail, !text.isEmpty else { return nil }
                let moment = DurationText.clock(max(0, event.time.timeIntervalSince(start)))
                return tr("\(text) на \(moment)", "\(text) at \(moment)")
            }
    }

    /// "3 выход" / "Exit 3": how the trainer's schedule names an exit.
    public static func exitName(_ number: Int) -> String {
        tr("\(number) выход", "Exit \(number)")
    }

    /// "за дверью 0:03", "фальстарт, за дверью 0:01", "фальстарт до двери".
    public static func outcome(of result: ExitResult) -> String {
        let away = result.leftAt == nil ? nil : tr("за дверью \(DurationText.clock(result.awayDuration))",
                                                   "outside \(DurationText.clock(result.awayDuration))")
        if result.falseStart {
            return away.map { tr("фальстарт, \($0)", "false start, \($0)") } ?? tr("фальстарт до двери", "false start before the door")
        }
        return away ?? tr("не выходили за дверь", "didn't go outside")
    }

    /// "перерыв после 2:10" / "break after: 2:10": the break that followed the exit, said as the plan says it («После —
    /// перерыв 5 мин»; design council, round 10: «перерыв 2:02» on an exit's line didn't say where it was). Its plan
    /// goes next to it when the break was noticeably different from it — and, given the `record`, when it was the
    /// exit's own break, not the training's common one (the trainer's «Перерыв 5 минут» after exit 6), so the
    /// trainer checks her five minutes even when they were kept: «перерыв после 5:02 (план 5 мин)».
    public static func breakText(for result: ExitResult, in record: TrainingRecord? = nil) -> String? {
        guard let actual = result.actualBreak else { return nil }
        var text = tr("перерыв после \(DurationText.clock(actual))", "break after: \(DurationText.clock(actual))")
        let differs = abs(actual - result.plannedBreak) > 15
        let ownBreak = record.map { abs(result.plannedBreak - $0.plan.defaultBreak) >= 1 } ?? false
        if differs || ownBreak {
            text += tr(" (план \(DurationText.short(result.plannedBreak)))", " (plan \(DurationText.short(result.plannedBreak)))")
        }
        return text
    }

    /// "25.09.2026 18:00:05" / "9/25/2026 6:00:05 PM" (the app's language and the device's region).
    public static var dateTime: DateFormatter { formatter("ddMMyyyy jmmss") }
    /// "18:00" / "6:00 PM".
    public static var time: DateFormatter { formatter("jmm") }
    static var day: DateFormatter { formatter("ddMMyyyy") }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    /// One formatter per template and language (the language only changes in tests).
    private static func formatter(_ template: String) -> DateFormatter {
        let key = "\(CoreLanguage.current.rawValue)|\(template)"
        return cacheLock.withLock {
            if let cached = cache[key] { return cached }
            let formatter = CoreLanguage.current.dateFormatter(template)
            cache[key] = formatter
            return formatter
        }
    }
}
