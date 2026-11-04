import Foundation

/// Parses the free-form training schedule text sent by the trainer, in Russian or English.
///
/// Recognised lines:
/// - header: `🐹 Тренировка на понедельник - Таня/Андрей - 05.10.2026`, `Monday training - Anna - 10/05/2026`
/// - exit:   `3 выход - 5 секунд`, `5 выход - 30 секунд ИЛИ до вставания`, `1 выход - 0 секунд (выйти и сразу вернуться)`,
///           `Exit 3 - 5 seconds`, `Exit 5 - 30 seconds OR until the dog stands up`
/// - break:  `Перерыв 5 минут`, `Break 5 minutes` (applies to the preceding exit)
/// - default break inside the notes: `➡️ Все перерывы 2 минуты`, `All breaks 2 minutes`
/// - a condition for coming back early: `🟡 Если встала и пошла - входим через 2 минуты от начала движения`,
///   `If she lies down - come back in 30 seconds`. Right under an exit (no blank line between) it is that exit's,
///   anywhere else it is common to the training.
/// - a line that goes on from an exit's conditions (no blank line between) and is none of these: the exit's own note
///   («🟡 Если встала за это время: …» under its 🟡/🟢); the rules against coming in and about false starts stay the
///   training's, and so does a line right under the exit line itself.
/// - anything else becomes a note.
public enum PlanParser {
    public static func parse(_ text: String) -> TrainingPlan {
        var plan = TrainingPlan(rawText: text)
        var exits: [PlannedExit] = []
        var notes: [String] = []
        var common: [EarlyEntry] = []
        var defaultFromText = false
        /// The exit the next condition belongs to: the last one, while no blank line has come after it.
        var attachedExit: Int?
        /// The lines under `attachedExit` have reached its conditions: what follows them is the exit's too.
        var inConditions = false
        var contentIndex = 0

        for rawLine in lines(of: text) {
            if rawLine.isEmpty {
                attachedExit = nil
                continue
            }
            let line = stripDecorations(rawLine)
            if line.isEmpty { continue }
            defer { contentIndex += 1 }

            if let exit = parseExit(line) {
                exits.append(exit)
                attachedExit = exits.count - 1
                inConditions = false
                continue
            }

            let lower = line.lowercased()

            if isExitBreak(lower), !exits.isEmpty, let duration = DurationText.sumOfUnits(in: line) {
                exits[exits.count - 1].breakAfter = duration
                continue
            }

            if let entry = parseEarlyEntry(rawLine) {
                if let attachedExit {
                    exits[attachedExit].earlyEntries.append(entry)
                    exits[attachedExit].usesCommonEarlyEntries = false
                    inConditions = true
                } else {
                    common.append(entry)
                }
                continue
            }

            if let attachedExit, inConditions, isExitNote(rawLine) {
                exits[attachedExit].note = [exits[attachedExit].noteText, line].compactMap { $0 }.joined(separator: "\n")
                continue
            }
            attachedExit = nil
            // A 🚩 rule keeps its flag: `TrainingPlan.doNotEnterRule` knows it by the flag when its words don't say
            // «не входить».
            let note = hasMark(rawLine, "🚩") ? "🚩 " + line : line

            if let duration = commonBreak(in: line) {
                // The first line that names it: «Все перерывы 2 минуты» comes with the opening points.
                if !defaultFromText {
                    plan.defaultBreak = duration
                    defaultFromText = true
                }
                notes.append(note)
                continue
            }

            if contentIndex == 0 {
                parseHeader(line, into: &plan)
                continue
            }

            notes.append(note)
        }

        plan.exits = exits
        plan.notes = notes
        plan.commonEarlyEntries = common
        // The training's common conditions go to the exits of a minute and longer: on a short exit «легла → 1:00» or
        // «встала и пошла → 3:00» never comes. Before the fold, so a short «ИЛИ до вставания» gets no copy of them.
        plan.applyCommonEarlyEntries(to: .long)
        plan.foldUntilStanding()
        normalizeBreaks(&plan, defaultFromText: defaultFromText)
        return plan
    }

    /// Trimmed lines, with blank ones kept (they end an exit's block). A line that runs into the next point without a
    /// line break («…поздно вечером➡️ За 30 минут…») is split there. A Windows line end (\r\n) is one break, not a
    /// line and a blank one.
    static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).flatMap { line -> [String] in
            let range = NSRange(line.startIndex..., in: line)
            return inlineBulletRegex.stringByReplacingMatches(in: line, range: range, withTemplate: "\n$1")
                .components(separatedBy: "\n")
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Conditions

    /// «🟡 Если встала и пошла - входим через 2 минуты от начала движения, когда сняла фокус внимания с двери»,
    /// «🟢 Если легла - входим через 30 секунд от укладки», "If she lies down — come back in 30 seconds". A rule about
    /// not coming in («🚩 Если залаяла - ни в коем случае не заходите…») is not one.
    public static func parseEarlyEntry(_ rawLine: String) -> EarlyEntry? {
        let line = stripDecorations(rawLine)
        let lower = line.lowercased()
        // The raw line: its 🚩 says «не входить» even when the words say «заходите».
        guard lower.hasPrefix("если ") || lower.hasPrefix("if "), !isDoNotEnterRule(rawLine) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let verb = comeBackRegex.firstMatch(in: line, range: range), let verbRange = Range(verb.range, in: line)
        else { return nil }

        let (event, _) = splitCondition(String(line[..<verbRange.lowerBound]))
        guard let event, !event.isEmpty else { return nil }

        var tail = String(line[verbRange.upperBound...])
        var delay: TimeInterval?
        let tailRange = NSRange(tail.startIndex..., in: tail)
        if let after = afterRegex.firstMatch(in: tail, range: tailRange), let afterRange = Range(after.range, in: tail) {
            // The time right after «через» / "in", up to the end of its part of the sentence («через 1,5 минуты» is
            // one part).
            let rest = String(tail[afterRange.upperBound...])
            let clauseEnd = clauseEndRegex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest))
                .flatMap { Range($0.range, in: rest)?.lowerBound } ?? rest.endIndex
            let clause = String(rest[..<clauseEnd])
            if case let (time, end)? = delayTime(atStartOf: clause) {
                delay = time
                tail = String(clause[end...]) + String(rest[clauseEnd...])
            } else {
                // «через пару минут» is not «сразу»: the words lead the detail (`EarlyEntry.unreadDelay`).
                tail = String(tail[afterRange.lowerBound...])
            }
        } else if let now = rightAwayRegex.firstMatch(in: tail, range: tailRange), let nowRange = Range(now.range, in: tail) {
            tail = String(tail[nowRange.upperBound...])
        }
        let detail = tail.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:.-–—")))

        let tone: EarlyEntry.Tone = hasMark(rawLine, "🟡") || hasMark(rawLine, "🟠") ? .yellow
            : hasMark(rawLine, "🟢") ? .green : .plain
        return EarlyEntry(event: event, delay: delay, detail: detail.isEmpty ? nil : detail, tone: tone)
    }

    /// The time `clause` (what follows «через» / "in") starts with, and where it ends: «2 минуты», «1 мин 30 сек»,
    /// «0,5 минуты», and in words «минуту», «полминуты», «две минуты», "a minute", "half a minute".
    static func delayTime(atStartOf clause: String) -> (TimeInterval, String.Index)? {
        let range = NSRange(clause.startIndex..., in: clause)
        if let match = spelledDurationRegex.firstMatch(in: clause, range: range),
           var end = Range(match.range, in: clause)?.upperBound, let unit = Range(match.range(at: 2), in: clause) {
            // No number: the one after the unit («через секунд 30», «через минут пять»), else one («через минуту»).
            // An unknown word («через пару минут»): no time.
            var count: Double = 1
            if let words = Range(match.range(at: 1), in: clause) {
                guard let word = clause[words].lowercased().split(whereSeparator: \.isWhitespace).first,
                      let value = numberWords[String(word)] else { return nil }
                count = value
            } else if let after = countAfterUnitRegex.firstMatch(in: clause, range: NSRange(end..., in: clause)),
                      let number = Range(after.range, in: clause) {
                let digits = Range(after.range(at: 1), in: clause).map { clause[$0].replacingOccurrences(of: ",", with: ".") }
                let word = Range(after.range(at: 2), in: clause).map { clause[$0].lowercased() }
                if let value = digits.flatMap({ Double($0) }) ?? word.flatMap({ numberWords[$0] }) {
                    count = value
                    end = number.upperBound
                }
            }
            // The count times one unit, not "\(count) секунд": a huge count prints as "1e+30", read as 30. No more
            // than `sumOfUnits` takes.
            guard let unitTime = DurationText.sumOfUnits(in: "1 \(clause[unit])"),
                  count * unitTime <= DurationText.longestTyped else { return nil }
            return (count * unitTime, end)
        }
        guard let last = durationRegex.matches(in: clause, range: range).last,
              let end = Range(last.range, in: clause)?.upperBound,
              let time = DurationText.sumOfUnits(in: String(clause[..<end])) else { return nil }
        return (time, end)
    }

    /// «🚩 Если залаяла, завыла - ни в коем случае не входить, ждём…», «…не заходите», "If she barks — do not return".
    public static func isDoNotEnterRule(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return hasMark(line, "🚩") || doNotEnterRegex.firstMatch(in: line, range: range) != nil
    }

    /// The line starts with the trainer's `mark` («🟡», «🚩», «🔖»), also with a variation selector after it («🟡︎»):
    /// Swift takes the two for different characters, JavaScript for the same start.
    public static func hasMark(_ line: String, _ mark: String) -> Bool {
        let scalars = line.unicodeScalars.filter { $0.value != 0xFE0E && $0.value != 0xFE0F }
        return String(String.UnicodeScalarView(scalars)).hasPrefix(mark)
    }

    /// «Если залаяла, завыла - ни в коем случае не входить» → («Залаяла, завыла», «ни в коем случае не входить»):
    /// what the dog does (after «если», up to the dash) and the rest. No «если» at the start: no title.
    public static func splitCondition(_ line: String) -> (title: String?, detail: String) {
        let text = stripDecorations(line)
        let lower = text.lowercased()
        let prefix = lower.hasPrefix("если ") ? "если ".count : lower.hasPrefix("if ") ? "if ".count : 0
        guard prefix > 0 else { return (nil, text) }
        let body = text.dropFirst(prefix)
        let separator = [" - ", " – ", " — ", "- ", "— "].compactMap { body.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
            ?? body.range(of: ", ")
        let head = separator.map { body[..<$0.lowerBound] } ?? body
        let rest = separator.map { body[$0.upperBound...] } ?? ""
        let title = head.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:-–—")))
        let detail = rest.trimmingCharacters(in: .whitespaces)
        return (title.prefix(1).uppercased() + title.dropFirst(), detail)
    }

    // MARK: - The trainer's text, line by line

    /// One line of the trainer's text, for showing it during the training with the current exit marked.
    public struct SourceLine: Equatable, Identifiable {
        public enum Kind: Equatable {
            case blank, header, note, exit, earlyEntry, breakTime, doNotEnter, falseStart
        }

        /// 0-based line index.
        public let id: Int
        public let text: String
        public let kind: Kind
        /// The exit the line is about: the exit's own line, its conditions and break right under it.
        public let exitNumber: Int?
    }

    public static func sourceLines(_ text: String) -> [SourceLine] {
        var result: [SourceLine] = []
        var attachedExit: Int?
        var inConditions = false
        var contentIndex = 0
        var rows = lines(of: text)
        while rows.last?.isEmpty == true { rows.removeLast() }
        while rows.first?.isEmpty == true { rows.removeFirst() }
        for (index, rawLine) in rows.enumerated() {
            if rawLine.isEmpty {
                attachedExit = nil
                result.append(SourceLine(id: index, text: "", kind: .blank, exitNumber: nil))
                continue
            }
            let line = stripDecorations(rawLine)
            // A lone «➡️» is no line of the schedule for `parse`: not the header, and an exit's lines go on past it.
            if line.isEmpty {
                result.append(SourceLine(id: index, text: rawLine, kind: .note, exitNumber: attachedExit))
                continue
            }
            defer { contentIndex += 1 }
            let lower = line.lowercased()
            var kind: SourceLine.Kind = .note
            var number: Int?
            if let exit = parseExit(line) {
                kind = .exit
                number = exit.number
                attachedExit = exit.number
                inConditions = false
            } else if isExitBreak(lower), attachedExit != nil, DurationText.sumOfUnits(in: line) != nil {
                kind = .breakTime
                number = attachedExit
            } else if parseEarlyEntry(rawLine) != nil {
                kind = .earlyEntry
                number = attachedExit
                inConditions = attachedExit != nil
            } else if attachedExit != nil, inConditions, isExitNote(rawLine) {
                number = attachedExit
            } else {
                attachedExit = nil
                if contentIndex == 0 {
                    kind = .header
                } else if isDoNotEnterRule(rawLine) {
                    kind = .doNotEnter
                } else if hasMark(rawLine, "🔖") || isFalseStartRule(lower) {
                    kind = .falseStart
                }
            }
            result.append(SourceLine(id: index, text: rawLine, kind: kind, exitNumber: number))
        }
        return result
    }

    /// "Перерыв 5 минут" / "Break 5 minutes" right after an exit: that exit's own break.
    public static func isExitBreak(_ lower: String) -> Bool {
        (lower.hasPrefix("перерыв") && !lower.hasPrefix("перерывы"))
            || ((lower.hasPrefix("break") || lower.hasPrefix("pause") || lower.hasPrefix("rest"))
                && !lower.hasPrefix("breaks") && !lower.hasPrefix("pauses"))
    }

    /// "Все перерывы 2 минуты", "Перерывы между выходами — 2 минуты", "All breaks 2 minutes", "2 minute breaks":
    /// the break of every exit. The time has to belong to the word: a few words after it or right before it,
    /// in the same part of the sentence. A note that mentions breaks next to some other time says nothing about
    /// them, and neither does the false-start rule: «Фальстарт: если пошла к двери в первые 20 секунд …, через
    /// обычный перерыв …» once made every break 20 s. «После перерыва» says when, not how long, and a time behind an
    /// exit is the exit's: «далее после перерыва делаем выход на 15 секунд» once made every break 15 s.
    public static func commonBreak(in line: String) -> TimeInterval? {
        if isFalseStartRule(stripDecorations(line).lowercased()) { return nil }
        for clause in clauses(of: line) {
            let range = NSRange(clause.startIndex..., in: clause)
            guard let match = breakWordRegex.firstMatch(in: clause, range: range),
                  let word = Range(match.range, in: clause) else { continue }
            let lastWordBefore = clause[..<word.lowerBound].split(whereSeparator: { !$0.isLetter }).last?.lowercased()
            if let lastWordBefore, timePrepositions.contains(lastWordBefore) { continue }
            let after = clause[word.upperBound...]
            if let digit = after.firstIndex(where: \.isWholeNumber),
               case let words = after[..<digit].split(whereSeparator: { !$0.isLetter }).map({ $0.lowercased() }), words.count <= 4,
               // «между выходами» is the break's place; «выход на 15 секунд» is the exit's time.
               words.contains("между") || words.contains("between")
                || !words.contains(where: { exitWordRegex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }),
               let duration = DurationText.sumOfUnits(in: String(after)) {
                return duration
            }
            let before = String(clause[..<word.lowerBound])
            if let adjacent = durationBeforeWordRegex.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)),
               let adjacentRange = Range(adjacent.range, in: before),
               let duration = DurationText.sumOfUnits(in: before[adjacentRange].replacingOccurrences(of: "-", with: " ")) {
                return duration
            }
        }
        return nil
    }

    /// A line under an exit that belongs to it: not a rule of the whole training (🚩, 🔖) and not about the breaks.
    static func isExitNote(_ rawLine: String) -> Bool {
        let line = stripDecorations(rawLine)
        return !isDoNotEnterRule(rawLine) && !hasMark(rawLine, "🔖") && !isFalseStartRule(line.lowercased())
            && commonBreak(in: line) == nil
    }

    /// «Фальстарт: …», "False start: …" (lowercased, decorations stripped).
    public static func isFalseStartRule(_ lower: String) -> Bool {
        lower.hasPrefix("фальстарт") || lower.hasPrefix("false start")
    }

    /// Parts of a sentence: split at commas and semicolons, and at the end of a sentence («выход. Если»), but not
    /// inside «1,5 минуты» or «1 мин. 30 сек».
    static func clauses(of line: String) -> [String] {
        let range = NSRange(line.startIndex..., in: line)
        return clauseBreakRegex.stringByReplacingMatches(in: line, range: range, withTemplate: "\n")
            .components(separatedBy: "\n")
    }

    /// Keeps per-exit breaks only where they differ from the plan's break, so changing that one
    /// setting in the editor changes every ordinary break. Trainers often write "Перерыв 2 минуты"
    /// after every exit instead of "Все перерывы 2 минуты": without such a line, a break used after
    /// most exits becomes the plan's break.
    static func normalizeBreaks(_ plan: inout TrainingPlan, defaultFromText: Bool) {
        if !defaultFromText {
            let breaks = plan.exits.compactMap(\.breakAfter)
            let counts = Dictionary(breaks.map { ($0, 1) }, uniquingKeysWith: +)
            // On a tie the break written first wins (a Dictionary's order changes from launch to launch).
            if let most = counts.values.max(), let common = breaks.first(where: { counts[$0] == most }),
               most * 2 > max(1, plan.exits.count - 1) {
                plan.defaultBreak = common
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

        // «10 секунд + куртка + взять ключи, звякнуть ими»: what follows a plus sign is a trigger.
        var parts = rest.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        rest = parts.removeFirst()
        var triggers = parts.filter { !$0.isEmpty }

        let lower = rest.lowercased()
        let untilStanding = saysUntilStanding(lower)

        let durationPart: String
        if let orRange = lower.range(of: #"(^|\s)(или|or)(\s|$)"#, options: .regularExpression) {
            durationPart = String(rest[rest.startIndex..<orRange.lowerBound])
        } else {
            durationPart = rest
        }
        let duration = DurationText.sumOfUnits(in: durationPart) ?? 0

        // «выйти, закрыть дверь на один оборот, подождать 10 секунд и вернуться»: a sentence instead of a time. What
        // is done before the waiting is a trigger, the sentence itself stays as the exit's note.
        if let first = rest.first, !first.isNumber, rest.contains(",") {
            let clauses = rest.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if let timed = clauses.firstIndex(where: { DurationText.sumOfUnits(in: $0) != nil }) {
                let actions = clauses[..<timed].filter { clause in
                    let range = NSRange(clause.startIndex..., in: clause)
                    return !clause.isEmpty && goingOutRegex.firstMatch(in: clause, range: range) == nil
                }
                triggers.insert(contentsOf: actions, at: 0)
                note = [rest, note].compactMap { $0 }.joined(separator: " · ")
            }
        }

        var exit = PlannedExit(number: number, duration: duration, untilStanding: untilStanding, note: note, triggers: triggers)
        exit.takeUntilStandingOutOfTriggers()
        return exit
    }

    /// «до вставания», «пока не встанет», "until the dog stands up" (lowercased).
    static func saysUntilStanding(_ lower: String) -> Bool {
        lower.contains("до вставания") || lower.contains("пока не встанет")
            || (lower.contains("until") && lower.contains("stand"))
    }

    /// «ключ ИЛИ до вставания» → «ключ», "keys or until the dog stands up" → "keys": the exit's «ИЛИ до вставания»
    /// written after its last trigger («45 секунд + куртка + ключ ИЛИ до вставания») is not a part of the trigger.
    /// `nil` when the trigger has no such tail; «ключ или телефон» stays one trigger.
    static func triggerBeforeUntilStanding(_ trigger: String) -> String? {
        let range = NSRange(trigger.startIndex..., in: trigger)
        // The last «или» that the standing up follows: «ключ или телефон ИЛИ до вставания» → «ключ или телефон».
        for match in orRegex.matches(in: trigger, range: range).reversed() {
            guard let orRange = Range(match.range, in: trigger),
                  saysUntilStanding(trigger[orRange.upperBound...].lowercased()) else { continue }
            return trigger[..<orRange.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        return nil
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

    /// «ИЛИ», "or" between words.
    private static let orRegex = try! NSRegularExpression(pattern: #"(?:^|\s)(?:или|or)\s+"#, options: [.caseInsensitive])

    /// «выйти», «выходим», «выйти из квартиры», "go out", "leave": the exit itself, not a trigger.
    private static let goingOutRegex = try! NSRegularExpression(
        pattern: #"^(?:выйти|выходим|выйдите|выход)(?:\s+(?:из|за)\s+\p{L}+)?$|^(?:go out|leave|step out)(?:\s+\p{L}+)?$"#,
        options: [.caseInsensitive])

    /// A bullet in the middle of a line: «…поздно вечером➡️ За 30 минут…».
    private static let inlineBulletRegex = try! NSRegularExpression(pattern: #"(?<=\S)\s*(➡️|➡|🔖|🚩|🟡|🟢)"#)

    /// «входим», «заходим», «возвращаемся», "come back", "come in", "go back", "return".
    private static let comeBackRegex = try! NSRegularExpression(
        pattern: #"\b(?:входим|заходим|возвращаемся|возвращайтесь|входите|заходите|come back|come in|go back|go in|return)\b"#,
        options: [.caseInsensitive])

    /// «через», "in", "after" in front of the delay.
    private static let afterRegex = try! NSRegularExpression(pattern: #"\b(?:через|спустя|in|after)\s+"#, options: [.caseInsensitive])

    private static let rightAwayRegex = try! NSRegularExpression(
        pattern: #"\b(?:сразу|немедленно|right away|immediately|at once)\b"#, options: [.caseInsensitive])

    /// «не входить», «не заходите», «нельзя возвращаться», "do not come in", "don’t return", "never enter": the verbs
    /// of `comeBackRegex` with a «не» in front, as an infinitive or a call to do it. Not «не заходя в комнату», «не
    /// входя резко» or "don’t enter the bedroom": that says how to come in, not whether.
    private static let doNotEnterRegex = try! NSRegularExpression(
        pattern: #"\b(?:не|нельзя)\s+(?:входи(?:ть|м|те)?|заходи(?:ть|м|те)?|возвраща(?:ться|емся|йтесь|йся))\b|(?:\b(?:not|never|cannot|dont)|n['’]t)\s+(?:(?:come|go)\s+(?:in|back|inside)|return|enter\b(?!\s+the\s+(?!(?:house|flat|apartment|home)\b)\p{L}))\b"#,
        options: [.caseInsensitive])

    /// Where the time after «через» ends: a comma (not the one in «1,5»), a semicolon or a colon.
    private static let clauseEndRegex = try! NSRegularExpression(pattern: #"[;:]|(?<!\d),|,(?!\d)"#)

    /// "<number> <unit>" (`DurationText`'s units).
    private static let durationRegex = try! NSRegularExpression(
        pattern: #"\d+(?:[.,]\d+)?\s*(?:час\p{L}*|hour\p{L}*|hr\p{L}*|мин\p{L}*|min\p{L}*|сек\p{L}*|sec\p{L}*|ч|h|м|m|с|s)(?![\p{L}])"#,
        options: [.caseInsensitive])

    /// A time in words at the start: «минуту», «полминуты», «полторы минуты», «две минуты», "an hour", "half a minute"
    /// (the number is looked up in `numberWords`).
    private static let spelledDurationRegex = try! NSRegularExpression(
        pattern: #"^(?:(half\s+an?|\p{L}+)\s*-?\s*)?(час(?:а|ов)?|минут\p{L}*|секунд\p{L}*|hours?|hrs?|minutes?|mins?|seconds?|secs?)(?!\p{L})"#,
        options: [.caseInsensitive])

    /// The number right after a unit that has none: «через секунд 30», «через минут пять» (`numberWords`). Not one that
    /// starts a time of its own: «через минуту 30 секунд».
    private static let countAfterUnitRegex = try! NSRegularExpression(
        pattern: #"^\s+(?:(\d+(?:[.,]\d+)?)|(\p{L}+))(?![\p{L}\p{N}])(?!\s*(?:час|мин|сек|hour|hr|min|sec))"#,
        options: [.caseInsensitive])

    private static let numberWords: [String: Double] = [
        "один": 1, "одна": 1, "одну": 1, "два": 2, "две": 2, "три": 3, "четыре": 4, "пять": 5, "шесть": 6, "семь": 7,
        "восемь": 8, "девять": 9, "десять": 10, "пятнадцать": 15, "двадцать": 20, "тридцать": 30,
        "пол": 0.5, "полторы": 1.5, "полтора": 1.5,
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "half": 0.5,
    ]

    /// «после перерыва», «через перерыв», "after the break": when, not how long.
    private static let timePrepositions: Set<String> = ["после", "через", "до", "перед", "after", "before", "following"]

    /// «выход», «выхода», "exit", "departure": a time behind it is the exit's.
    private static let exitWordRegex = try! NSRegularExpression(pattern: #"^(?:выход\p{L}*|exit\p{L}*|departure\p{L}*)$"#,
                                                                options: [.caseInsensitive])

    private static let breakWordRegex = try! NSRegularExpression(
        pattern: #"перерыв\p{L}*|\b(?:break|breaks|pause|pauses)\b"#, options: [.caseInsensitive])

    /// "2 minute " / "2-minute " / «2 минуты » right before the break word.
    private static let durationBeforeWordRegex = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?[\s-]*\p{L}+[\s-]*$"#)

    private static let clauseBreakRegex = try! NSRegularExpression(pattern: #"[.!?…](?=\s+[^\s\d]|\s*$)|[,;](?=\s)"#)

    private static let dateRegex = try! NSRegularExpression(pattern: #"(\d{1,2})[./-](\d{1,2})[./-](\d{4}|\d{2})"#)
}
