import Foundation

/// When to come back before the planned time, from a line such as «🟡 Если встала и пошла - входим через 2 минуты от
/// начала движения, когда сняла фокус внимания с двери» or «🟢 Если легла - входим через 30 секунд от укладки».
public struct EarlyEntry: Codable, Equatable, Hashable, Identifiable {
    /// The trainer's mark in front of the line.
    public enum Tone: String, Codable, CaseIterable {
        case yellow, green, plain
    }

    public var id: UUID
    /// What the dog does: «Встала и пошла», «Легла».
    public var event: String
    /// How long after it to come back; `nil` — right away.
    public var delay: TimeInterval?
    /// The rest of the trainer's sentence: «от начала движения, когда сняла фокус внимания с двери…», «от укладки».
    public var detail: String?
    public var tone: Tone

    public init(id: UUID = UUID(), event: String, delay: TimeInterval? = nil, detail: String? = nil, tone: Tone = .plain) {
        self.id = id
        self.event = event
        self.delay = delay
        self.detail = detail
        self.tone = tone
    }

    /// «через 2 мин» / «сразу» / «через пару минут» (`unreadDelay`).
    public var delayDescription: String {
        guard let delay, delay > 0 else { return unreadDelay ?? tr("сразу", "right away") }
        return tr("через \(DurationText.short(delay))", "in \(DurationText.short(delay))")
    }

    /// «встала и пошла → 2:00», «легла → 0:30», «встала → сразу»: the short form for summaries.
    public var summary: String {
        let name = event.prefix(1).lowercased() + event.dropFirst()
        guard let delay, delay > 0 else { return "\(name) → " + (unreadDelay ?? tr("сразу", "right away")) }
        return "\(name) → \(DurationText.clock(delay))"
    }

    /// «через пару минут», "after she settles": the trainer's words for a time the parser couldn't read, which lead
    /// the detail. Such a condition is not «сразу». `nil` when the time is known or there is none.
    public var unreadDelay: String? {
        unreadDelayParts?.words
    }

    /// The detail to show beside the time: without `unreadDelay`, which the time shows already («через пару минут»
    /// there, «от начала движения, когда отойдёт» here). `nil` when nothing is left. The stored detail keeps the
    /// words for older builds.
    public var detailBesideTime: String? {
        guard let parts = unreadDelayParts else { return detail }
        let rest = parts.rest.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:.-–—")))
        return rest.isEmpty ? nil : rest
    }

    /// The detail split after `unreadDelay`.
    private var unreadDelayParts: (words: String, rest: Substring)? {
        guard delay == nil, let detail else { return nil }
        let range = NSRange(detail.startIndex..., in: detail)
        guard let match = Self.unreadDelayRegex.firstMatch(in: detail, range: range),
              let words = Range(match.range, in: detail) else { return nil }
        return (String(detail[words]), detail[words.upperBound...])
    }

    /// `PlanParser`'s «через», «спустя», "after", "in" (only as in "in a couple of minutes", "in several minutes",
    /// "in 15 breaths", not "in the kitchen"), up to the end of the part of the sentence or to where it says from
    /// what: «через пару минут | от начала движения», "in a few minutes | after she lies down".
    private static let unreadDelayRegex = try! NSRegularExpression(
        pattern: #"^(?:через|спустя|after|in(?=\s+(?:an?|several|few|couple|some|[0-9]+)\b))\s+(?:(?!\s(?:от|после|когда|from|after|when)\b)[^,;:])*[^,;:\s.]"#,
        options: [.caseInsensitive])

    /// The condition is about the dog standing up («встала», «встала и пошла», "stands up").
    public var isStandingUp: Bool {
        let lower = event.lowercased()
        return lower.contains("встал") || lower.contains("встав") || lower.contains("stand") || lower.contains("got up")
    }

    /// The same condition with a new id (a copy for one exit of the plan's common conditions).
    public func copy() -> EarlyEntry {
        EarlyEntry(event: event, delay: delay, detail: detail, tone: tone)
    }

    /// «Сразу»: no time to wait, and no trainer's words for one (`unreadDelay`).
    public var isRightAway: Bool {
        (delay ?? 0) <= 0 && unreadDelay == nil
    }

    /// «Встала → сразу»: come back as soon as the dog stands up, what «ИЛИ до вставания» says.
    public var isUntilStanding: Bool { isStandingUp && isRightAway }

    /// «Встала → сразу»: an exit's «ИЛИ до вставания» as a condition of its own (`TrainingPlan.foldUntilStanding`).
    public static var untilStanding: EarlyEntry {
        EarlyEntry(event: tr("Встала", "Stands up"))
    }
}

/// One planned exit from the apartment.
public struct PlannedExit: Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    /// 1-based number as written in the schedule.
    public var number: Int
    /// Planned time behind the door, in seconds.
    public var duration: TimeInterval
    /// «ИЛИ до вставания» as the schedule or an older build says it. `TrainingPlan` turns it into the exit's own
    /// condition «Встала → сразу» and clears it (`foldUntilStanding`): what the exit does is in `earlyEntries`
    /// (`endsWhenStanding`). Still written, false, for the older builds that require the key.
    public var untilStanding: Bool
    /// The exit's own notes: a remark in parentheses («выйти и сразу вернуться»), the trainer's wording of the exit, the
    /// owner's own words.
    public var note: String?
    /// Explicit break after this exit. `nil` means the plan's default break.
    public var breakAfter: TimeInterval?
    /// What to do or take on the way out: «куртка», «взять ключи, звякнуть ими», «закрыть дверь на один оборот».
    public var triggers: [String]
    /// The exit's own conditions for coming back early (lines under the exit in the schedule).
    public var earlyEntries: [EarlyEntry]
    /// The plan's common conditions apply to this exit (when it has none of its own).
    public var usesCommonEarlyEntries: Bool
    /// An extra exit added after the schedule's last one: no planned time, its timer counts up.
    public var isOpen: Bool
    /// Which of the exits in the trainer's text this one is (0-based, in her order): its lines in
    /// `PlanParser.sourceLines` carry the same `exitIndex`, whatever number a reorder gives it. nil for an exit added
    /// by hand and for plans from builds before it.
    public var sourceIndex: Int?

    public init(id: UUID = UUID(),
                number: Int,
                duration: TimeInterval,
                untilStanding: Bool = false,
                note: String? = nil,
                breakAfter: TimeInterval? = nil,
                triggers: [String] = [],
                earlyEntries: [EarlyEntry] = [],
                usesCommonEarlyEntries: Bool = true,
                isOpen: Bool = false,
                sourceIndex: Int? = nil) {
        self.id = id
        self.number = number
        self.duration = duration
        self.untilStanding = untilStanding
        self.note = note
        self.breakAfter = breakAfter
        self.triggers = triggers
        self.earlyEntries = earlyEntries
        self.usesCommonEarlyEntries = usesCommonEarlyEntries
        self.isOpen = isOpen
        self.sourceIndex = sourceIndex
    }

    private enum CodingKeys: String, CodingKey {
        case id, number, duration, untilStanding, note, breakAfter, triggers, earlyEntries, usesCommonEarlyEntries, isOpen
        case sourceIndex
    }

    /// Plans from builds before triggers and conditions decode with none of their own.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        number = try container.decode(Int.self, forKey: .number)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        untilStanding = try container.decode(Bool.self, forKey: .untilStanding)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        breakAfter = try container.decodeIfPresent(TimeInterval.self, forKey: .breakAfter)
        triggers = try container.decodeIfPresent([String].self, forKey: .triggers) ?? []
        earlyEntries = try container.decodeIfPresent([EarlyEntry].self, forKey: .earlyEntries) ?? []
        usesCommonEarlyEntries = try container.decodeIfPresent(Bool.self, forKey: .usesCommonEarlyEntries) ?? true
        isOpen = try container.decodeIfPresent(Bool.self, forKey: .isOpen) ?? false
        sourceIndex = try container.decodeIfPresent(Int.self, forKey: .sourceIndex)
    }

    /// The extra exit «Ещё выход» starts after the schedule's last one.
    public static func open(number: Int) -> PlannedExit {
        PlannedExit(number: number, duration: 0, isOpen: true)
    }

    /// The exit's own conditions say to come back as soon as the dog stands up («Встала → сразу»): «… или до
    /// вставания» after its time, the * in the history.
    public var endsWhenStanding: Bool {
        untilStanding || earlyEntries.contains(where: \.isUntilStanding)
    }

    /// «45 секунд + куртка + ключ ИЛИ до вставания»: the «ИЛИ до вставания» after the last trigger is the exit's
    /// (`untilStanding`), not a part of the trigger «ключ». Older builds kept the trigger «ключ ИЛИ до вставания»;
    /// `TrainingPlan.foldUntilStanding` takes it out of their plans too.
    mutating func takeUntilStandingOutOfTriggers() {
        var found = false
        triggers = triggers.compactMap { trigger in
            guard let before = PlanParser.triggerBeforeUntilStanding(trigger) else { return trigger }
            found = true
            return before.isEmpty ? nil : before
        }
        if found { untilStanding = true }
    }

    /// Human readable planned duration, e.g. "30 с или до вставания" / "30 s or until the dog stands".
    public var durationDescription: String {
        if isOpen { return Self.openText }
        var text = DurationText.short(duration)
        if endsWhenStanding { text += " " + Self.untilStandingText }
        return text
    }

    /// The note with something in it.
    public var noteText: String? {
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
        return note
    }

    /// "или до вставания": come back as soon as the dog stands up.
    public static var untilStandingText: String { tr("или до вставания", "or until the dog stands") }

    /// An extra exit's time: «без времени».
    public static var openText: String { tr("без времени", "no set time") }
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
    /// Conditions for coming back early written once for the whole training (after or before the exits).
    public var commonEarlyEntries: [EarlyEntry]

    public init(id: UUID = UUID(),
                title: String = TrainingPlan.defaultTitle,
                trainers: String = "",
                date: Date? = nil,
                notes: [String] = [],
                defaultBreak: TimeInterval = TrainingPlan.defaultBreakDuration,
                exits: [PlannedExit] = [],
                rawText: String = "",
                commonEarlyEntries: [EarlyEntry] = []) {
        self.id = id
        self.title = title
        self.trainers = trainers
        self.date = date
        self.notes = notes
        self.defaultBreak = defaultBreak
        self.exits = exits
        self.rawText = rawText
        self.commonEarlyEntries = commonEarlyEntries
        foldUntilStanding()
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, trainers, date, notes, defaultBreak, exits, rawText, commonEarlyEntries
    }

    /// A plan from a build before conditions keeps «🟡 Если встала - входим через 15 секунд» among its notes: such
    /// notes become its common conditions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        trainers = try container.decode(String.self, forKey: .trainers)
        date = try container.decodeIfPresent(Date.self, forKey: .date)
        notes = try container.decode([String].self, forKey: .notes)
        defaultBreak = try container.decode(TimeInterval.self, forKey: .defaultBreak)
        exits = try container.decode([PlannedExit].self, forKey: .exits)
        rawText = try container.decode(String.self, forKey: .rawText)
        if let entries = try container.decodeIfPresent([EarlyEntry].self, forKey: .commonEarlyEntries) {
            commonEarlyEntries = entries
        } else {
            commonEarlyEntries = notes.compactMap { PlanParser.parseEarlyEntry($0) }
            notes.removeAll { PlanParser.parseEarlyEntry($0) != nil }
        }
        foldUntilStanding()
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

    // MARK: - Conditions for coming back early

    /// Conditions that apply to `exit`: its own, or the plan's common ones when it has none and they apply to it.
    public func earlyEntries(of exit: PlannedExit) -> [EarlyEntry] {
        exit.earlyEntries.isEmpty && exit.usesCommonEarlyEntries ? commonEarlyEntries : exit.earlyEntries
    }

    /// «ИЛИ до вставания» of the schedule or of an older build becomes the exit's own «Встала → сразу»:
    /// - The lines under the exit keep the word when one of them is about standing up («встала и пошла → 1:00»
    ///   says what standing up means for this exit); otherwise «Встала → сразу» goes in front of them.
    /// - Over the training's common conditions the exit's word wins: it gets «Встала → сразу» and a copy of the common
    ///   ones without those about standing up («встала и пошла → 4:00» never comes after «встала → сразу»; the two
    ///   together were a contradiction on the screen). Common ones that already say «встала → сразу» stay common.
    public mutating func foldUntilStanding() {
        for index in exits.indices {
            exits[index].takeUntilStandingOutOfTriggers()
        }
        for index in exits.indices where exits[index].untilStanding {
            exits[index].untilStanding = false
            let exit = exits[index]
            if !exit.earlyEntries.isEmpty {
                if !exit.earlyEntries.contains(where: \.isStandingUp) {
                    exits[index].earlyEntries.insert(.untilStanding, at: 0)
                }
                continue
            }
            let common = exit.usesCommonEarlyEntries ? commonEarlyEntries : []
            if common.contains(where: \.isUntilStanding) { continue }
            exits[index].earlyEntries = [.untilStanding] + common.filter { !$0.isStandingUp }.map { $0.copy() }
            exits[index].usesCommonEarlyEntries = false
        }
    }

    /// The exit may end before its planned time — the 🏃 on its chip in the exit strip: a condition that comes sooner
    /// than the plan does («встала → сразу»; «встала → 4:00» on an 8-minute exit, while on a 15-second one it never
    /// comes). A time the parser couldn't read counts; an extra exit without a plan takes any condition.
    public func canEndEarly(_ exit: PlannedExit) -> Bool {
        earlyEntries(of: exit).contains { entry in
            guard let delay = entry.delay, !exit.isOpen else { return true }
            return delay < exit.duration
        }
    }

    /// `exit` shows the plan's common conditions (none of its own).
    public func usesCommonEarlyEntries(_ exit: PlannedExit) -> Bool {
        exit.earlyEntries.isEmpty && exit.usesCommonEarlyEntries && !commonEarlyEntries.isEmpty
    }

    /// Which exits get the common conditions: all of them or those of at least a minute. Exits with their own
    /// conditions keep them.
    public enum CommonEntriesScope: String, Codable, CaseIterable {
        case all, long

        /// «К длинным»: an exit this long or longer.
        public static let longExit: TimeInterval = 60

        /// «Ещё выход» has no planned time: its timer counts up, so it is a long one.
        func includes(_ exit: PlannedExit) -> Bool {
            self == .all || exit.isOpen || exit.duration >= Self.longExit
        }
    }

    /// The scope the exits now follow; `nil` when they were picked one by one. When both fit (no exit under a minute
    /// follows the common conditions or not), «к длинным»: the parser's default, and an exit added later keeps it.
    public var commonEntriesScope: CommonEntriesScope? {
        let candidates = exits.filter(\.earlyEntries.isEmpty)
        return [CommonEntriesScope.long, .all].first { scope in
            candidates.allSatisfy { $0.usesCommonEarlyEntries == scope.includes($0) }
        }
    }

    /// This plan, an edit of `old`, with the exits still following `old`'s scope: a new exit or one with a new time
    /// gets the common conditions as «ко всем» / «к длинным» says (a 45-second exit stretched to 2 minutes gets them
    /// under «к длинным»). The switches flipped one by one stay, and under «Выбрать» nothing changes.
    public func keepingCommonEntriesScope(from old: TrainingPlan) -> TrainingPlan {
        guard let scope = old.commonEntriesScope else { return self }
        let durations = Dictionary(old.exits.map { ($0.id, $0.duration) }, uniquingKeysWith: { first, _ in first })
        var plan = self
        for index in plan.exits.indices where plan.exits[index].earlyEntries.isEmpty
            && durations[plan.exits[index].id] != plan.exits[index].duration {
            plan.exits[index].usesCommonEarlyEntries = scope.includes(plan.exits[index])
        }
        return plan
    }

    public mutating func applyCommonEarlyEntries(to scope: CommonEntriesScope) {
        for index in exits.indices where exits[index].earlyEntries.isEmpty {
            exits[index].usesCommonEarlyEntries = scope.includes(exits[index])
        }
    }

    /// Turns the common conditions `exit` shows into its own, so they can be changed for this exit alone.
    public mutating func detachEarlyEntries(ofExitAt index: Int) {
        guard exits.indices.contains(index), usesCommonEarlyEntries(exits[index]) else { return }
        exits[index].earlyEntries = commonEarlyEntries.map { $0.copy() }
        exits[index].usesCommonEarlyEntries = false
    }

    // MARK: - Rules for the whole training

    /// «🚩 Если залаяла, завыла - ни в коем случае не входить, ждём…»: when NOT to come in.
    public struct Rule: Equatable, Hashable {
        /// «Залаяла, завыла».
        public var title: String
        /// «ни в коем случае не входить, ждём когда станет чуть спокойнее…».
        public var detail: String
        public var text: String
    }

    /// «🔖 Фальстарт: если пошла к двери в первые 20 секунд длинного выхода…»: how long into an exit a return still
    /// counts as a false start. `nil` when the schedule doesn't say (the button stays the whole exit).
    public var falseStartWindow: TimeInterval? {
        for note in notes where PlanParser.isFalseStartRule(PlanParser.stripDecorations(note).lowercased()) {
            let range = NSRange(note.startIndex..., in: note)
            guard let match = Self.firstSecondsRegex.firstMatch(in: note, range: range),
                  let timeRange = Range(match.range(at: 1), in: note),
                  let window = DurationText.sumOfUnits(in: String(note[timeRange])), window > 0 else { continue }
            return window
        }
        return nil
    }

    /// «в первые 20 секунд», «в течение первых 30 секунд», "in the first 20 seconds".
    private static let firstSecondsRegex = try! NSRegularExpression(
        pattern: #"(?:перв\p{L}*|first)\s+(\d+(?:[.,]\d+)?\s*\p{L}+)"#, options: [.caseInsensitive])

    /// The note that says when not to come in: the trainer's 🚩 (the parser keeps it on the note), else the first
    /// note whose words say so.
    public var doNotEnterRule: Rule? {
        guard let note = notes.first(where: { PlanParser.hasMark($0, "🚩") }) ?? notes.first(where: PlanParser.isDoNotEnterRule)
        else { return nil }
        let (title, detail) = PlanParser.splitCondition(note)
        return Rule(title: title ?? tr("Не входить", "Do not come in"), detail: detail, text: note)
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
            // «или до вставания» is a condition now: «ранний вход» below says it changed.
            if was.duration != exit.duration {
                changes.append(tr("выход \(exit.number): \(was.durationDescription) → \(exit.durationDescription)",
                                  "exit \(exit.number): \(was.durationDescription) → \(exit.durationDescription)"))
            }
            if was.triggers != exit.triggers {
                changes.append(tr("выход \(exit.number): триггеры", "exit \(exit.number): triggers"))
            }
            if old.earlyEntries(of: was) != earlyEntries(of: exit) {
                changes.append(tr("выход \(exit.number): ранний вход", "exit \(exit.number): coming back early"))
            }
            if was.noteText != exit.noteText {
                changes.append(tr("выход \(exit.number): заметка", "exit \(exit.number): note"))
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
