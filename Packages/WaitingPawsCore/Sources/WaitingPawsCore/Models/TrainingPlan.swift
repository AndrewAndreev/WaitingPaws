import Foundation

/// One planned exit from the apartment.
public struct PlannedExit: Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    /// 1-based number as written in the schedule.
    public var number: Int
    /// Planned time behind the door, in seconds.
    public var duration: TimeInterval
    /// "ИЛИ до вставания" — come back as soon as the dog stands up.
    public var untilStanding: Bool
    /// Free-form remark, e.g. "выйти и сразу вернуться".
    public var note: String?
    /// Explicit break after this exit. `nil` means the plan's default break.
    public var breakAfter: TimeInterval?

    public init(id: UUID = UUID(),
                number: Int,
                duration: TimeInterval,
                untilStanding: Bool = false,
                note: String? = nil,
                breakAfter: TimeInterval? = nil) {
        self.id = id
        self.number = number
        self.duration = duration
        self.untilStanding = untilStanding
        self.note = note
        self.breakAfter = breakAfter
    }

    /// Human readable planned duration, e.g. "30 с ИЛИ до вставания".
    public var durationDescription: String {
        var text = DurationText.short(duration)
        if untilStanding { text += " или до вставания" }
        return text
    }
}

/// A parsed (and possibly hand-corrected) training schedule.
public struct TrainingPlan: Codable, Equatable, Hashable, Identifiable {
    public static let defaultBreakDuration: TimeInterval = 120

    public var id: UUID
    public var title: String
    public var trainers: String
    public var date: Date?
    public var notes: [String]
    public var defaultBreak: TimeInterval
    public var exits: [PlannedExit]
    public var rawText: String

    public init(id: UUID = UUID(),
                title: String = "Тренировка",
                trainers: String = "",
                date: Date? = nil,
                notes: [String] = [],
                defaultBreak: TimeInterval = TrainingPlan.defaultBreakDuration,
                exits: [PlannedExit] = [],
                rawText: String = "") {
        self.id = id
        self.title = title
        self.trainers = trainers
        self.date = date
        self.notes = notes
        self.defaultBreak = defaultBreak
        self.exits = exits
        self.rawText = rawText
    }

    /// Break that follows the exit at `index` (falls back to the default break).
    public func breakAfter(exitAt index: Int) -> TimeInterval {
        guard exits.indices.contains(index) else { return defaultBreak }
        return exits[index].breakAfter ?? defaultBreak
    }

    /// Sum of planned exits and the breaks between them (the last break is excluded).
    public var estimatedDuration: TimeInterval {
        guard !exits.isEmpty else { return 0 }
        var total: TimeInterval = 0
        for (index, exit) in exits.enumerated() {
            total += exit.duration
            if index < exits.count - 1 { total += breakAfter(exitAt: index) }
        }
        return total
    }

    public var isValid: Bool { !exits.isEmpty }

    /// Rewrites exit numbers to 1…n in order.
    public mutating func renumber() {
        for index in exits.indices { exits[index].number = index + 1 }
    }

    /// Short label used in lists and file names, e.g. "05.10.2026 · Тренировка на понедельник".
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if let date {
            return "\(Self.dateFormatter.string(from: date)) · \(trimmed)"
        }
        return trimmed
    }

    public static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()
}
