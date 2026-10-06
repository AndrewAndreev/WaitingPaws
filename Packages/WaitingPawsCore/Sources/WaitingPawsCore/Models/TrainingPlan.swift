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

    /// Human readable planned duration, e.g. "30 с или до вставания" / "30 s or until the dog stands".
    public var durationDescription: String {
        var text = DurationText.short(duration)
        if untilStanding { text += " " + Self.untilStandingText }
        return text
    }

    /// "или до вставания": come back as soon as the dog stands up.
    public static var untilStandingText: String { tr("или до вставания", "or until the dog stands") }
}

/// A parsed (and possibly hand-corrected) training schedule.
public struct TrainingPlan: Codable, Equatable, Hashable, Identifiable {
    public static let defaultBreakDuration: TimeInterval = 120
    /// Title of a schedule without a header line.
    public static var defaultTitle: String { tr("Тренировка", "Training") }

    public var id: UUID
    public var title: String
    public var trainers: String
    public var date: Date?
    public var notes: [String]
    public var defaultBreak: TimeInterval
    public var exits: [PlannedExit]
    public var rawText: String

    public init(id: UUID = UUID(),
                title: String = TrainingPlan.defaultTitle,
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

    /// How long after the dog stands up to come back on an "или до вставания" exit, from a schedule note such as
    /// "🟡 Если встала - входим через 15 секунд от вставания". `nil`: come back right away.
    public var standingDelay: TimeInterval? {
        for note in notes {
            let lower = note.lowercased()
            guard lower.contains("встал") || lower.contains("встав") || lower.contains("stand") else { continue }
            // The time after the last "через" / "in" ("входим через 15 секунд", "come back in 15 seconds"), else the line's.
            var tail = Substring(note)
            if let range = note.range(of: "через ", options: [.caseInsensitive, .backwards])
                ?? note.range(of: " in ", options: [.caseInsensitive, .backwards]) {
                tail = note[range.upperBound...]
            }
            if let delay = DurationText.sumOfUnits(in: String(tail)), delay > 0 { return delay }
        }
        return nil
    }

    /// What an edit changed, for the session log: "перерывы 2 мин → 3 мин", "выход 4: 45 с → 1 мин",
    /// "перерыв после выхода 5: 2 мин → 5 мин", "добавлен выход 6 — 30 с", "убран выход 7". Exits are matched by id.
    public func changes(from old: TrainingPlan) -> [String] {
        var changes: [String] = []
        if defaultBreak != old.defaultBreak {
            changes.append(tr("перерывы \(DurationText.short(old.defaultBreak)) → \(DurationText.short(defaultBreak))",
                              "breaks \(DurationText.short(old.defaultBreak)) → \(DurationText.short(defaultBreak))"))
        }
        for (index, exit) in exits.enumerated() {
            guard let oldIndex = old.exits.firstIndex(where: { $0.id == exit.id }) else {
                changes.append(tr("добавлен выход \(exit.number) — \(exit.durationDescription)",
                                  "exit \(exit.number) added — \(exit.durationDescription)"))
                continue
            }
            let was = old.exits[oldIndex]
            if was.duration != exit.duration || was.untilStanding != exit.untilStanding {
                changes.append(tr("выход \(exit.number): \(was.durationDescription) → \(exit.durationDescription)",
                                  "exit \(exit.number): \(was.durationDescription) → \(exit.durationDescription)"))
            }
            // Own breaks only: a new common break is already said above.
            let before = old.breakAfter(exitAt: oldIndex), after = breakAfter(exitAt: index)
            if (was.breakAfter != nil || exit.breakAfter != nil), before != after, index < exits.count - 1 {
                changes.append(tr("перерыв после выхода \(exit.number): \(DurationText.short(before)) → \(DurationText.short(after))",
                                  "break after exit \(exit.number): \(DurationText.short(before)) → \(DurationText.short(after))"))
            }
        }
        for exit in old.exits where !exits.contains(where: { $0.id == exit.id }) {
            changes.append(tr("убран выход \(exit.number)", "exit \(exit.number) removed"))
        }
        return changes
    }

    /// What to do on an "или до вставания" exit: "собака встала — сразу возвращайтесь" or, with a note about it,
    /// "собака встала — возвращайтесь через 15 с".
    public var standingRule: String {
        if let delay = standingDelay {
            return tr("собака встала — возвращайтесь через \(DurationText.short(delay))",
                      "the dog stands up — come back in \(DurationText.short(delay))")
        }
        return tr("собака встала — сразу возвращайтесь", "the dog stands up — come back right away")
    }

    /// Rewrites exit numbers to 1…n in order.
    public mutating func renumber() {
        for index in exits.indices { exits[index].number = index + 1 }
    }

    /// Short label used in lists, e.g. "05.10.2026 · Тренировка на понедельник".
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if let date {
            return "\(Self.dateFormatter.string(from: date)) · \(trimmed)"
        }
        return trimmed
    }

    /// The schedule's date: "05.10.2026" / "10/5/2026".
    public static var dateFormatter: DateFormatter {
        CoreLanguage.current == .ru ? ruDateFormatter : enDateFormatter
    }
    private static let ruDateFormatter = CoreLanguage.ru.dateFormatter("ddMMyyyy")
    private static let enDateFormatter = CoreLanguage.en.dateFormatter("ddMMyyyy")
}
