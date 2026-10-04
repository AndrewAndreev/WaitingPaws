#if os(macOS)
import SwiftUI
import WaitingPawsCore

// MARK: - Formatting

/// Plan wording shared by the review sheet and the plan timeline.
enum MacPlanFormat {
    /// "2 мин", "1:30" when minutes and seconds mix, "45 с".
    static func cell(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 && total % 60 != 0 ? DurationText.clock(seconds) : DurationText.short(seconds)
    }

    /// "≈ 28 мин" for summaries (seconds dropped from ten minutes up).
    static func approx(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 600 { return String(localized: "≈ \(Int((Double(total) / 60).rounded())) мин") }
        return "≈ " + DurationText.short(seconds)
    }

    /// "+0:30", "−1:00".
    static func signed(_ delta: TimeInterval) -> String {
        (delta < 0 ? "−" : "+") + DurationText.clock(abs(delta))
    }

    /// "1 выход", "5 выходов" / "1 exit", "5 exits".
    static func exits(_ n: Int) -> String { pluralText(n, ru: ("выход", "выхода", "выходов"), en: ("exit", "exits")) }
    /// "2 перерыва" / "2 breaks".
    static func breaks(_ n: Int) -> String { pluralText(n, ru: ("перерыв", "перерыва", "перерывов"), en: ("break", "breaks")) }
    /// "3 заметки" / "3 notes".
    static func notes(_ n: Int) -> String { pluralText(n, ru: ("заметка", "заметки", "заметок"), en: ("note", "notes")) }

    static func exitsTotal(_ plan: TrainingPlan) -> TimeInterval { plan.exits.reduce(0) { $0 + $1.duration } }
    static func breaksTotal(_ plan: TrainingPlan) -> TimeInterval { plan.estimatedDuration - exitsTotal(plan) }

    /// Seconds from the start of the training to the start of the exit at `index`.
    static func start(of index: Int, in plan: TrainingPlan) -> TimeInterval {
        var t: TimeInterval = 0
        for i in 0..<min(index, plan.exits.count) { t += plan.exits[i].duration + plan.breakAfter(exitAt: i) }
        return t
    }

    /// Exit durations offered in the editor (from «выйти и вернуться» to ten minutes).
    static let exitPresets: [TimeInterval] = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 300, 600]
    /// Breaks between exits.
    static let breakPresets: [TimeInterval] = [60, 90, 120, 180, 240, 300, 420, 600, 900]

    /// "Фальстарт: если пошла…" → "Если пошла…".
    static func ruleBody(_ text: String) -> String {
        let body = text.components(separatedBy: ":").dropFirst().joined(separator: ":")
            .trimmingCharacters(in: .whitespaces)
        let value = body.isEmpty ? text : body
        return value.prefix(1).uppercased() + value.dropFirst()
    }
}

/// Plan colours: pink exits, blue breaks, orange false-start rule (the app is dark; deeper tones keep
/// contrast if a light surface ever shows them).
enum MacPlanTint {
    static func exit(_ scheme: ColorScheme) -> Color { scheme == .dark ? MacPalette.pink : MacPalette.pinkDeep }
    static func pause(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? MacPalette.blue : Color(red: 0.16, green: 0.45, blue: 0.90)
    }
    static func rule(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? MacPalette.orange : Color(red: 0.86, green: 0.47, blue: 0.05)
    }
}

// MARK: - The trainer's text, line by line

/// One line of the pasted text and what `PlanParser` made of it. Classified with the parser's own
/// patterns (exit line, «Перерыв N» after an exit, a line about all breaks, the first line as the header),
/// plus the false-start rule («🔖 Фальстарт: …»), which the parser keeps as a note.
struct MacPlanTextLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case header
        /// `ordinal` — position among the exit lines = index of the exit in the parsed plan.
        case exit(number: Int, ordinal: Int)
        /// «Перерыв 5 минут» — own break of the exit on line `afterLine`.
        case ownBreak(afterLine: Int)
        /// «➡️ Все перерывы 2 минуты».
        case defaultBreak
        /// «🔖 Фальстарт: …».
        case rule
        case note
        case blank
    }

    /// 1-based line number.
    let id: Int
    let text: String
    let kind: Kind

    var isExit: Bool { if case .exit = kind { return true }; return false }
    var isBreak: Bool {
        switch kind {
        case .ownBreak, .defaultBreak: true
        default: false
        }
    }

    /// Lines marked in the gutter.
    var isRecognised: Bool {
        switch kind {
        case .exit, .ownBreak, .defaultBreak, .rule: true
        case .header, .note, .blank: false
        }
    }

    func tint(_ scheme: ColorScheme) -> Color {
        switch kind {
        case .exit: MacPlanTint.exit(scheme)
        case .ownBreak, .defaultBreak: MacPlanTint.pause(scheme)
        case .rule: MacPlanTint.rule(scheme)
        case .header, .note, .blank: .secondary
        }
    }

    // MARK: Classification

    static func classify(_ text: String) -> [MacPlanTextLine] {
        var result: [MacPlanTextLine] = []
        var contentIndex = 0
        var exitOrdinal = 0
        var lastExitLine: Int?
        var rows = text.components(separatedBy: .newlines)
        while rows.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { rows.removeLast() }
        for (index, raw) in rows.enumerated() {
            let id = index + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                result.append(MacPlanTextLine(id: id, text: "", kind: .blank))
                continue
            }
            defer { contentIndex += 1 }
            let stripped = stripDecorations(line)
            let lower = stripped.lowercased()
            let kind: Kind
            if stripped.isEmpty {
                kind = .note
            } else if let number = exitNumber(stripped) {
                kind = .exit(number: number, ordinal: exitOrdinal)
                exitOrdinal += 1
                lastExitLine = id
            } else if PlanParser.isExitBreak(lower), let lastExitLine, DurationText.sumOfUnits(in: stripped) != nil {
                kind = .ownBreak(afterLine: lastExitLine)
            } else if PlanParser.mentionsBreak(lower), DurationText.sumOfUnits(in: stripped) != nil {
                kind = .defaultBreak
            } else if contentIndex == 0 {
                kind = .header
            } else if isRule(line) {
                kind = .rule
            } else {
                kind = .note
            }
            result.append(MacPlanTextLine(id: id, text: line, kind: kind))
        }
        return result
    }

    /// «🔖 Фальстарт: …», «Фальстарт — …», "False start: …".
    static func isRule(_ line: String) -> Bool {
        let lower = stripDecorations(line).lowercased()
        return line.hasPrefix("🔖") || lower.hasPrefix("фальстарт") || lower.hasPrefix("false start")
    }

    /// `PlanParser.stripDecorations`: leading emoji, bullets and arrows.
    static func stripDecorations(_ line: String) -> String {
        PlanParser.stripDecorations(line)
    }

    /// `PlanParser.parseExit`: «3 выход - 5 секунд», «Выход №3 — 5 секунд», "Exit 3 - 5 seconds".
    static func exitNumber(_ line: String) -> Int? {
        PlanParser.parseExit(line)?.number
    }
    private static let durationRegex = try! NSRegularExpression(
        pattern: #"\d+(?:[.,]\d+)?\s*(?:час\p{L}*|мин\p{L}*|сек\p{L}*)"#, options: [.caseInsensitive])
    private static let exitLabelRegex = try! NSRegularExpression(
        pattern: #"\d+\s*[-–—.)]?\s*выход\p{L}*|выход\p{L}*\s*(?:№\s*)?\d+"#, options: [.caseInsensitive])
    private static let standingRegex = try! NSRegularExpression(
        pattern: #"или\s+до\s+вставания|пока\s+не\s+встанет"#, options: [.caseInsensitive])

    // MARK: Highlighting

    /// Monospaced text with durations of exits pink, breaks blue, the rule's head orange, notes dimmed.
    func attributed(scheme: ColorScheme, size: CGFloat = 12.5) -> AttributedString {
        enum Role { case plain, dim, label, duration, pause, flag, title, rule }
        var marks: [(NSRange, Role)] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var base: Role = .dim
        switch kind {
        case .blank:
            return AttributedString()
        case .note:
            base = .dim
        case .header:
            // «Название - Тренеры - Дата»: the parser splits on any dash between spaces.
            base = .plain
            let titleEnd = [" - ", " – ", " — "].map { ns.range(of: $0).location }.filter { $0 != NSNotFound }.min()
            marks.append((NSRange(location: 0, length: titleEnd ?? ns.length), .title))
        case .rule:
            base = .dim
            let colon = ns.range(of: ":")
            if colon.location != NSNotFound {
                marks.append((NSRange(location: 0, length: colon.location + 1), .rule))
            } else {
                base = .rule
            }
        case .exit:
            base = .dim
            if let label = Self.exitLabelRegex.firstMatch(in: text, range: full) { marks.append((label.range, .label)) }
            for match in Self.durationRegex.matches(in: text, range: full) { marks.append((match.range, .duration)) }
            if let flag = Self.standingRegex.firstMatch(in: text, range: full) { marks.append((flag.range, .flag)) }
        case .ownBreak, .defaultBreak:
            base = kind == .defaultBreak ? .dim : .pause
            for match in Self.durationRegex.matches(in: text, range: full) { marks.append((match.range, .pause)) }
        }
        marks.sort { $0.0.location < $1.0.location }

        var result = AttributedString()
        func append(_ range: NSRange, _ role: Role) {
            guard range.length > 0 else { return }
            var run = AttributedString(ns.substring(with: range))
            var weight: Font.Weight = .regular
            switch role {
            case .plain: run.foregroundColor = .primary
            case .dim: run.foregroundColor = .secondary
            case .label: run.foregroundColor = .primary; weight = .semibold
            case .duration: run.foregroundColor = MacPlanTint.exit(scheme); weight = .semibold
            case .pause: run.foregroundColor = MacPlanTint.pause(scheme); weight = .semibold
            case .flag: run.foregroundColor = MacPlanTint.exit(scheme).opacity(0.8)
            case .title: run.foregroundColor = .primary; weight = .bold
            case .rule: run.foregroundColor = MacPlanTint.rule(scheme); weight = .semibold
            }
            run.font = .system(size: size, weight: weight, design: .monospaced)
            result += run
        }
        var cursor = 0
        for (range, role) in marks where range.location >= cursor {
            append(NSRange(location: cursor, length: range.location - cursor), base)
            append(range, role)
            cursor = range.location + range.length
        }
        append(NSRange(location: cursor, length: ns.length - cursor), base)
        return result
    }
}

/// Which line of the trainer's text each exit came from. The parsed exits follow the exit lines in order;
/// the link is remembered per plan, so it survives reordering, deleting and re-opening the sheet.
/// Exits added by hand have no line.
@MainActor
enum MacPlanLineMap {
    private static var cache: [UUID: [UUID: Int]] = [:]

    static func lines(for plan: TrainingPlan, textLines: [MacPlanTextLine]) -> [UUID: Int] {
        if let known = cache[plan.id] { return known }
        let exitLines = textLines.filter(\.isExit)
        guard !exitLines.isEmpty else { return [:] }
        if exitLines.count == plan.exits.count {
            let map = Dictionary(uniqueKeysWithValues: zip(plan.exits.map(\.id), exitLines.map(\.id)))
            cache[plan.id] = map
            return map
        }
        // Edited before the first look: match by the number written in the text.
        var map: [UUID: Int] = [:]
        for exit in plan.exits {
            if let line = exitLines.first(where: { if case .exit(let number, _) = $0.kind { return number == exit.number }; return false }) {
                map[exit.id] = line.id
            }
        }
        return map
    }
}

// MARK: - Small pieces

/// The whole plan as one proportional bar: exits pink, breaks blue (own breaks brighter).
struct MacPlanMiniBar: View {
    let plan: TrainingPlan
    var height: CGFloat = 6
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let total = max(1, plan.estimatedDuration)
            let gaps = CGFloat(max(0, plan.exits.count * 2 - 2))
            let unit = max(0, geo.size.width - gaps) / total
            HStack(spacing: 1) {
                ForEach(Array(plan.exits.enumerated()), id: \.element.id) { index, exit in
                    Capsule().fill(MacPlanTint.exit(scheme))
                        .frame(width: max(2, exit.duration * unit))
                    if index < plan.exits.count - 1 {
                        Capsule().fill(MacPlanTint.pause(scheme).opacity(exit.breakAfter == nil ? 0.35 : 0.8))
                            .frame(width: max(2, plan.breakAfter(exitAt: index) * unit))
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Minutes and seconds plus ready-made values: the popover behind every duration in the plan editor.
/// With `defaultValue` the value may be `nil` («как у всех»).
struct MacDurationEditor: View {
    @Binding var value: TimeInterval?
    let title: String
    let presets: [TimeInterval]
    var defaultValue: TimeInterval? = nil
    /// Step of the stepper below a minute (30 s from a minute up).
    var step: TimeInterval = 5
    var tint: Color = MacPalette.pink
    var onClose: () -> Void

    @FocusState private var minutesFocused: Bool

    private var total: Int { Int((value ?? defaultValue ?? 0).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            HStack(spacing: 6) {
                TextField("Минуты", value: Binding(get: { total / 60 },
                                                   set: { set(max(0, min(120, $0)) * 60 + total % 60) }),
                          format: .number)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                    .focused($minutesFocused)
                Text("мин").foregroundStyle(.secondary)
                TextField("Секунды", value: Binding(get: { total % 60 },
                                                    set: { set(total / 60 * 60 + max(0, min(59, $0))) }),
                          format: .number)
                    .frame(width: 38)
                    .multilineTextAlignment(.trailing)
                Text("с").foregroundStyle(.secondary)
                Stepper("Изменить",
                        onIncrement: { set(total + Int(total >= 60 ? 30 : step)) },
                        onDecrement: { set(max(0, total - Int(total > 60 ? 30 : step))) })
                .labelsHidden()
                Spacer(minLength: 0)
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit(onClose)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(presets, id: \.self) { preset in
                    let button = Button {
                        value = preset
                        onClose()
                    } label: {
                        Text(MacPlanFormat.cell(preset))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                    }
                    if value != nil && total == Int(preset) {
                        button.buttonStyle(.borderedProminent).tint(tint.opacity(0.85)).fontWeight(.semibold)
                    } else {
                        button.buttonStyle(.bordered)
                    }
                }
            }
            .controlSize(.small)

            if let defaultValue {
                Divider()
                Toggle("Как у всех — \(DurationText.short(defaultValue))", isOn: Binding(
                    get: { value == nil },
                    set: { if $0 { value = nil; onClose() } else { value = defaultValue } }))
                    .toggleStyle(.checkbox)
            }
        }
        .padding(14)
        .frame(width: 270)
        .onAppear { minutesFocused = true }
    }

    private func set(_ seconds: Int) {
        value = TimeInterval(seconds)
    }
}
#endif
