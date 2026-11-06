#if os(macOS)
import SwiftUI
import WaitingPawsCore

// MARK: - Formatting

/// Plan wording shared by the review sheet and the plan timeline.
enum MacPlanFormat {
    /// A length in the plan, one form everywhere and as on the iPhone: "45 с", "2 мин", "2 мин 30 с" (never "2:30",
    /// which reads as a moment).
    static func cell(_ seconds: TimeInterval) -> String {
        DurationText.short(seconds)
    }

    /// "≈ 28 мин" for summaries (seconds dropped from ten minutes up).
    static func approx(_ seconds: TimeInterval) -> String {
        let total = DurationText.wholeSeconds(seconds)
        if total >= 600 { return String(localized: "≈ \(Int((Double(total) / 60).rounded())) мин") }
        return "≈ " + DurationText.short(seconds)
    }

    /// "+30 с", "−1 мин".
    static func signed(_ delta: TimeInterval) -> String {
        (delta < 0 ? "−" : "+") + DurationText.short(abs(delta))
    }


    /// "Ждать тишины 30 с": the trainer's rule against coming in, what it asks (it holds on every exit).
    static func quietRuleTitle(_ plan: TrainingPlan) -> String {
        plan.doNotEnterRule?.quietTime.map { String(localized: "Ждать тишины \(DurationText.short($0))") }
            ?? String(localized: "Ждать тишины")
    }

    /// Exit durations offered in the editor (from «выйти и вернуться» to ten minutes).
    static let exitPresets: [TimeInterval] = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 300, 600]
    /// Breaks between exits.
    static let breakPresets: [TimeInterval] = [60, 90, 120, 180, 240, 300, 420, 600, 900]
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

/// What a line of the trainer's text set in the plan.
enum MacSourceTarget: Hashable {
    /// An exit's own line; `ordinal` — its place among the exit lines, the index of the exit `PlanParser` made of it.
    case exit(ordinal: Int)
    /// A line under an exit: its condition, its own break, its note.
    case underExit(ordinal: Int)
    /// The first line: the training's name, the trainers, the date.
    case header
    /// «Все перерывы 2 минуты».
    case commonBreak
    /// A condition for coming back early for the whole training.
    case commonCondition
    /// The trainer's 🚩: wait for quiet before coming in.
    case quietRule
    /// «🔖 Фальстарт: …».
    case falseStartRule
    /// Words the plan keeps as they are (a note), or a blank line.
    case none
}

/// What the pointer is over on the plan's side of the link with the trainer's text (the review's table and chips, the
/// timeline before the start): its lines light in the text, and a line under the pointer lights it back.
enum MacPlanPointer: Hashable {
    /// The exit's line and its conditions.
    case exit(UUID)
    /// The break after the exit: its own line, or «Все перерывы…» when it is the common one.
    case breakAfter(UUID)
    case commonBreak
    case commonConditions
    case quietRule
}

/// One line of the trainer's text as the parser reads it (`PlanParser.sourceLines`) and what it set in the plan.
struct MacSourceLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let kind: PlanParser.SourceLine.Kind
    let target: MacSourceTarget
    /// The exit's number as the trainer wrote it (an exit line).
    let writtenNumber: Int?

    var ordinal: Int? {
        switch target {
        case .exit(let ordinal), .underExit(let ordinal): ordinal
        default: nil
        }
    }

    @MainActor private static var cache: (text: String, lines: [MacSourceLine])?

    @MainActor
    static func lines(_ text: String) -> [MacSourceLine] {
        if let cache, cache.text == text { return cache.lines }
        var result: [MacSourceLine] = []
        for line in PlanParser.sourceLines(text) {
            let target: MacSourceTarget
            switch line.kind {
            case .exit:
                target = line.exitIndex.map { .exit(ordinal: $0) } ?? .none
            case .blank: target = .none
            case .header: target = .header
            case .doNotEnter: target = .quietRule
            case .falseStart: target = .falseStartRule
            case .earlyEntry where line.exitNumber == nil: target = .commonCondition
            case .note where line.exitNumber == nil:
                target = PlanParser.commonBreak(in: PlanParser.stripDecorations(line.text)) != nil ? .commonBreak : .none
            default:
                target = line.exitIndex.map { .underExit(ordinal: $0) } ?? .none
            }
            result.append(MacSourceLine(id: line.id, text: line.text, kind: line.kind, target: target,
                                        writtenNumber: line.kind == .exit ? line.exitNumber : nil))
        }
        cache = (text, result)
        return result
    }

    /// What the line stands for on the plan's side; nil for the header, a note and the false-start rule.
    func pointer(exitID: [Int: UUID]) -> MacPlanPointer? {
        switch target {
        case .exit(let ordinal): exitID[ordinal].map { .exit($0) }
        case .underExit(let ordinal): exitID[ordinal].map { kind == .breakTime ? .breakAfter($0) : .exit($0) }
        case .commonBreak: .commonBreak
        case .commonCondition: .commonConditions
        case .quietRule: .quietRule
        default: nil
        }
    }

    /// The lines of the exits at `ordinals`: each exit's line with everything under it.
    static func ids(ofExits ordinals: Set<Int>, in lines: [MacSourceLine]) -> Set<Int> {
        Set(lines.filter { $0.ordinal.map(ordinals.contains) ?? false }.map(\.id))
    }

    /// The lines `pointer` stands for.
    static func ids(of pointer: MacPlanPointer?, in lines: [MacSourceLine], ordinals: [UUID: Int]) -> Set<Int> {
        func all(_ target: MacSourceTarget) -> Set<Int> { Set(lines.filter { $0.target == target }.map(\.id)) }
        switch pointer {
        case nil:
            return []
        case .exit(let id):
            guard let ordinal = ordinals[id] else { return [] }
            return Set(lines.filter { $0.ordinal == ordinal && $0.kind != .breakTime }.map(\.id))
        case .breakAfter(let id):
            let own = ordinals[id].map { ordinal in lines.filter { $0.ordinal == ordinal && $0.kind == .breakTime } } ?? []
            return own.isEmpty ? all(.commonBreak) : Set(own.map(\.id))
        case .commonBreak: return all(.commonBreak)
        case .commonConditions: return all(.commonCondition)
        case .quietRule: return all(.quietRule)
        }
    }

    // MARK: Highlighting

    private static let durationRegex = try! NSRegularExpression(
        pattern: #"\d+(?:[.,]\d+)?\s*(?:час\p{L}*|мин\p{L}*|сек\p{L}*|hour\p{L}*|hr\p{L}*|min\p{L}*|sec\p{L}*)"#,
        options: [.caseInsensitive])
    private static let exitLabelRegex = try! NSRegularExpression(
        pattern: #"\d+\s*[-–—.)]?\s*выход\p{L}*|выход\p{L}*\s*(?:№\s*)?\d+|exit\s*(?:№|#)?\s*\d+|\d+(?:st|nd|rd|th)?\s+exit"#,
        options: [.caseInsensitive])
    private static let standingRegex = try! NSRegularExpression(
        pattern: #"(?:или\s+)?(?:до\s+вставания|пока\s+не\s+встанет)|(?:or\s+)?until[^+()]*stand\p{L}*"#,
        options: [.caseInsensitive])
    private static let triggerRegex = try! NSRegularExpression(pattern: #"\+\s*([^+(]+)"#)

    /// What the plan says now, which the line's words are checked against.
    struct Context {
        var plan: TrainingPlan?
        /// The plan as the trainer's text gives it (`MacPlanLineMap.trainerPlan`).
        var trainer: TrainingPlan?
        /// The exit the line went to.
        var exit: PlannedExit?
        /// The line is an exit's, and that exit is gone from the plan.
        var removed = false
    }

    /// The words with what the plan read from them marked: an exit's time in the exits' pink, its triggers in the ⚡'s
    /// amber, the times of breaks and conditions blue, «ИЛИ до вставания» blue like 🏃 where it became the exit's
    /// condition, what the dog does in full white, the wait for quiet red, the training's name bold and its trainers
    /// and date brighter; the rest quieter, a note quieter still. A word the owner has changed since is struck
    /// through and faded, as on the iPhone (`TrainerWords`); an exit taken out of the plan, its whole lines.
    /// `muted`: the same weights without the colours (during a training, away from the exit under way); the wait for
    /// quiet then in plain quiet words, its red left to the ⊖ at its side.
    func attributed(size: CGFloat, scheme: ColorScheme, context: Context = Context(), muted: Bool = false) -> AttributedString {
        enum Role { case quiet, faint, plain, strong, title, exitTime, trigger, info, infoTime, danger, rule }
        struct Mark {
            let range: NSRange
            let role: Role
            var stale = false
        }
        var marks: [Mark] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let words = PlanParser.stripDecorations(text)
        let plan = context.plan, exit = context.exit
        func times(_ role: Role, stale: Bool = false, before limit: Int = .max) {
            for match in Self.durationRegex.matches(in: text, range: full) where match.range.location < limit {
                marks.append(Mark(range: match.range, role: role, stale: stale))
            }
        }
        func mark(_ words: String?, _ role: Role, stale: Bool = false) {
            guard let words, !words.isEmpty else { return }
            let range = ns.range(of: words, options: .caseInsensitive)
            if range.location != NSNotFound { marks.append(Mark(range: range, role: role, stale: stale)) }
        }
        var base: Role = .quiet
        switch kind {
        case .blank:
            return AttributedString()
        case .header:
            // «Тренировка на воскресенье - Таня/Андрей - 04.10.2026»: the parts between the dashes, as the parser reads them.
            let trainer = context.trainer
            var cursor = 0
            var parts: [NSRange] = []
            for separator in Self.dashRegex.matches(in: text, range: full) {
                parts.append(NSRange(location: cursor, length: separator.range.location - cursor))
                cursor = NSMaxRange(separator.range)
            }
            parts.append(NSRange(location: cursor, length: ns.length - cursor))
            for (index, part) in parts.enumerated() where part.length > 0 {
                if Self.dateRegex.firstMatch(in: text, range: part) != nil {
                    let stale = plan.flatMap { plan in trainer.map { !Self.sameDay(plan.date, $0.date) } } ?? false
                    marks.append(Mark(range: part, role: .strong, stale: stale))
                } else if index == 0 {
                    let stale = plan.flatMap { plan in trainer.map { plan.title != $0.title } } ?? false
                    marks.append(Mark(range: part, role: .title, stale: stale))
                } else {
                    let stale = plan.flatMap { plan in trainer.map { plan.trainers != $0.trainers } } ?? false
                    marks.append(Mark(range: part, role: .strong, stale: stale))
                }
            }
        case .exit:
            if let label = Self.exitLabelRegex.firstMatch(in: text, range: full) {
                marks.append(Mark(range: label.range, role: .strong))
            }
            let standing = Self.standingRegex.firstMatch(in: text, range: full)?.range
            let written = PlanParser.parseExit(words)
            // The exit's time: before «ИЛИ» and the triggers.
            let timeStale = exit.map { exit in !exit.isOpen && written.map { $0.duration != exit.duration } ?? false } ?? false
            times(.exitTime, stale: timeStale, before: min(ns.range(of: "+").location, standing?.location ?? .max))
            for match in Self.triggerRegex.matches(in: text, range: full) {
                var range = match.range(at: 1)
                if let standing, NSLocationInRange(standing.location, range) {
                    range.length = standing.location - range.location
                }
                while range.length > 0, ns.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)) == " " {
                    range.length -= 1
                }
                let trigger = ns.substring(with: range).lowercased()
                let stale = exit.map { exit in !exit.triggers.contains { $0.lowercased() == trigger } } ?? false
                marks.append(Mark(range: range, role: .trigger, stale: stale))
            }
            // «ИЛИ до вставания» marked only where it became the exit's own condition «встала → сразу» (its own lines
            // about standing up say it otherwise); struck through once the owner took that condition away.
            if let standing, let trainer = context.trainer, let ordinal,
               trainer.exits.indices.contains(ordinal),
               trainer.earlyEntries(of: trainer.exits[ordinal]).contains(where: \.isUntilStanding) {
                let stale = plan.flatMap { plan in exit.map { !plan.earlyEntries(of: $0).contains(where: \.isUntilStanding) } } ?? false
                marks.append(Mark(range: standing, role: .info, stale: stale))
            }
        case .earlyEntry:
            let entries: [EarlyEntry]? = plan.flatMap { plan in
                target == .commonCondition ? plan.commonEarlyEntries : exit.map { plan.earlyEntries(of: $0) }
            }
            let written = PlanParser.parseEarlyEntry(text)
            let match = entries?.first { $0.event.lowercased() == written?.event.lowercased() }
            let gone = entries != nil && match == nil
            let delayStale = gone || match.map { ($0.delay ?? 0) != (written?.delay ?? 0) } == true
            mark(written?.event, .plain, stale: gone)
            times(.infoTime, stale: delayStale)
        case .breakTime:
            var stale = false
            if let plan, let exit, let index = plan.exits.firstIndex(where: { $0.id == exit.id }), index < plan.exits.count - 1,
               let written = DurationText.sumOfUnits(in: words) {
                stale = plan.breakAfter(exitAt: index) != written
            }
            times(.infoTime, stale: stale)
        case .doNotEnter:
            if !muted {
                mark(PlanParser.splitCondition(text).title, .plain)
                times(.danger)
            }
        case .falseStart:
            let colon = ns.range(of: ":")
            marks.append(Mark(range: NSRange(location: 0, length: colon.location == NSNotFound ? ns.length : colon.location + 1),
                              role: .rule))
        case .note:
            if target == .commonBreak {
                let stale = plan.map { plan in PlanParser.commonBreak(in: words).map { $0 != plan.defaultBreak } ?? false } ?? false
                times(.infoTime, stale: stale)
            } else {
                base = target == .none ? .faint : .quiet
            }
        }
        marks.sort { $0.range.location < $1.range.location }

        var result = AttributedString()
        func append(_ range: NSRange, _ role: Role, stale: Bool = false) {
            guard range.length > 0 else { return }
            var run = AttributedString(ns.substring(with: range))
            var weight: Font.Weight = .regular
            var color: Color
            switch role {
            case .quiet: color = Color(nsColor: .secondaryLabelColor)
            case .faint: color = Color(nsColor: .tertiaryLabelColor)
            case .plain: color = .primary
            case .strong: color = .primary; weight = .semibold
            case .title: color = .primary; weight = .bold
            case .exitTime: color = MacPlanTint.exit(scheme); weight = .semibold
            case .trigger: color = Theme.warning; weight = .medium
            case .info: color = MacPlanTint.pause(scheme); weight = .medium
            case .infoTime: color = MacPlanTint.pause(scheme); weight = .semibold
            case .danger: color = MacPalette.red; weight = .semibold
            case .rule: color = MacPlanTint.rule(scheme); weight = .semibold
            }
            if muted, ![.quiet, .faint].contains(role) { color = .primary }
            if stale {
                color = color.opacity(0.55)
                run.strikethroughStyle = Text.LineStyle.single
            }
            run.foregroundColor = color
            run.font = .system(size: size, weight: weight)
            result += run
        }
        var cursor = 0
        for mark in marks where mark.range.location >= cursor {
            append(NSRange(location: cursor, length: mark.range.location - cursor), base)
            append(mark.range, mark.role, stale: mark.stale)
            cursor = NSMaxRange(mark.range)
        }
        append(NSRange(location: cursor, length: ns.length - cursor), base)
        if context.removed {
            result.strikethroughStyle = Text.LineStyle.single
            result.foregroundColor = Color(nsColor: .secondaryLabelColor)
        }
        return result
    }

    /// « - » between the header's parts.
    private static let dashRegex = try! NSRegularExpression(pattern: #"\s[-–—]\s"#)
    private static let dateRegex = try! NSRegularExpression(pattern: #"\d{1,2}[./]\d{1,2}[./]\d{2,4}"#)

    private static func sameDay(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case let (a?, b?): return Calendar.current.isDate(a, inSameDayAs: b)
        case (nil, nil): return true
        default: return false
        }
    }
}

/// Which exit of the plan each exit line of the trainer's text became: the exit's `sourceIndex` (its place among the
/// text's exits, kept through a reorder, none for an exit added by hand). A plan from a build before it is matched
/// once, at its first look, by order or by the number written in the text.
@MainActor
enum MacPlanLineMap {
    private static var cache: [UUID: [UUID: Int]] = [:]
    private static var parsed: (text: String, plan: TrainingPlan)?

    /// Exit id → the ordinal of its line among the exit lines.
    static func ordinals(for plan: TrainingPlan, lines: [MacSourceLine]) -> [UUID: Int] {
        if plan.exits.contains(where: { $0.sourceIndex != nil }) {
            var map: [UUID: Int] = [:]
            for exit in plan.exits { if let index = exit.sourceIndex { map[exit.id] = index } }
            return map
        }
        if let known = cache[plan.id] { return known }
        let exitLines = lines.filter { if case .exit = $0.target { true } else { false } }
        guard !exitLines.isEmpty else { return [:] }
        if exitLines.count == plan.exits.count {
            let map = Dictionary(uniqueKeysWithValues: zip(plan.exits.map(\.id), exitLines.indices))
            cache[plan.id] = map
            return map
        }
        // Edited before the first look: by the number written in the text.
        var map: [UUID: Int] = [:]
        for exit in plan.exits {
            if let line = exitLines.first(where: { $0.writtenNumber == exit.number }), let ordinal = line.ordinal {
                map[exit.id] = ordinal
            }
        }
        return map
    }

    /// The plan as the trainer's text says it: what the owner changed since shows against it.
    static func trainerPlan(_ text: String) -> TrainingPlan {
        if let parsed, parsed.text == text { return parsed.plan }
        let plan = PlanParser.parse(text)
        parsed = (text, plan)
        return plan
    }
}

/// The link between the trainer's text and the plan, worked out once per redraw: which exit each exit line became,
/// and what the trainer's text says of each exit.
@MainActor
struct MacPlanTextLink {
    let lines: [MacSourceLine]
    /// Exit id → the ordinal of its exit line.
    let ordinals: [UUID: Int]
    /// The other way.
    let exitIDs: [Int: UUID]
    /// The plan's exit of each exit line, by the line's ordinal.
    let exits: [Int: PlannedExit]
    /// The plan now.
    let plan: TrainingPlan
    /// The plan as the text says it.
    let trainer: TrainingPlan

    init(plan: TrainingPlan, lines: [MacSourceLine]) {
        self.lines = lines
        self.plan = plan
        let ordinals = MacPlanLineMap.ordinals(for: plan, lines: lines)
        let present = plan.exits.filter { ordinals[$0.id] != nil }
        self.ordinals = ordinals
        exits = Dictionary(present.map { (ordinals[$0.id]!, $0) }, uniquingKeysWith: { first, _ in first })
        exitIDs = exits.mapValues(\.id)
        trainer = MacPlanLineMap.trainerPlan(plan.rawText)
    }

    /// The plan's number of each exit line's exit.
    var numbers: [Int: Int] { exits.mapValues(\.number) }

    var hasText: Bool { lines.contains { $0.kind != .blank } }

    /// What the line's words are checked against.
    func context(of line: MacSourceLine) -> MacSourceLine.Context {
        let exit = line.ordinal.flatMap { exits[$0] }
        return MacSourceLine.Context(plan: plan, trainer: trainer, exit: exit, removed: line.ordinal != nil && exit == nil)
    }

    /// The trainer's time behind the door for the exit, when it came from the text.
    func trainerDuration(of exit: PlannedExit) -> TimeInterval? {
        guard let ordinal = ordinals[exit.id], trainer.exits.indices.contains(ordinal) else { return nil }
        return trainer.exits[ordinal].duration
    }

    /// The trainer's break after the exit (the common one when she gave it none of its own); nil for the last.
    func trainerBreak(after exit: PlannedExit) -> TimeInterval? {
        guard let ordinal = ordinals[exit.id], ordinal < trainer.exits.count - 1 else { return nil }
        return trainer.breakAfter(exitAt: ordinal)
    }
}

/// The trainer's text as she wrote it, with what the plan made of each line at its side: an exit's line carries the
/// exit's number as the timeline's blocks do (the plan's number, so after a reorder the row's), the lines under it a
/// thin stem down from it; a line for the whole training the sign of what it set (⏸ the common break, ⊖ the wait for
/// quiet, 🏃 common conditions, 🔖 the false-start rule); a note nothing, in quieter words. No line numbers, legend or
/// words about it. `lit` lines (the rows selected, the exit under way) are one pink block, `pointed` ones (what the
/// pointer is over on the plan's side) a quieter one, `dimmed` ones (exits done) faded.
struct MacTrainerTextView: View {
    /// The lines and the plan they are checked against.
    let link: MacPlanTextLink
    var lit: Set<Int> = []
    var pointed: Set<Int> = []
    var dimmed: Set<Int> = []
    var fontSize: CGFloat = 13
    /// Colour only in the `lit` lines (during a training: the exit under way); the rest in the same weights, grey.
    var colorsOnlyLit = false
    /// Brought into view (the least scrolling that shows it) when it changes.
    var focus: Int? = nil
    var onHover: ((MacSourceLine?) -> Void)? = nil
    var onTap: ((MacSourceLine) -> Void)? = nil

    @Environment(\.colorScheme) private var scheme
    @State private var hovered: Int?

    private var lines: [MacSourceLine] { link.lines }

    private enum Mark { case none, lit, pointed }

    private func mark(of line: MacSourceLine) -> Mark {
        lit.contains(line.id) ? .lit : pointed.contains(line.id) ? .pointed : .none
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // One flat list (a row keeps its identity while the marks move): a marked run of lines is drawn as
                // one block by its rows, rounded only at its ends.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        let mark = mark(of: line)
                        row(line)
                            .background {
                                markShape(mark,
                                          top: index == 0 || self.mark(of: lines[index - 1]) != mark,
                                          bottom: index == lines.count - 1 || self.mark(of: lines[index + 1]) != mark)
                            }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }
            .onChange(of: focus, initial: true) { old, line in
                guard let line else { return }
                if old == nil || old == line {
                    proxy.scrollTo(line)
                } else {
                    withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(line) }
                }
            }
        }
    }

    @ViewBuilder
    private func markShape(_ mark: Mark, top: Bool, bottom: Bool) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: top ? 6 : 0, bottomLeadingRadius: bottom ? 6 : 0,
                                           bottomTrailingRadius: bottom ? 6 : 0, topTrailingRadius: top ? 6 : 0,
                                           style: .continuous)
        switch mark {
        case .lit: shape.fill(MacPalette.pink.opacity(0.14))
        case .pointed: shape.fill(Color.primary.opacity(0.07))
        case .none: EmptyView()
        }
    }

    @ViewBuilder
    private func row(_ line: MacSourceLine) -> some View {
        if line.kind == .blank {
            Color.clear.frame(height: fontSize * 0.55).id(line.id)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                gutter(line)
                    .frame(width: 24)
                words(line)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(alignment: .leading) { stem(line) }
            .opacity(dimmed.contains(line.id) ? 0.38 : 1)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hovered = line.id
                    onHover?(line)
                } else if hovered == line.id {
                    hovered = nil
                    onHover?(nil)
                }
            }
            .simultaneousGesture(TapGesture().onEnded { onTap?(line) }, including: onTap == nil ? .none : .all)
            .id(line.id)
        }
    }

    @ViewBuilder
    private func words(_ line: MacSourceLine) -> some View {
        let text = Text(line.attributed(size: fontSize, scheme: scheme, context: link.context(of: line), muted: muted(line)))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        // Only to read where a click means nothing else.
        if onTap == nil { text.textSelection(.enabled) } else { text }
    }

    @ViewBuilder
    private func gutter(_ line: MacSourceLine) -> some View {
        switch line.target {
        case .exit(let ordinal):
            MacExitBadge(number: link.exits[ordinal]?.number, filled: lit.contains(line.id) || pointed.contains(line.id),
                         muted: muted(line))
        case .header: sign("calendar", .secondary)
        case .commonBreak: sign("pause.fill", muted(line) ? .secondary : MacPlanTint.pause(scheme))
        case .commonCondition: sign("figure.run", muted(line) ? .secondary : MacPalette.blue)
        case .quietRule: sign("minus.circle.fill", MacPalette.red)
        case .falseStartRule: sign("bookmark.fill", muted(line) ? .secondary : MacPlanTint.rule(scheme))
        default: Text(verbatim: " ").font(.system(size: 10.5))
        }
    }

    private func muted(_ line: MacSourceLine) -> Bool { colorsOnlyLit && !lit.contains(line.id) }

    private func sign(_ symbol: String, _ tint: Color) -> some View {
        Text(Image(systemName: symbol))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
    }

    /// A thin pink stem in the gutter: the line belongs to the exit above.
    @ViewBuilder
    private func stem(_ line: MacSourceLine) -> some View {
        if case .underExit = line.target {
            Capsule()
                .fill(muted(line) ? Color.secondary.opacity(0.5) : MacPlanTint.exit(scheme).opacity(0.4))
                .frame(width: 1.5)
                .padding(.leading, 4 + 12 - 0.75)
        }
    }
}

/// An exit's number in the trainer's text and in the review's table, the pink of the timeline's exit blocks: a quiet
/// tint, solid while its lines or its row are lit; grey when `muted`. «–» for an exit line whose exit is gone.
struct MacExitBadge: View {
    let number: Int?
    var filled = false
    var muted = false

    var body: some View {
        let tint = muted ? Color.secondary : MacPalette.pink
        Text(verbatim: number.map(String.init) ?? "–")
            .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(filled ? AnyShapeStyle(Color.black.opacity(0.78)) : AnyShapeStyle(tint))
            .padding(.horizontal, 4)
            .frame(minWidth: 19, minHeight: 15)
            .background(filled ? AnyShapeStyle(MacPalette.pink) : AnyShapeStyle(tint.opacity(0.16)),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(number == nil ? 0.45 : 1)
            .fixedSize()
    }
}

// MARK: - Small pieces

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

    private var total: Int { DurationText.wholeSeconds(value ?? defaultValue ?? 0) }

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
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
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
