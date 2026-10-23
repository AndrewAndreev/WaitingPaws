import SwiftUI
import WaitingPawsCore

/// What the readout says about an exit besides its time: when to come back early, when not to come in, what to take
/// on the way out and the notes. Outside it is about the current exit, in a break about the next one.
struct ExitBrief {
    let exit: PlannedExit
    /// Its conditions for coming back early («Встала и пошла — через 2:00»), «до вставания» among them.
    let entries: [EarlyEntry]
    /// «Залаяла, завыла — не входить»: on exits with conditions and on long ones (a 5 s exit is over before).
    let doNotEnter: TrainingPlan.Rule?
    /// The exit's note and what the trainer wrote about its conditions, for the folded «Заметки» line.
    let notes: [String]

    init(plan: TrainingPlan, exit: PlannedExit) {
        self.exit = exit
        entries = plan.earlyEntries(of: exit)
        doNotEnter = !entries.isEmpty || exit.duration >= TrainingPlan.CommonEntriesScope.longExit ? plan.doNotEnterRule : nil
        notes = [exit.noteText].compactMap { $0 }
            + entries.compactMap { entry in entry.detail.map { "\(entry.event): \($0)" } }
    }

    /// Nothing to show for this exit outside (or, in a break, for the way out).
    func isEmpty(inBreak: Bool) -> Bool {
        entries.isEmpty && notes.isEmpty && (inBreak ? exit.triggers.isEmpty : doNotEnter == nil)
    }

    /// The schedule has details for some exit: the readout keeps a row for them.
    static func hasDetails(_ plan: TrainingPlan) -> Bool {
        plan.doNotEnterRule != nil || plan.exits.contains { exit in
            !exit.triggers.isEmpty || exit.noteText != nil || !plan.earlyEntries(of: exit).isEmpty
        }
    }

    /// The conditions in one line: «встала и пошла → 2:00 · легла → 0:30».
    var entriesSummary: String? {
        entries.isEmpty ? nil : entries.map(\.summary).joined(separator: " · ")
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
        case .green: return Color(red: 0.43, green: 0.91, blue: 0.63)
        case .plain: return Theme.info
        }
    }
}

/// ⚡ 🏃 📝 of an exit, always there: with a count when the exit has them, dimmed when not.
struct ExitMarks: View {
    let triggers: Int
    let entries: Int
    let hasNote: Bool
    var size: CGFloat = 12

    init(plan: TrainingPlan, exit: PlannedExit, size: CGFloat = 12) {
        triggers = exit.triggers.count
        entries = plan.earlyEntries(of: exit).count
        hasNote = exit.noteText != nil
        self.size = size
    }

    var body: some View {
        HStack(spacing: size * 0.5) {
            mark("bolt.fill", count: triggers, tint: Theme.warning)
            mark("figure.run", count: entries, tint: Theme.info)
            Image(systemName: hasNote ? "text.bubble.fill" : "text.bubble")
                .foregroundStyle(hasNote ? Color.white.opacity(0.85) : Color.white.opacity(0.25))
        }
        .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Триггеров: \(triggers), условий раннего входа: \(entries)"))
    }

    private func mark(_ symbol: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol)
            if count > 0 { Text(verbatim: "\(count)") }
        }
        .foregroundStyle(count > 0 ? tint : Color.white.opacity(0.25))
    }
}

/// «● Встала и пошла           через 2:00»: a condition for coming back early, readable at arm's length.
struct EarlyEntryPlate: View {
    let entry: EarlyEntry
    /// Mac: the trainer's words under the event, one line.
    var showsDetail = false
    var height: CGFloat = 44
    var digits: CGFloat = 22

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(entry.tone.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.event)
                    .font(.system(size: digits * 0.7, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if showsDetail, let detail = entry.detail {
                    Text(detail)
                        .font(.system(size: digits * 0.52))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            if let delay = entry.delay, delay > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("через")
                        .font(.system(size: digits * 0.55, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(DurationText.clock(delay))
                        .font(Theme.display(digits, weight: .bold))
                        .monospacedDigit()
                }
            } else {
                Text("сразу").font(Theme.display(digits * 0.8, weight: .bold))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: height)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// «⚑ Залаяла, завыла          не входить»: the trainer's rule against coming in, red.
struct DoNotEnterPlate: View {
    let rule: TrainingPlan.Rule
    var showsDetail = false
    var height: CGFloat = 44
    var digits: CGFloat = 22

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "flag.fill")
                .font(.system(size: digits * 0.5, weight: .semibold))
                .foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.title)
                    .font(.system(size: digits * 0.7, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if showsDetail, !rule.detail.isEmpty {
                    Text(rule.detail)
                        .font(.system(size: digits * 0.52))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            Text("не входить")
                .font(.system(size: digits * 0.68, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.danger)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, showsDetail ? 6 : 0)
        .frame(minHeight: height)
        .background(Theme.danger.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// «⚡ взять ключи, звякнуть ими»: what to take or do on the way out (no checkbox: nothing to tick off).
struct TriggerRow: View {
    let text: String
    var size: CGFloat = 15

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "bolt.fill").foregroundStyle(Theme.warning)
        }
        .font(.system(size: size, weight: .medium, design: .rounded))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The exit's notes folded into one line; a tap shows them all and folds them back.
struct FoldedNotes: View {
    let notes: [String]
    var size: CGFloat = 13
    @State private var expanded = false

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "text.bubble")
                VStack(alignment: .leading, spacing: 4) {
                    if expanded {
                        ForEach(notes, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                    } else {
                        Text(notes.joined(separator: " · ")).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: size * 0.8, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .font(.system(size: size, design: .rounded))
            .foregroundStyle(.white.opacity(0.6))
            .multilineTextAlignment(.leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? String(localized: "Свернуть заметки") : String(localized: "Развернуть заметки"))
    }
}

/// The trainer's text line by line: the lines of `exitNumber` (the exit and its conditions under it) marked pink and
/// brought into view when it changes (not otherwise: the reader's own scrolling stays where it is), exits before it
/// dimmed, the rule against coming in red. A plain stack: a lazy one measured the long lines only as they came into
/// view, and the text jumped under the finger.
struct TrainerTextView: View {
    let text: String
    let exitNumber: Int?
    var fontSize: CGFloat = 15

    var body: some View {
        let lines = PlanParser.sourceLines(text)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        row(line).id(line.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: exitNumber, initial: true) { _, number in
                guard let first = lines.first(where: { $0.kind == .exit && $0.exitNumber == number }) else { return }
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(first.id, anchor: UnitPoint(x: 0, y: 0.2)) }
            }
        }
    }

    @ViewBuilder
    private func row(_ line: PlanParser.SourceLine) -> some View {
        let current = line.exitNumber != nil && line.exitNumber == exitNumber
        let done = line.exitNumber.map { number in exitNumber.map { number < $0 } ?? false } ?? false
        if line.kind == .blank {
            Color.clear.frame(height: fontSize * 0.4)
        } else {
            Text(line.text)
                .font(.system(size: fontSize, weight: weight(line, current: current)))
                .foregroundStyle(color(line, current: current, done: done))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .padding(.horizontal, 10)
                .background(alignment: .leading) {
                    if current {
                        ZStack(alignment: .leading) {
                            Theme.accent.opacity(0.13)
                            Theme.accent.frame(width: 3)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .textSelection(.enabled)
        }
    }

    private func weight(_ line: PlanParser.SourceLine, current: Bool) -> Font.Weight {
        switch line.kind {
        case .header: return .bold
        case .exit: return current ? .bold : .semibold
        default: return .regular
        }
    }

    private func color(_ line: PlanParser.SourceLine, current: Bool, done: Bool) -> Color {
        if current { return .white }
        if done { return .white.opacity(0.35) }
        switch line.kind {
        case .header, .exit: return .white.opacity(0.9)
        case .earlyEntry, .breakTime: return .white.opacity(0.75)
        case .doNotEnter: return Theme.danger.opacity(0.95)
        case .falseStart: return Theme.warning.opacity(0.9)
        case .note, .blank: return .white.opacity(0.6)
        }
    }
}

/// «⚡ куртка · ключи   🏃 встала → 2:00 · легла → 0:30   📝» under an exit in the plan: everything the exit has
/// in words, with the empty categories as dimmed icons.
struct ExitSummaryText: View {
    let plan: TrainingPlan
    let exit: PlannedExit
    var size: CGFloat = 13

    var body: some View {
        let entries = plan.earlyEntries(of: exit)
        let dim = Color.white.opacity(0.3)
        var text = Text(Image(systemName: "bolt.fill")).foregroundColor(exit.triggers.isEmpty ? dim : Theme.warning)
            + Text(verbatim: " ")
            + Text(verbatim: exit.triggers.isEmpty ? "—" : exit.triggers.joined(separator: " · "))
                .foregroundColor(exit.triggers.isEmpty ? dim : .white.opacity(0.85))
            + Text(verbatim: "   ")
            + Text(Image(systemName: "figure.run")).foregroundColor(entries.isEmpty ? dim : Theme.info)
            + Text(verbatim: " ")
            + Text(verbatim: entries.isEmpty ? "—" : entries.map(\.summary).joined(separator: " · "))
                .foregroundColor(entries.isEmpty ? dim : .white.opacity(0.85))
        if plan.usesCommonEarlyEntries(exit) {
            text = text + Text(verbatim: " ") + Text("· общие").foregroundColor(dim)
        }
        text = text + Text(verbatim: "   ")
            + Text(Image(systemName: exit.noteText == nil ? "text.bubble" : "text.bubble.fill"))
                .foregroundColor(exit.noteText == nil ? dim : .white.opacity(0.85))
        return text
            .font(.system(size: size, design: .rounded))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }
}

// MARK: - Editing an exit's conditions

extension TrainingPlan {
    /// The conditions to edit for the exit at `index`: those it shows, without «до вставания» (the exit's own switch).
    func editableEarlyEntries(ofExitAt index: Int) -> [EarlyEntry] {
        guard exits.indices.contains(index) else { return [] }
        return earlyEntries(of: exits[index]).filter { $0.id != EarlyEntry.untilStanding.id }
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
