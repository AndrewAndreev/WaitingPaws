import Foundation

/// Parses the free-form training schedule text sent by the trainer, in Russian or English.
///
/// Recognised lines:
/// - header: `🐹 Тренировка на понедельник - Таня/Андрей - 05.10.2026`, `Monday training - Anna - 10/05/2026`
/// - exit:   `3 выход - 5 секунд`, `5 выход - 30 секунд ИЛИ до вставания`, `1 выход - 0 секунд (выйти и сразу вернуться)`,
///           `Exit 3 - 5 seconds`, `Exit 5 - 30 seconds OR until the dog stands up`
/// - break:  `Перерыв 5 минут`, `Break 5 minutes` (applies to the preceding exit)
/// - default break inside the notes: `➡️ Все перерывы 2 минуты`, `All breaks 2 minutes`
/// - anything else becomes a note.
public enum PlanParser {
    public static func parse(_ text: String) -> TrainingPlan {
        var plan = TrainingPlan(rawText: text)
        var exits: [PlannedExit] = []
        var notes: [String] = []
        var defaultFromText = false

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for (index, rawLine) in lines.enumerated() {
            let line = stripDecorations(rawLine)
            if line.isEmpty { continue }

            if let exit = parseExit(line) {
                exits.append(exit)
                continue
            }

            let lower = line.lowercased()

            if isExitBreak(lower), !exits.isEmpty, let duration = DurationText.sumOfUnits(in: line) {
                exits[exits.count - 1].breakAfter = duration
                continue
            }

            if mentionsBreak(lower), let duration = DurationText.sumOfUnits(in: line) {
                plan.defaultBreak = duration
                defaultFromText = true
                notes.append(line)
                continue
            }

            if index == 0 {
                parseHeader(line, into: &plan)
                continue
            }

            notes.append(line)
        }

        plan.exits = exits
        plan.notes = notes
        normalizeBreaks(&plan, defaultFromText: defaultFromText)
        return plan
    }

    /// "Перерыв 5 минут" / "Break 5 minutes" right after an exit: that exit's own break.
    public static func isExitBreak(_ lower: String) -> Bool {
        (lower.hasPrefix("перерыв") && !lower.hasPrefix("перерывы"))
            || ((lower.hasPrefix("break") || lower.hasPrefix("pause") || lower.hasPrefix("rest"))
                && !lower.hasPrefix("breaks") && !lower.hasPrefix("pauses"))
    }

    /// "Все перерывы 2 минуты", "All breaks 2 minutes": a line about breaks in general.
    public static func mentionsBreak(_ lower: String) -> Bool {
        lower.contains("перерыв") || lower.range(of: #"\b(break|breaks|pause|pauses)\b"#, options: .regularExpression) != nil
    }

    /// Keeps per-exit breaks only where they differ from the plan's break, so changing that one
    /// setting in the editor changes every ordinary break. Trainers often write "Перерыв 2 минуты"
    /// after every exit instead of "Все перерывы 2 минуты": without such a line, a break used after
    /// most exits becomes the plan's break.
    static func normalizeBreaks(_ plan: inout TrainingPlan, defaultFromText: Bool) {
        if !defaultFromText {
            let counts = Dictionary(plan.exits.compactMap(\.breakAfter).map { ($0, 1) }, uniquingKeysWith: +)
            if let common = counts.max(by: { $0.value < $1.value }), common.value * 2 > max(1, plan.exits.count - 1) {
                plan.defaultBreak = common.key
            }
        }
        for index in plan.exits.indices where plan.exits[index].breakAfter == plan.defaultBreak {
            plan.exits[index].breakAfter = nil
        }
    }

    // MARK: - Lines

    /// Removes leading emoji, bullets and arrows: "➡️ За 30 минут" → "За 30 минут".
    public static func stripDecorations(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        let stripped = decorationRegex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespaces)
    }

    public static func parseExit(_ line: String) -> PlannedExit? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = exitRegex.firstMatch(in: line, range: range) else { return nil }

        var number: Int?
        for group in [1, 2] {
            if let numberRange = Range(match.range(at: group), in: line), let value = Int(line[numberRange]) {
                number = value
            }
        }
        guard let number else { return nil }

        var rest = ""
        if let restRange = Range(match.range(at: 3), in: line) {
            rest = String(line[restRange])
        }

        var note: String?
        let restRange = NSRange(rest.startIndex..., in: rest)
        if let noteMatch = parenthesesRegex.firstMatch(in: rest, range: restRange),
           let noteRange = Range(noteMatch.range(at: 1), in: rest) {
            let candidate = rest[noteRange].trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty { note = candidate }
            rest = parenthesesRegex.stringByReplacingMatches(in: rest, range: restRange, withTemplate: "")
        }

        let lower = rest.lowercased()
        let untilStanding = lower.contains("до вставания") || lower.contains("пока не встанет")
            || (lower.contains("until") && lower.contains("stand"))

        let durationPart: String
        if let orRange = lower.range(of: #"(^|\s)(или|or)(\s|$)"#, options: .regularExpression) {
            durationPart = String(rest[rest.startIndex..<orRange.lowerBound])
        } else {
            durationPart = rest
        }
        let duration = DurationText.sumOfUnits(in: durationPart) ?? 0

        return PlannedExit(number: number, duration: duration, untilStanding: untilStanding, note: note)
    }

    static func parseHeader(_ line: String, into plan: inout TrainingPlan) {
        var text = line
        if let (date, dateRange) = extractDate(from: text) {
            plan.date = date
            text.removeSubrange(dateRange)
        }

        let normalized = text
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        let parts = normalized
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-"))) }
            .filter { !$0.isEmpty }

        plan.title = parts.first ?? TrainingPlan.defaultTitle
        plan.trainers = parts.dropFirst().joined(separator: " · ")
    }

    static func extractDate(from text: String) -> (Date, Range<String.Index>)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = dateRegex.firstMatch(in: text, range: range),
              let fullRange = Range(match.range, in: text),
              let dayRange = Range(match.range(at: 1), in: text),
              let monthRange = Range(match.range(at: 2), in: text),
              let yearRange = Range(match.range(at: 3), in: text),
              let first = Int(text[dayRange]),
              let second = Int(text[monthRange]),
              var year = Int(text[yearRange]) else { return nil }
        if year < 100 { year += 2000 }
        // 05.10.2026 (dots) is always day.month; with slashes an English schedule from the US means month/day.
        // A number above 12 settles it, otherwise the app language's region decides.
        let slashes = text[fullRange].contains("/")
        let monthFirst = first <= 12
            && (second > 12 || (slashes && CoreLanguage.current == .en && localeWritesMonthFirst))
        let day = monthFirst ? second : first
        let month = monthFirst ? first : second

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        guard let date = calendar.date(from: components) else { return nil }
        return (date, fullRange)
    }

    private static var localeWritesMonthFirst: Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "dMy", options: 0, locale: CoreLanguage.en.locale) ?? ""
        guard let m = format.firstIndex(of: "M"), let d = format.firstIndex(of: "d") else { return false }
        return m < d
    }

    // MARK: - Regular expressions

    private static let decorationRegex = try! NSRegularExpression(pattern: #"^[^\p{L}\p{N}(]+"#)

    /// "3 выход", "выход 3", "выход №3", "Exit 3", "3rd exit", "Departure #3", followed by the duration.
    private static let exitRegex = try! NSRegularExpression(
        pattern: #"^(?:(\d+)(?:st|nd|rd|th)?\s*[-–—.)]?\s*(?:выход|exit|departure)\p{L}*|(?:выход|exit|departure)\p{L}*\s*(?:№|#|no\.?)?\s*(\d+))\s*[-–—:]*\s*(.*)$"#,
        options: [.caseInsensitive]
    )

    private static let parenthesesRegex = try! NSRegularExpression(pattern: #"\(([^)]*)\)"#)

    private static let dateRegex = try! NSRegularExpression(pattern: #"(\d{1,2})[./-](\d{1,2})[./-](\d{4}|\d{2})"#)
}
