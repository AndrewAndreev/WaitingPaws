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
        case .sessionStarted: return "Тренировка начата"
        case .exitStarted: return "Пошли к двери"
        case .behindDoor: return "За дверью"
        case .exitEnded: return "Вернулись"
        case .falseStart: return "Фальстарт / сброс"
        case .breakStarted: return "Перерыв"
        case .breakEnded: return "Перерыв окончен"
        case .recordingStarted: return "Запись включена"
        case .recordingStopped: return "Запись остановлена"
        case .sessionFinished: return "Тренировка завершена"
        case .note: return "Заметка"
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

    public init(id: UUID = UUID(), time: Date, kind: SessionEventKind, exitNumber: Int? = nil, attempt: Int? = nil, detail: String? = nil) {
        self.id = id
        self.time = time
        self.kind = kind
        self.exitNumber = exitNumber
        self.attempt = attempt
        self.detail = detail
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

    public init(id: UUID = UUID(), number: Int, attempt: Int, plannedDuration: TimeInterval, untilStanding: Bool,
                startedAt: Date, leftAt: Date?, endedAt: Date, falseStart: Bool, plannedBreak: TimeInterval, actualBreak: TimeInterval? = nil) {
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
}

/// Renders a record as a short plain-text report, one line per exit in the trainer's own notation:
///
///     Тренировка на пятницу · Андрей
///     25.09.2026, 18:00–18:41 (41 мин) · выходов 9 из 9 · фальстартов 1
///
///     1 выход — 2 с: за дверью 0:03 ✅ · перерыв 2:10
///     2 выход — 5 с: фальстарт, за дверью 0:01 ❌ · перерыв 1:00 (план 5 мин)
///     2 выход — 5 с, попытка 2: за дверью 0:06 ✅ · перерыв 5:05
///
/// Every press is still kept in `TrainingRecord.events` (JSON); the text leaves out what the exit lines already say.
public enum SessionLogFormatter {
    public static func text(for record: TrainingRecord) -> String {
        var lines: [String] = []
        let title = record.plan.title.trimmingCharacters(in: .whitespaces)
        lines.append(record.plan.trainers.isEmpty ? title : "\(title) · \(record.plan.trainers)")

        var summary = "\(day.string(from: record.startedAt)), \(time.string(from: record.startedAt))–\(time.string(from: record.finishedAt))"
        summary += " (\(DurationText.short(record.duration)))"
        summary += " · выходов \(record.completedExits) из \(record.plan.exits.count)"
        if record.falseStarts > 0 { summary += " · фальстартов \(record.falseStarts)" }
        lines.append(summary)
        lines.append("")

        for (index, result) in record.results.enumerated() {
            var line = "\(result.number) выход — \(DurationText.short(result.plannedDuration))"
            if result.untilStanding { line += " или до вставания" }
            if result.attempt > 1 { line += ", попытка \(result.attempt)" }
            line += ": \(outcome(of: result)) \(result.falseStart ? "❌" : "✅")"
            // The break after the last exit only ends the session.
            if index < record.results.count - 1, let text = breakText(for: result) { line += " · \(text)" }
            lines.append(line)
        }

        let notes = record.events.filter { $0.kind == .note && !($0.detail ?? "").isEmpty }
        if !notes.isEmpty {
            lines.append("")
            for note in notes {
                let exit = note.exitNumber.map { " (выход \($0))" } ?? ""
                lines.append("\(time.string(from: note.time))\(exit): \(note.detail ?? "")")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// "за дверью 0:03", "фальстарт, за дверью 0:01", "фальстарт до двери".
    public static func outcome(of result: ExitResult) -> String {
        let away = result.leftAt == nil ? nil : "за дверью \(DurationText.clock(result.awayDuration))"
        if result.falseStart {
            return away.map { "фальстарт, \($0)" } ?? "фальстарт до двери"
        }
        return away ?? "не выходили за дверь"
    }

    /// "перерыв 2:10", with the plan only when the break was noticeably different from it.
    public static func breakText(for result: ExitResult) -> String? {
        guard let actual = result.actualBreak else { return nil }
        var text = "перерыв \(DurationText.clock(actual))"
        if abs(actual - result.plannedBreak) > 15 { text += " (план \(DurationText.short(result.plannedBreak)))" }
        return text
    }

    public static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return formatter
    }()

    public static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()
}
