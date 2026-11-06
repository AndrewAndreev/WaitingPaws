import SwiftUI
import WaitingPawsCore

/// What the readout says about an exit besides its time: when to come back early, when not to come in, what to take
/// on the way out and its note. Outside it is about the current exit, in a break about the next one.
struct ExitBrief {
    let exit: PlannedExit
    /// Its conditions for coming back early («Встала и пошла — через 2:00»), «до вставания» among them.
    let entries: [EarlyEntry]
    /// «Залаяла, завыла — ждать тишины»: the trainer's rule for the whole training, on every exit.
    let doNotEnter: TrainingPlan.Rule?
    /// The exit's note and what the trainer wrote about its conditions.
    let notes: [String]

    init(plan: TrainingPlan, exit: PlannedExit) {
        self.exit = exit
        entries = plan.earlyEntries(of: exit)
        // The trainer's rule holds for the whole training: every exit shows it (no hidden exceptions).
        doNotEnter = plan.doNotEnterRule
        notes = [exit.noteText].compactMap { $0 }
            + entries.compactMap { entry in entry.detail.map { "\(entry.event): \($0)" } }
    }

    /// The schedule has details for some exit: the readout keeps a row for them.
    static func hasDetails(_ plan: TrainingPlan) -> Bool {
        plan.doNotEnterRule != nil || plan.exits.contains { exit in
            !exit.triggers.isEmpty || exit.noteText != nil || !plan.earlyEntries(of: exit).isEmpty
        }
    }
}

// MARK: - Conditions in one form

/// An exit's conditions are written one way on every screen — the training card, the Mac, the plan: the trainer's
/// event lower-cased and its time, «встала и пошла 0:30 · легла 0:20 · ⊖ тишина 0:30». No arrows, no «через».
extension EarlyEntry {
    /// «встала и пошла»: the trainer's words for what the dog does, lower-cased.
    var conditionWords: String { event.prefix(1).lowercased() + event.dropFirst() }

    /// «0:30»; «сразу» without a delay («ИЛИ до вставания» is «встала сразу»); the trainer's words for a time the
    /// parser couldn't read («через пару минут»).
    var conditionTime: String {
        delay.flatMap { $0 > 0 ? DurationText.clock($0) : nil } ?? unreadDelay ?? String(localized: "сразу")
    }

    /// «встала и пошла 0:30».
    var conditionText: String { "\(conditionWords) \(conditionTime)" }
}

extension TrainingPlan.Rule {
    /// «тишина» and the quiet the trainer asked for, «0:30»; «ждать тишины» when the rule names no time. After the
    /// red ⊖ (`ConditionsLine.ruleSymbol`).
    var conditionWords: String {
        quietTime == nil ? String(localized: "ждать тишины") : String(localized: "тишина")
    }

    var conditionTime: String? { quietTime.map(DurationText.clock) }

    /// «тишина 0:30» (without the ⊖).
    var conditionText: String { [conditionWords, conditionTime].compactMap { $0 }.joined(separator: " ") }
}

/// «встала и пошла 0:30 · легла 0:20 · ⊖ тишина 0:30»: an exit's conditions in their one form (`conditionText`), for
/// reading only. The words quiet, the times brighter, «·» between two conditions on one line only (none ends a line),
/// the trainer's rule after the red ⊖; it wraps by whole conditions. The colour of the words is the caller's
/// (`foregroundStyle`); the times are white.
struct ConditionsLine: View {
    let entries: [EarlyEntry]
    /// The trainer's rule against coming in (nil: none, or not shown here).
    var rule: TrainingPlan.Rule? = nil
    var size: CGFloat = 14
    /// Between two conditions on one line.
    var spacing: CGFloat = 5

    /// The rule's sign, red: «no entry».
    static let ruleSymbol = "minus.circle.fill"

    var body: some View {
        SeparatedFlowLayout(spacing: spacing, lineSpacing: 3) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if index > 0 { FlowDot() }
                Self.item(words: entry.conditionWords, time: entry.conditionTime, size: size)
            }
            if let rule {
                if !entries.isEmpty { FlowDot() }
                Self.item(words: rule.conditionWords, time: rule.conditionTime, size: size, rule: true)
            }
        }
        .font(.system(size: size, weight: .medium, design: .rounded))
        .accessibilityElement(children: .combine)
    }

    /// One condition: «легла 0:20», «⊖ тишина 0:30».
    static func item(words: String, time: String?, size: CGFloat, rule: Bool = false) -> some View {
        HStack(spacing: 4) {
            if rule {
                Image(systemName: ruleSymbol)
                    .font(.system(size: size * 0.9, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            }
            Text(verbatim: words)
            if let time {
                Text(verbatim: time)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.92))
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Words that go with a number

/// A word in the form its number asks for, for a number shown apart from it (a large «2» over «фальстарта»). With the
/// number in the same line, `HistoryText.falseStarts` («2 фальстарта»).
enum CountText {
    /// «фальстарт», «фальстарта», «фальстартов» / "false start", "false starts".
    static func falseStartWord(_ count: Int) -> String {
        let text = pluralText(count, ru: ("фальстарт", "фальстарта", "фальстартов"), en: ("false start", "false starts"))
        return String(text.drop(while: { $0 != " " }).dropFirst())
    }
}

// MARK: - Lines of items with «·» between them

/// Items in lines like words, a «·» (`FlowDot`) between two items on the same line only: a wrapped line never ends
/// or starts with one, and an item is never split (design council, rounds 7–8: «легла → 0:20 ·» left hanging at the
/// end of a line, «· ⊖ ждать тишины» opening the next). The dots are subviews marked `FlowDot`; one where the line
/// breaks is laid out with no size (and clipped away).
struct SeparatedFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 2

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func append(_ index: Int, _ size: CGSize, spacing: CGFloat) {
            width += (items.isEmpty ? 0 : spacing) + size.width
            height = max(height, size.height)
            items.append((index, size))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity).lines
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        let width = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { $0.isFinite ? $0 : width } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (lines, hidden) = arrange(subviews, width: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2),
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
        for index in hidden {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: .zero)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (lines: [Line], hidden: [Int]) {
        var lines: [Line] = [Line()]
        var hidden: [Int] = []
        var dot: (index: Int, size: CGSize)?
        for index in subviews.indices {
            if subviews[index][FlowDotKey.self] {
                if let dot { hidden.append(dot.index) }
                dot = (index, subviews[index].sizeThatFits(.unspecified))
                continue
            }
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let line = lines[lines.count - 1]
            let dotWidth = dot.map { $0.size.width + spacing } ?? 0
            if line.items.isEmpty || line.width + dotWidth + spacing + size.width > width + 0.5 {
                if let dot { hidden.append(dot.index) }
                if !line.items.isEmpty { lines.append(Line()) }
            } else if let dot {
                lines[lines.count - 1].append(dot.index, dot.size, spacing: spacing)
            }
            lines[lines.count - 1].append(index, size, spacing: spacing)
            dot = nil
        }
        if let dot { hidden.append(dot.index) }
        return (lines.filter { !$0.items.isEmpty }, hidden)
    }
}

private struct FlowDotKey: LayoutValueKey {
    static let defaultValue = false
}

/// The «·» between two items of a `SeparatedFlowLayout`, in the items' font and colour; gone where the line breaks.
struct FlowDot: View {
    var body: some View {
        Text(verbatim: "·")
            .fixedSize()
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
            .accessibilityHidden(true)
            .layoutValue(key: FlowDotKey.self, value: true)
    }
}

extension ReadoutContent {
    /// The exit the readout talks about besides the timer: the current one outside, the next one in a break.
    var brief: ExitBrief? {
        switch session.phase {
        case .ready, .leaving, .away:
            return session.currentExit.map { ExitBrief(plan: session.plan, exit: $0) }
        case .breakTime(_, _, _, let next):
            guard let next, session.plan.exits.indices.contains(next) else { return nil }
            return ExitBrief(plan: session.plan, exit: session.plan.exits[next])
        case .finished:
            return nil
        }
    }

    /// The exit whose lines are marked in the trainer's text.
    var textExitNumber: Int? { brief?.exit.number }
}

extension EarlyEntry.Tone {
    /// The trainer's 🟡 and 🟢; a condition without a mark is blue like the «Вернулись» button.
    var color: Color {
        switch self {
        case .yellow: return Theme.warning
        case .green: return Theme.go
        case .plain: return Theme.info
        }
    }
}

/// The trainer's text line by line, marked as her whole text from the plan is (`TrainerPageLine`: the exits' numbers in
/// the margin, what the plan read in each line in its colour, the sign of the rule to wait for quiet; design council,
/// round 17: the drawer showed the bare words): the lines of `exitNumber` (the exit and its conditions under it) as one
/// pink block — one instruction, one mark at its side, not a strip per line — brought into view when it changes (not
/// otherwise: the reader's own scrolling stays where it is), exits before it dimmed. A plain stack: a lazy one measured
/// the long lines only as they came into view, and the text jumped under the finger.
struct TrainerTextView: View {
    let plan: TrainingPlan
    /// The current exit (the next one in a break), by its number in `plan`.
    let exitNumber: Int?

    /// The lines in runs: the current exit's consecutive lines together, every other line alone.
    private struct Run: Identifiable {
        let lines: [PlanParser.SourceLine]
        let current: Bool
        var id: PlanParser.SourceLine.ID { lines[0].id }
    }

    var body: some View {
        let source = TrainerSource(plan)
        let current = exitNumber.flatMap { number in plan.exits.firstIndex { $0.number == number } }
        let runs = runs(source, current: current)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(runs) { run in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(run.lines) { row($0, source: source, current: current, inCurrent: run.current) }
                        }
                        .padding(.vertical, run.current ? 3 : 0)
                        .background(alignment: .leading) {
                            if run.current {
                                ZStack(alignment: .leading) {
                                    Theme.accent.opacity(0.13)
                                    Theme.accent.frame(width: 3)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                        .id(run.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: exitNumber, initial: true) { _, _ in
                guard let run = runs.first(where: \.current) else { return }
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(run.id, anchor: UnitPoint(x: 0, y: 0.2)) }
            }
        }
    }

    private func runs(_ source: TrainerSource, current: Int?) -> [Run] {
        let exit = current.map { plan.exits[$0] }
        var runs: [Run] = []
        for line in source.lines {
            let isCurrent = exit.map { line.role != .blank && source.isLine(line, of: $0) } ?? false
            if isCurrent, let last = runs.last, last.current {
                runs[runs.count - 1] = Run(lines: last.lines + [line], current: true)
            } else {
                runs.append(Run(lines: [line], current: isCurrent))
            }
        }
        return runs
    }

    @ViewBuilder
    private func row(_ line: PlanParser.SourceLine, source: TrainerSource, current: Int?, inCurrent: Bool) -> some View {
        if line.role == .blank {
            Color.clear.frame(height: 6)
        } else {
            // The exits already done (before the current one) dimmed.
            let done = current.map { current in
                source.exit(of: line, in: plan).flatMap { exit in plan.exits.firstIndex { $0.id == exit.id } }.map { $0 < current } ?? false
            } ?? false
            // In the current block its pink bar says whose lines they are: no rule beside them.
            TrainerPageLine(line: line, source: source, plan: plan, exitRule: !inCurrent)
                .padding(.leading, 6)
                .padding(.trailing, 10)
                .opacity(done ? 0.4 : 1)
                .textSelection(.enabled)
        }
    }
}

/// «⚡ куртка · ключи   🏃 встала → 2:00 · легла → 0:30   💬 выйти и сразу вернуться» under an exit in the plan:
/// only what the exit has, in words. An exit with nothing besides its time gives an empty line (`isEmpty`), which the
/// iPhone plan leaves out and the Mac table leaves blank.
struct ExitSummaryText: View {
    let plan: TrainingPlan
    let exit: PlannedExit
    var size: CGFloat = 13

    /// No triggers, no conditions for coming back early, no note.
    var isEmpty: Bool {
        exit.triggers.isEmpty && exit.noteText == nil && plan.earlyEntries(of: exit).isEmpty
    }

    var body: some View {
        let entries = plan.earlyEntries(of: exit)
        let bright = Color.white.opacity(0.85)
        let dim = Color.white.opacity(0.4)
        // Joined by interpolation (`Text + Text` is deprecated) into keys the catalog has as untranslated: "%@ %@", "%@  %@".
        func part(_ symbol: String, _ tint: Color, _ words: Text) -> Text {
            Text("\(Text(Image(systemName: symbol)).foregroundStyle(tint)) \(words)")
        }
        var parts: [Text] = []
        if !exit.triggers.isEmpty {
            parts.append(part("bolt.fill", Theme.warning, Text(verbatim: exit.triggers.joined(separator: " · ")).foregroundStyle(bright)))
        }
        if !entries.isEmpty {
            // In their one form (`EarlyEntry.conditionText`), as on the training card and the Mac. Each condition
            // unbroken, the «·» after it kept with it: the row wraps between whole conditions.
            let summaries = entries.map(\.conditionText)
                .map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
            var words = Text(verbatim: summaries.joined(separator: "\u{00A0}· ")).foregroundStyle(bright)
            if plan.usesCommonEarlyEntries(exit) {
                words = Text("\(words) \(Text("· общие").foregroundStyle(dim))")
            }
            parts.append(part("figure.run", Theme.info, words))
        }
        if let note = exit.noteText {
            parts.append(part("text.bubble", dim, Text(verbatim: note).foregroundStyle(.white.opacity(0.6))))
        }
        let text = parts.dropFirst().reduce(parts.first ?? Text(verbatim: "")) { Text("\($0)  \($1)") }
        return text
            .font(.system(size: size, design: .rounded))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }
}

// MARK: - Editing an exit's conditions

extension TrainingPlan {
    /// The conditions to edit for the exit at `index`: those it shows, «Встала → сразу» of «ИЛИ до вставания» too.
    func editableEarlyEntries(ofExitAt index: Int) -> [EarlyEntry] {
        guard exits.indices.contains(index) else { return [] }
        return earlyEntries(of: exits[index])
    }

    /// Changes condition `offset` of the exit; one of the common ones becomes the exit's own copy first, so the other
    /// exits keep theirs.
    mutating func setEarlyEntry(_ entry: EarlyEntry, at offset: Int, ofExitAt index: Int) {
        detachEarlyEntries(ofExitAt: index)
        guard exits.indices.contains(index), exits[index].earlyEntries.indices.contains(offset) else { return }
        var value = entry
        value.id = exits[index].earlyEntries[offset].id
        exits[index].earlyEntries[offset] = value
    }

    mutating func removeEarlyEntries(at offsets: IndexSet, ofExitAt index: Int) {
        detachEarlyEntries(ofExitAt: index)
        guard exits.indices.contains(index) else { return }
        exits[index].earlyEntries.remove(atOffsets: offsets.filteredIndexSet { exits[index].earlyEntries.indices.contains($0) })
    }

    /// «Своё условие»: a new condition of this exit only.
    mutating func addEarlyEntry(toExitAt index: Int) {
        detachEarlyEntries(ofExitAt: index)
        guard exits.indices.contains(index) else { return }
        exits[index].usesCommonEarlyEntries = false
        exits[index].earlyEntries.append(EarlyEntry(event: "", delay: 30))
    }

    /// «Вернуть общие условия»: the exit drops its own and follows the training's again.
    mutating func restoreCommonEarlyEntries(ofExitAt index: Int) {
        guard exits.indices.contains(index) else { return }
        exits[index].earlyEntries = []
        exits[index].usesCommonEarlyEntries = true
    }
}

// MARK: - Camera names

/// What to call the two cameras where there is little room: their names while they are short and different
/// («Прихожая», «Комната»), else the models when those differ («Xiaomi Smart Camera C302» → «C302»), else the names.
/// The number («1», «2») is the last resort of the views themselves.
enum CameraShortNames {
    static func make(_ first: String, _ second: String) -> (String, String) {
        if first != second, first.count <= 14, second.count <= 14 { return (first, second) }
        if let a = model(of: first), let b = model(of: second), a != b { return (a, b) }
        return (first, second)
    }

    /// «C302», «C200», «MJSXJ09CM»: the last word of letters and digits with a digit in it.
    static func model(of name: String) -> String? {
        name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).last.map(String.init).flatMap { word in
            word.contains(where: \.isNumber) && word.contains(where: \.isLetter) ? word : nil
        }
    }
}
