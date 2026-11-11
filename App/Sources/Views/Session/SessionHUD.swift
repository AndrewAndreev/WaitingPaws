import SwiftUI
import WaitingPawsCore

/// The iPhone's heads-up display for the running session: one card, top to bottom the same in an exit and in a break
/// — the plan as a strip of its exits, where we are («Выход 3», «Перерыв»), one quiet line about this exit, the big
/// number and the two buttons. The card keeps one height through the whole training, so the camera above never moves.
/// Nothing on it but the buttons is pressed: the exit's conditions are for reading (the trainer's whole text is a tap
/// away in the bar), and the only other control is a small neutral stopwatch beside the title.
struct SessionHUD: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let session: TrainingSession
    /// Smaller numbers and tighter spacing for shorter phones.
    var compact = false
    var onFinish: () -> Void
    /// The window's height: the card's limit at the accessibility sizes.
    @State private var windowHeight: CGFloat = 0

    var body: some View {
        let large = typeSize.isAccessibilitySize
        // The accessibility sizes: the card's words go on growing. Taller than this, the line about the exit and the
        // number scroll between the title and the buttons (`SessionReadout`), and the camera keeps the rest.
        // The card's own height up to the cap, whatever the camera above would like: offered less, its middle scrolled
        // with room to spare on a large iPhone (design council, round 13).
        CappedHeight(cap: large && windowHeight > 0 ? windowHeight * (verticalSizeClass == .compact ? 0.94 : 0.7) : nil,
                     claimsCap: verticalSizeClass != .compact) {
            GlassCard(padding: compact ? 14 : 18) {
                SessionReadout(session: session, size: compact ? .phoneCompact : .phone, onFinish: onFinish)
            }
        }
        .background {
            if large {
                Color.clear
                    .containerRelativeFrame(.vertical)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { windowHeight = $0 }
                    .accessibilityHidden(true)
            }
        }
    }
}


/// Its one view no taller than `cap` (nil: no limit), and only as tall as that view wants below it — `frame(maxHeight:)`
/// takes the whole limit whatever is in it.
private struct CappedHeight: Layout {
    var cap: CGFloat?
    /// Measured against the cap itself even where less is offered: upright, the camera over the card gives way (it is
    /// laid out after it); a parent that offers less — the side column of a phone on its side — is listened to.
    var claimsCap = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        return view.sizeThatFits(capped(proposal))
    }

    /// Placed with the height it was measured with, not its own size back: the card's `ViewThatFits` chose its layout
    /// for that, and offered its own height rounded to the screen's pixels — a fraction of a point less — it took the
    /// next one, the conditions in a scroll with room to spare (accessibility sizes: 538.36 pt measured, 538.33 given).
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading,
                              proposal: ProposedViewSize(width: bounds.width,
                                                         height: capped(proposal).height ?? bounds.height))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        guard let cap else { return proposal }
        return ProposedViewSize(width: proposal.width, height: claimsCap ? cap : min(proposal.height ?? cap, cap))
    }
}

/// The layer under an open drawer (the trainer's text): a tap on it closes the drawer, and what is under it is not
/// pressed. Over the buttons it is a dark veil — they are off until the drawer is closed; over the camera
/// `dims: false` keeps the picture as bright as before, the dog is what's watched.
struct ModalVeil<S: Shape>: View {
    var shape: S
    var dims = true
    var onClose: () -> Void

    var body: some View {
        shape
            .fill(dims ? Color.black.opacity(0.45) : Color.clear)
            .contentShape(shape)
            .onTapGesture(perform: onClose)
            .transition(.opacity)
            .accessibilityLabel("Close")
            .accessibilityAddTraits(.isButton)
            .accessibilityHidden(!dims)
    }
}

extension ModalVeil where S == Rectangle {
    init(dims: Bool = true, onClose: @escaping () -> Void) {
        self.init(shape: Rectangle(), dims: dims, onClose: onClose)
    }
}

extension Theme {
    /// Past the plan («+0:22», an exit or a break longer than planned): the orange it was before 1.7, the false start's
    /// (`Theme.warning`). The bright yellow of 1.7 was too loud on the timeline and the card (the owner, 2026-11-06).
    static let overtime = warning
}

/// What the training readout says, for the iPhone card and the Mac panel alike: the phase, the big number and what it
/// means (`Status`), what comes next and the same two buttons — "Вышли" (in a break) or "Вернулись" (outside), and
/// "Фальстарт".
struct ReadoutContent {
    /// The main button (Space on a computer).
    enum Step {
        case outside, backInside, finish

        var title: String {
            switch self {
            case .outside: return String(localized: "Outside|step")
            case .backInside: return String(localized: "Back Inside")
            case .finish: return String(localized: "Finish")
            }
        }

        /// The door with the arrow out of it or back in.
        var icon: StepIcon.Kind {
            switch self {
            case .outside: return .outside
            case .backInside: return .backInside
            case .finish: return .symbol("flag.checkered")
            }
        }

        /// The colour of the phase it starts: pink for an exit, blue for the break after it.
        var tint: Color { self == .backInside ? Theme.info : Theme.accent }
    }

    struct Timer {
        let text: String
        let caption: String
        let overdue: Bool
        /// Pink outside, blue in a break; past the plan orange (`Theme.overtime`), both.
        let tint: Color
        let progress: Double?
    }

    /// The big number and what it means, the one thing to read from behind the door: «Осталось 0:53», «Легла —
    /// входите через 0:12», «Можно входить», «Ждите тишины 0:18», «Сверх плана +0:05».
    struct Status: Equatable {
        enum Kind: Equatable {
            case ready, leaving, plan, overdue, counting, comeBackIn, comeBackAfter, canComeIn, waitForQuiet,
                 breakTime, breakOver, done
        }

        var kind: Kind
        /// Over the number: what it counts.
        var label: String
        /// The number («0:53», «+0:05») or, for `isWords`, words («Можно входить»).
        var value: String
        var isWords = false
        /// Beside the number, quiet: «план 1 мин», «тишина 0:12 из 0:30».
        var detail: String?
        /// The label and the progress line; the number takes it too past the plan and for a condition.
        var tint: Color
        var valueTint: Color = .white
        var progress: Double?
        /// Where the shown countdown reaches zero, or where the shown count-up began: a Live Activity counts on its own.
        var endsAt: Date?
        var countsUpFrom: Date?
        /// A sign before the label, in `tint`: the trainer's rule's ⊖ while the quiet is waited for.
        var symbol: String? = nil
        /// The label's own colour where it isn't `tint` (nil: `tint`, grey for the plan and a break — `shownLabelTint`):
        /// «Тихо — входите через» neutral, the red only on ⊖ and «тишина 0:18 из 0:30» (design council, round 8).
        var labelTint: Color? = nil
        /// The note's colour where it says the thing that still holds back (nil: the quiet grey of a note).
        var detailTint: Color? = nil
        /// `label` shorter, for a row too narrow for it beside a button: «Залаяла · 0:30 тишины» (nil: it shrinks).
        var shortLabel: String? = nil

        /// The colour the label is shown in.
        var shownLabelTint: Color {
            if let labelTint { return labelTint }
            return kind == .plan || kind == .breakTime ? .white.opacity(0.6) : tint
        }
    }

    /// What comes after this phase: «перерыв 2 мин · выход 4 — 45 с», in a break the next exit and its triggers.
    struct Next {
        var label: String
        var title: String?
        var triggers: [String] = []
        /// The part of `title` that is a repeat after a false start, «попытка 2»: shown in the false start's orange,
        /// as it is next to «Выход 3» outside (design council, round 9). `title` keeps it, for where it is one line.
        var attempt: String? = nil
    }

    let session: TrainingSession

    var isBreak: Bool {
        if case .breakTime = session.phase { return true }
        return false
    }

    var title: String {
        switch session.phase {
        case .ready, .leaving, .away:
            if session.currentExit?.isOpen == true { return String(localized: "Another Exit") }
            return String(localized: "Exit \(session.currentExit?.number ?? 0)")
        case .breakTime(_, _, _, let next):
            return next == nil ? String(localized: "Last Break") : String(localized: "Break")
        case .finished:
            return String(localized: "Done")
        }
    }

    /// «из 5» next to «Выход 3»: where in the schedule this is.
    var position: String? {
        switch session.phase {
        case .ready, .leaving, .away:
            guard session.currentExit?.isOpen == false else { return nil }
            return String(localized: "of \(session.plan.exits.count)")
        default:
            return nil
        }
    }

    /// "попытка 2" next to the title (outside; in a break it is part of the next exit's line).
    var attempt: String? {
        session.attempt > 1 && !isBreak ? String(localized: "attempt \(session.attempt)") : nil
    }

    var next: Next? {
        switch session.phase {
        case .ready, .leaving, .away:
            guard let index = session.currentExitIndex, session.currentExit?.isOpen == false else { return nil }
            let pause = DurationText.short(session.plan.breakAfter(exitAt: index))
            guard session.plan.exits.indices.contains(index + 1) else {
                return Next(label: String(localized: "Next"), title: String(localized: "last break \(pause)"))
            }
            let exit = session.plan.exits[index + 1]
            return Next(label: String(localized: "Next"),
                        title: String(localized: "break \(pause) · exit \(exit.number) — \(DurationText.short(exit.duration))"))
        case .breakTime(_, _, _, let next):
            guard let next, session.plan.exits.indices.contains(next) else {
                return Next(label: String(localized: "Next"), title: String(localized: "“Another Exit” or “Finish”"))
            }
            let exit = session.plan.exits[next]
            var title = String(localized: "exit \(exit.number) — \(DurationText.short(exit.duration))")
            let attempt = session.attempt > 1 ? String(localized: "attempt \(session.attempt)") : nil
            if let attempt { title += " · " + attempt }
            return Next(label: String(localized: "Next"), title: title, triggers: exit.triggers, attempt: attempt)
        case .finished:
            return nil
        }
    }

    var step: Step? {
        let phase = session.phase
        if case .away = phase { return .backInside }
        if phase.canGoOutside { return .outside }
        if case .breakTime = phase { return .finish }
        return nil
    }

    var canFalseStart: Bool { session.phase.canFalseStart }

    /// The exit a press of «Фальстарт» now counts against: outside the one under way, in a break (and before the first
    /// exit) the next one — the dog went to the door before «Вышли» (`TrainingSession.resetExit`).
    var falseStartExitNumber: Int? { canFalseStart ? session.currentExit?.number : nil }

    /// What VoiceOver says for it: «Фальстарт выхода 4».
    var falseStartAccessibilityLabel: String {
        falseStartExitNumber.map { String(localized: "False start of exit \($0)") } ?? String(localized: "False Start")
    }

    /// What a press does, for VoiceOver and the pointer's tip: in a break the break starts over (the dog went to the
    /// door before «Вышли»), outside the exit ends and is repeated after a break.
    var falseStartHint: String? {
        guard let number = falseStartExitNumber else { return nil }
        return isBreak ? String(localized: "The break starts over, exit \(number) after it")
                       : String(localized: "Exit \(number) will be repeated after a break")
    }

    /// The trainer's rule against coming in: ⊖, red, as on its chip.
    static let quietSymbol = "minus.circle.fill"
    /// A label that only says what the number is («Тихо — входите через»): neither «нельзя» nor «можно».
    static let neutralLabel = Color.white.opacity(0.72)

    /// Outside: how long «Фальстарт» still counts, by the trainer's rule («в первые 20 секунд…»); nil without one.
    func falseStartLeft(at now: Date) -> TimeInterval? {
        guard case .away = session.phase, let window = session.plan.falseStartWindow else { return nil }
        return window - session.elapsed(at: now)
    }

    /// «Фальстарт» is there: always in a break; outside until the trainer's window has passed.
    func showsFalseStart(at now: Date) -> Bool {
        guard canFalseStart else { return false }
        return (falseStartLeft(at: now) ?? 1) > 0
    }

    /// The break after the schedule's last exit: «Ещё выход» is offered next to «Завершить».
    var canStartOpenExit: Bool {
        if case .breakTime(_, _, _, nil) = session.phase { return true }
        return false
    }

    /// The plain timer (the trainer's text drawer, the minimized Mac panel): no conditions in it.
    func timer(at now: Date) -> Timer {
        let remaining = session.remaining(at: now)
        let overdue = (remaining ?? 0) < 0
        let tint: Color = overdue ? Theme.overtime : (isBreak ? Theme.info : Theme.accent)
        switch session.phase {
        case .ready:
            return Timer(text: DurationText.clock(session.currentExit?.duration ?? 0), caption: String(localized: "plan"),
                         overdue: false, tint: tint, progress: nil)
        case .leaving:
            return Timer(text: DurationText.clock(session.elapsed(at: now)), caption: String(localized: "to the door"),
                         overdue: false, tint: tint, progress: nil)
        case .away where session.currentExit?.isOpen == true:
            // An extra exit has no plan: its time counts up.
            return Timer(text: DurationText.clock(session.elapsed(at: now)), caption: String(localized: "elapsed"),
                         overdue: false, tint: Theme.accent, progress: nil)
        case .away, .breakTime:
            let value = remaining ?? 0
            return Timer(text: overdue ? "+" + DurationText.clock(-value) : DurationText.clock(value),
                         caption: overdue ? String(localized: "over plan") : String(localized: "left"),
                         overdue: overdue, tint: tint, progress: session.progress(at: now))
        case .finished:
            return Timer(text: "✓", caption: "", overdue: false, tint: Theme.accent, progress: nil)
        }
    }

    /// The big number with what the owner marked (`watch`): a condition's countdown or the quiet to wait for come
    /// before the plan's; past the plan it says so.
    func status(at now: Date, watch: ExitWatch?) -> Status {
        let remaining = session.remaining(at: now) ?? 0
        switch session.phase {
        case .ready:
            return Status(kind: .ready, label: String(localized: "Plan"),
                          value: DurationText.clock(session.currentExit?.duration ?? 0), tint: Theme.accent)
        case .leaving(_, let since):
            return Status(kind: .leaving, label: String(localized: "To the door"),
                          value: DurationText.clock(session.elapsed(at: now)), tint: Theme.accent, countsUpFrom: since)
        case .away(_, _, let leftAt):
            guard let exit = session.currentExit, !exit.isOpen else {
                return Status(kind: .counting, label: String(localized: "Elapsed"),
                              value: DurationText.clock(session.elapsed(at: now)), detail: String(localized: "no plan"),
                              tint: Theme.accent, countsUpFrom: leftAt)
            }
            let planEnd = now.addingTimeInterval(remaining)
            let planLeft = remaining >= 0 ? String(localized: "\(DurationText.clock(remaining)) left by plan")
                                          : String(localized: "over plan +\(DurationText.clock(-remaining))")
            let verdict = watch?.verdict(at: now, quietNeeded: session.plan.doNotEnterRule?.quietTime) ?? .plan
            switch verdict {
            case .comeBackIn(let left, let entry):
                let delay = entry.delay ?? left
                return Status(kind: .comeBackIn, label: String(localized: "\(entry.event) — come back in"),
                              value: DurationText.clock(left), detail: planLeft, tint: entry.tone.color,
                              valueTint: entry.tone.color, progress: delay > 0 ? 1 - left / delay : 1,
                              endsAt: now.addingTimeInterval(left))
            case .comeBackAfter(let words, let elapsed, let entry):
                return Status(kind: .comeBackAfter,
                              label: String(localized: "\(entry.event) \(DurationText.clock(elapsed)) ago, come back"),
                              value: words, isWords: true, detail: planLeft, tint: entry.tone.color,
                              valueTint: entry.tone.color, countsUpFrom: now.addingTimeInterval(-elapsed))
            case .canComeIn(let entry):
                return Status(kind: .canComeIn,
                              label: entry.map { String(localized: "\($0.event) — time's up") }
                                  ?? String(localized: "Quiet long enough"),
                              value: String(localized: "Come back now"), isWords: true, detail: planLeft,
                              tint: Theme.go, valueTint: Theme.go, progress: 1)
            case .barking(let needed):
                // Barking: nothing counts until the owner taps «Замолчала»; the label says what the trainer wants.
                // The one form of the event everywhere — «Залаяла», as on the chip, in the log and «Снова
                // залаяла» (design council, round 9: «Лает» beside «Залаяла, завыла» was a third form, and wrong
                // for a dog that howls).
                return Status(kind: .waitForQuiet,
                              label: needed.map { String(localized: "Barked · needs \(DurationText.clock($0)) of quiet") }
                                  ?? String(localized: "Barked"),
                              value: String(localized: "Wait for quiet|instruction"), isWords: true, detail: planLeft,
                              tint: Theme.danger, valueTint: Theme.danger, progress: 0, symbol: Self.quietSymbol,
                              shortLabel: needed.map { String(localized: "Barked · \(DurationText.clock($0)) of quiet") })
            case .waitForQuiet(let quiet, let needed):
                // The quiet counts from «Замолчала», said like a condition's countdown («Легла — входите через»):
                // «Тихо — входите через 0:12», and beside it how much quiet there has been, «тишина 0:18 из 0:30».
                // The words and the number neutral: she is quiet, things go well; the red is only the rule's ⊖ and
                // the quiet still missing (the note and the line), as «нельзя» is red and «можно» green everywhere.
                // Both in whole seconds of one rounding, so they add up to the quiet asked for (0:12 + 0:18 = 0:30).
                let quietShown = quiet.rounded(.down)
                guard let needed else {
                    return Status(kind: .waitForQuiet, label: String(localized: "Quiet"),
                                  value: DurationText.clock(quiet), detail: planLeft, tint: Theme.danger,
                                  countsUpFrom: now.addingTimeInterval(-quiet), symbol: Self.quietSymbol,
                                  labelTint: Self.neutralLabel)
                }
                let neededShown = needed.rounded(.down)
                return Status(kind: .waitForQuiet,
                              label: String(localized: "Quiet — come back in"),
                              value: DurationText.clock(max(0, neededShown - quietShown)),
                              detail: String(localized: "quiet \(DurationText.clock(quietShown)) of \(DurationText.clock(neededShown))"),
                              tint: Theme.danger, progress: quiet / needed,
                              endsAt: now.addingTimeInterval(needed - quiet), symbol: Self.quietSymbol,
                              labelTint: Self.neutralLabel, detailTint: Theme.danger)
            case .plan:
                break
            }
            if remaining < 0 {
                return Status(kind: .overdue, label: String(localized: "Over Plan"),
                              value: "+" + DurationText.clock(-remaining),
                              detail: String(localized: "plan \(DurationText.short(exit.duration))"),
                              tint: Theme.overtime, valueTint: Theme.overtime, progress: 1, countsUpFrom: planEnd)
            }
            return Status(kind: .plan, label: String(localized: "Left"), value: DurationText.clock(remaining),
                          detail: String(localized: "plan \(DurationText.short(exit.duration))"),
                          tint: Theme.accent, progress: session.progress(at: now), endsAt: planEnd)
        case .breakTime(_, _, let duration, _):
            if remaining < 0 {
                return Status(kind: .breakOver, label: String(localized: "Break over plan"),
                              value: "+" + DurationText.clock(-remaining),
                              detail: String(localized: "plan \(DurationText.short(duration))"),
                              tint: Theme.overtime, valueTint: Theme.overtime, progress: 1,
                              countsUpFrom: now.addingTimeInterval(remaining))
            }
            return Status(kind: .breakTime, label: String(localized: "Left"), value: DurationText.clock(remaining),
                          detail: String(localized: "break \(DurationText.short(duration))"), tint: Theme.info,
                          progress: session.progress(at: now), endsAt: now.addingTimeInterval(remaining))
        case .finished:
            return Status(kind: .done, label: "", value: "✓", tint: Theme.accent)
        }
    }
}

extension ReadoutContent {
    /// The iPhone's big number (the card's, the trainer's text's): the plan's own count — what the owner marked behind
    /// the door (`ExitWatch`) is the Mac's. Before the first exit the plan's time quiet, grey: nothing runs yet. After
    /// the schedule's last exit no exit is ahead to count down to: the break's own time counts up there, without a line.
    func phoneStatus(at now: Date) -> Status {
        if case .breakTime(_, let since, _, nil) = session.phase {
            return Status(kind: .breakTime, label: String(localized: "Elapsed"),
                          value: DurationText.clock(max(0, now.timeIntervalSince(since))),
                          tint: Theme.info, countsUpFrom: since)
        }
        var status = status(at: now, watch: nil)
        if status.kind == .ready { status.valueTint = .white.opacity(0.4) }
        return status
    }

    /// The colour of `phoneStatus` where it stands alone, small (the trainer's text): the phase's — pink outside, blue
    /// in a break, orange past the plan — and grey before the first exit.
    static func phaseColor(_ status: Status) -> Color {
        switch status.kind {
        case .ready: return .white.opacity(0.4)
        case .overdue, .breakOver: return Theme.overtime
        default: return status.tint
        }
    }

    /// «Выход 3» / «Перерыв» — the last break too: «Завершить» and «Ещё выход» under it say it is the last.
    var phoneTitle: String {
        if case .breakTime = session.phase { return String(localized: "Break") }
        return title
    }
}

/// The iPhone's readout, top to bottom: the plan's strip, where we are («Выход 3», «Перерыв»), one quiet line about
/// the exit, the big number and the two buttons — the same rows in every phase, each of one height, so the card is
/// one height from the first exit to the last break.
struct SessionReadout: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let session: TrainingSession
    var size: Size = .phone
    var onFinish: () -> Void

    /// When the stopwatch was started — a tap on the big number outside (nil: it isn't on). It belongs to the exit
    /// under way.
    @State private var stopwatchStart: Date?

    struct Size {
        var number: CGFloat
        var title: CGFloat
        var info: CGFloat
        var spacing: CGFloat
        var button: CGFloat
        /// The condition plates' height and the size of their time (no longer used by the iPhone's card).
        var plate: CGFloat
        var plateDigits: CGFloat
        /// More details than this scroll (no longer used by the iPhone's card).
        var detailsHeight: CGFloat
        /// The least height of the place of the line about the exit (no longer used by the iPhone's card: the line
        /// keeps the height of the plan's longest, `ExitLine`).
        var slot: CGFloat

        static let phone = Size(number: 64, title: 22, info: 15, spacing: 14, button: 52, plate: 44, plateDigits: 22,
                                detailsHeight: 300, slot: 105)
        static let phoneCompact = Size(number: 54, title: 20, info: 14, spacing: 11, button: 50, plate: 40,
                                       plateDigits: 20, detailsHeight: 220, slot: 105)
    }

    var body: some View {
        let content = ReadoutContent(session: session)
        let large = typeSize.isAccessibilitySize
        // A little closer at the accessibility sizes, where every point of the card is words.
        let spacing = large ? min(size.spacing, 10) : size.spacing
        VStack(alignment: .leading, spacing: spacing) {
            ExitStrip(session: session, scale: large ? min(TypeScale.factor(typeSize), 1.3) : 1)
                // The badges' room over the chips is room enough under the card's edge.
                .padding(.top, -6)
            header(content)
            if large || verticalSizeClass == .compact {
                // Where the card is limited (`SessionHUD` at the accessibility sizes, the side column of a phone on its
                // side): all of it if it fits, else the line about the exit and the number scroll between the title
                // and the buttons, opened at the number. The scroll takes all the room the card has in every phase
                // (one height still), so the line keeps only its own height there: in a break «⚡ взять ключи» just
                // over the number, in view, not at the top of the room an exit's three lines need.
                ViewThatFits(in: .vertical) {
                    middle(content, spacing: spacing)
                    FadingScroll(fromBottom: true) { middle(content, spacing: spacing, reserves: false) }
                }
            } else {
                middle(content, spacing: spacing)
            }
            ReadoutActions(session: session, height: size.button, onFinish: onFinish)
        }
        .onChange(of: stopwatchKey) { stopwatchStart = nil }
        .sensoryFeedback(.impact(weight: .light), trigger: stopwatchStart != nil)
        .onAppear {
            #if DEBUG
            // `--demo-stopwatch <seconds>`: the stopwatch started that long ago (outside).
            if let seconds = DemoData.stopwatchSeconds, session.phase.isOutside {
                stopwatchStart = Date().addingTimeInterval(-seconds)
            }
            #endif
        }
    }

    /// The line about the exit and the big number.
    private func middle(_ content: ReadoutContent, spacing: CGFloat, reserves: Bool = true) -> some View {
        let outside = session.phase.isOutside
        return VStack(alignment: .leading, spacing: spacing) {
            if ExitBrief.hasDetails(session.plan) {
                ExitLine(session: session, info: size.info, reserves: reserves)
            }
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                BigNumber(status: content.phoneStatus(at: context.date), size: size,
                          stopwatch: stopwatchStart.map { max(0, context.date.timeIntervalSince($0)) })
            }
            // Outside, a tap on the number starts a small stopwatch beside it, the next one puts it away: no button
            // for it on the card.
            .contentShape(Rectangle())
            .onTapGesture { if outside { toggleStopwatch() } }
            .accessibilityAction(named: Text("Stopwatch")) { if outside { toggleStopwatch() } }
        }
    }

    private func toggleStopwatch() {
        withAnimation(.smooth(duration: 0.2)) { stopwatchStart = stopwatchStart == nil ? Date() : nil }
    }

    /// «Выход 3» / «Перерыв» big; on the right, for a few seconds after «Фальстарт», the way back from it. The title
    /// grows with larger system text as the card's other words do (`TypeScale`), up to the same cap as the buttons' —
    /// and past it at the accessibility sizes. The row is one height whatever is on its right.
    private func header(_ content: ReadoutContent) -> some View {
        let large = typeSize.isAccessibilitySize
        let title = size.title * (large ? min(TypeScale.factor(typeSize), 1.6) : TypeScale.capped(typeSize))
        let accessory = 14 * TypeScale.capped(typeSize)
        return HStack(alignment: .center, spacing: 8) {
            Text(content.phoneTitle)
                .font(Theme.display(title, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if content.isBreak {
                UndoFalseStartButton(size: accessory)
                    .fixedSize()
            }
        }
        .frame(height: max(accessory * 2.1, title * 1.3))
    }

    /// The stopwatch is put away when the exit (or its attempt) is over.
    private var stopwatchKey: String {
        "\(session.currentExitIndex ?? -1)-\(session.attempt)-\(session.phase.isOutside)"
    }
}

/// One quiet line about the exit, for reading only — nothing on it is pressed. Outside: its conditions in their one
/// form, «встала и пошла 0:30 · легла 0:20 · ⊖ тишина 0:30» (`ConditionsLine`). Before it (in a break, before the
/// first exit): what to take or do on the way out, «⚡ взять ключи». The exit's own note after them. It wraps by whole
/// items rather than cutting one, and it is as tall as the longest such line of the plan: the card keeps one height
/// from exit to break, the line at the top of its place, right under the title. Empty where the exit has nothing.
private struct ExitLine: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let session: TrainingSession
    var info: CGFloat
    /// As tall as the plan's longest line (false: its own height).
    var reserves = true

    enum Item: Hashable {
        case condition(words: String, time: String?, rule: Bool)
        case triggers(String)
        case note(String)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Every line this plan can show, unseen: the place is as tall as the tallest.
            if reserves {
                ForEach(Array(Self.variants(of: session.plan).enumerated()), id: \.offset) { _, items in
                    line(items)
                        .hidden()
                        .accessibilityHidden(true)
                }
            }
            line(Self.items(for: session))
                .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var scale: CGFloat { TypeScale.factor(typeSize) }

    private func line(_ items: [Item]) -> some View {
        let size = (info - 1) * scale
        return SeparatedFlowLayout(spacing: 5 * min(scale, 1.4), lineSpacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { FlowDot() }
                view(item, size: size)
            }
        }
        .font(.system(size: size, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.62))
    }

    @ViewBuilder
    private func view(_ item: Item, size: CGFloat) -> some View {
        switch item {
        case .condition(let words, let time, let rule):
            ConditionsLine.item(words: words, time: time, size: size, rule: rule)
        case .triggers(let text):
            // The one thing to do before the exit: a little larger and brighter than the conditions.
            Label {
                Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "bolt.fill").foregroundStyle(Theme.warning)
            }
            .labelStyle(LineLabelStyle())
            .font(.system(size: info * scale, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.92))
        case .note(let text):
            Label {
                Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "text.bubble")
            }
            .labelStyle(LineLabelStyle())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    /// What the line says now: outside the exit's conditions, before it what to take; the note in both.
    static func items(for session: TrainingSession) -> [Item] {
        guard let brief = ReadoutContent(session: session).brief else { return [] }
        return session.phase.isOutside ? outside(brief) : before(brief)
    }

    /// All the lines the plan can show, each once.
    static func variants(of plan: TrainingPlan) -> [[Item]] {
        var seen = Set<[Item]>()
        var lines: [[Item]] = []
        for exit in plan.exits {
            let brief = ExitBrief(plan: plan, exit: exit)
            for items in [outside(brief), before(brief)] where !items.isEmpty && seen.insert(items).inserted {
                lines.append(items)
            }
        }
        return lines
    }

    private static func outside(_ brief: ExitBrief) -> [Item] {
        var items: [Item] = brief.entries.map { .condition(words: $0.conditionWords, time: $0.conditionTime, rule: false) }
        if let rule = brief.doNotEnter {
            items.append(.condition(words: rule.conditionWords, time: rule.conditionTime, rule: true))
        }
        if let note = brief.exit.noteText { items.append(.note(note)) }
        return items
    }

    private static func before(_ brief: ExitBrief) -> [Item] {
        var items: [Item] = brief.exit.triggers.isEmpty ? [] : [.triggers(brief.exit.triggers.joined(separator: " · "))]
        if let note = brief.exit.noteText { items.append(.note(note)) }
        return items
    }
}

/// A sign and words that wrap under the words, not under the sign.
private struct LineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

/// The big number alone — the time left; past the plan the time over it, «+0:05» in orange — and a thin line of
/// progress under it, pink in an exit, blue in a break. No words round it: the strip's lit chip says the plan, the
/// title what is counted. On its right, while it runs, the owner's stopwatch: «⏱ 0:12», small and grey.
private struct BigNumber: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let status: ReadoutContent.Status
    let size: SessionReadout.Size
    /// The stopwatch's time (nil: it isn't on).
    var stopwatch: TimeInterval?

    var body: some View {
        let number = size.number * min(TypeScale.factor(typeSize), 1.12)
        let small = size.info * TypeScale.capped(typeSize)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(status.value)
                    // Before the first exit, not running: grey and a little lighter (`phoneStatus`).
                    .font(Theme.display(number, weight: status.kind == .ready ? .semibold : .bold))
                    .monospacedDigit()
                    .foregroundStyle(status.valueTint)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if let stopwatch {
                    Label {
                        Text(verbatim: DurationText.clock(stopwatch))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "stopwatch")
                    }
                    .labelStyle(LineLabelStyle())
                    .font(.system(size: small, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
                }
            }
            // Digits have no descenders: the line's room under them is left out, the number keeps its size.
            .frame(height: number * 1.08)
            // Nothing to fill toward (before the first exit, an extra exit, the last break): no line, its place kept.
            ProgressLine(progress: status.progress, tint: status.tint)
                .opacity(status.progress == nil ? 0 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [status.label, status.value,
                                            stopwatch.map { String(localized: "Stopwatch") + " " + DurationText.clock($0) }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")))
    }
}

/// «Отменить» in the title's row for a few seconds after «Фальстарт» (its break), then gone — a toast, not a part of
/// the card; the way back stays in the model until the next exit starts (`AppModel.falseStartUndo`). Grey with white
/// words, no ↺: the orange and the ↺ are «Фальстарт»'s alone, so it can't be taken for a second false start.
private struct UndoFalseStartButton: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat

    /// How long it is shown after the press.
    static let shownFor: TimeInterval = 10

    var body: some View {
        if let undo = model.falseStartUndo {
            TimelineView(.periodic(from: undo.pressedAt, by: 1)) { context in
                let shown = context.date.timeIntervalSince(undo.pressedAt) < Self.shownFor
                Group {
                    if shown {
                        Button {
                            withAnimation(.smooth(duration: 0.25)) { model.undoFalseStart() }
                        } label: {
                            Text("Cancel|verb")
                                .font(.system(size: size, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .padding(.horizontal, size * 0.85)
                                .frame(minHeight: size * 2.1)
                                .background(Theme.control, in: Capsule())
                                .contentShape(Rectangle().inset(by: -7))
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel(String(localized: "Undo the false start of exit \(undo.exitNumber)"))
                        .transition(.opacity)
                    }
                }
                .animation(.smooth(duration: 0.3), value: shown)
            }
        }
    }
}

/// What scrolls inside the card at the accessibility sizes: an edge fades while there is more past it — a row cut
/// there reads as «more», not as a broken card — and is sharp once the end is in view (iOS 18 and later; before, the
/// far edge always fades, and the room past the content lets its last row clear the fade). `fromBottom`: it opens
/// scrolled to its end — where only the card's middle scrolls, the big number at its end stays in view over
/// «Дальше», the conditions above it a scroll away.
private struct FadingScroll<Content: View>: View {
    var fromBottom = false
    @ViewBuilder var content: Content
    @State private var more: ScrollMore?

    var body: some View {
        let more = more ?? ScrollMore(above: fromBottom, below: !fromBottom)
        ScrollView {
            content
                .padding(fromBottom ? .top : .bottom, scrollFade)
        }
        .scrollBounceBehavior(.basedOnSize)
        .modifier(ScrollAnchors(fromBottom: fromBottom))
        .modifier(ScrollEndWatch(room: scrollFade, fromBottom: fromBottom, more: $more))
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: more.above ? scrollFade : 0)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: more.below ? scrollFade : 0)
            }
        }
        .animation(.smooth(duration: 0.2), value: more)
    }
}

/// Where `FadingScroll` opens (its end, `fromBottom`) and, what is shorter than it, where that sits: at its top, under
/// the title — in a break «⚡ взять ключи» right under «Перерыв» (iOS 18 and later; before, at the end it opens at).
private struct ScrollAnchors: ViewModifier {
    var fromBottom: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content
                .defaultScrollAnchor(fromBottom ? .bottom : .top, for: .initialOffset)
                .defaultScrollAnchor(fromBottom ? .bottom : .top, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .alignment)
        } else {
            content.defaultScrollAnchor(fromBottom ? .bottom : .top)
        }
    }
}

/// The height of `FadingScroll`'s fades, and of the room past its content.
private let scrollFade: CGFloat = 22

/// Whether a scroll view has more above and below what it shows.
private struct ScrollMore: Equatable {
    var above: Bool
    var below: Bool
}

/// Watches a scroll view's edges (iOS 18 and later; before, `more` stays nil).
private struct ScrollEndWatch: ViewModifier {
    /// The room past the content (`FadingScroll`), not counted as more.
    var room: CGFloat
    var fromBottom: Bool
    @Binding var more: ScrollMore?

    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content
                .onScrollGeometryChange(for: ScrollMore.self) { geometry in
                    let top = fromBottom ? room : 0
                    let bottom = fromBottom ? 0 : room
                    return ScrollMore(above: geometry.contentOffset.y > top + 1,
                                      below: geometry.contentOffset.y + geometry.containerSize.height
                                          < geometry.contentSize.height - bottom - 1)
                } action: { _, value in
                    more = value
                }
        } else {
            content
        }
    }
}

/// A thin capsule filled to `progress` (nil: only the track).
struct ProgressLine: View {
    var progress: Double?
    var tint: Color
    var height: CGFloat = 4

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.12))
            .overlay(alignment: .leading) {
                if let progress {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(tint)
                            .frame(width: max(height, geometry.size.width * min(1, max(0, progress))))
                    }
                }
            }
            .frame(height: height)
            .animation(.linear(duration: 0.25), value: progress)
    }
}

/// Larger system text makes the card's words larger too; the big number grows less (it is large already) and the
/// card keeps one height per text size. The accessibility sizes go on to 2×: there the card's buttons go one under
/// the other, and its middle scrolls when it must (`SessionHUD`).
enum TypeScale {
    static func factor(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall, .small, .medium, .large: return 1
        case .xLarge: return 1.08
        case .xxLarge: return 1.16
        case .xxxLarge: return 1.24
        case .accessibility1: return 1.4
        case .accessibility2: return 1.55
        case .accessibility3: return 1.7
        case .accessibility4: return 1.85
        case .accessibility5: return 2
        @unknown default: return 1.32
        }
    }

    /// For words that are large already and sit side by side in a fixed width — «Выход 3», the two buttons'
    /// «Вернулись» and «Фальстарт»: they grow with the text up to 1.24× (xxxLarge) and no further, so two still fit
    /// in a row on a small iPhone (design council, round 7). Where they get a row of their own at the accessibility
    /// sizes, they grow on (`BigButton.growsWithText`).
    static func capped(_ size: DynamicTypeSize) -> CGFloat { min(factor(size), 1.24) }
}

/// The two buttons: the next step — «Вышли» (pink, toward an exit), «Вернулись» outside (blue, toward the break) —
/// and «Фальстарт», orange as a false start is everywhere (not before the first exit: nothing to repeat yet). Outside,
/// «Фальстарт» counts down the trainer's window («в первые 20 секунд…») with a line running out under its word, and
/// then folds away, the step taking the whole row. After the schedule's last exit: «Завершить» in the step's place and
/// «Ещё выход» (an extra one without a planned time) beside it — a training ends only with that. At the accessibility
/// sizes one under the other, their words growing on; there a folded «Фальстарт» keeps its place, so the card doesn't
/// change its height.
struct ReadoutActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let session: TrainingSession
    var height: CGFloat = 52
    var onFinish: () -> Void

    var body: some View {
        let content = ReadoutContent(session: session)
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        // Before the first exit nothing has gone wrong yet: no «Фальстарт» there.
        let beforeFirst: Bool = if case .ready = session.phase { true } else { false }
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let falseStartLeft = content.falseStartLeft(at: context.date)
            let showsFalseStart = content.showsFalseStart(at: context.date) && !beforeFirst
            layout {
                if let step = content.step {
                    BigButton(title: step.title, icon: step.icon, style: step == .backInside ? .rest : .primary,
                              height: height, growsWithText: stacked) {
                        switch step {
                        case .outside: session.markBehindDoor()
                        case .backInside: session.endExit()
                        case .finish: onFinish()
                        }
                    }
                }
                if showsFalseStart {
                    falseStartButton(content, stacked: stacked)
                        .overlay(alignment: .bottom) {
                            if let falseStartLeft, let window = session.plan.falseStartWindow {
                                // How long it still counts: a line running out under the word.
                                Capsule()
                                    .fill(Theme.warning.opacity(0.7))
                                    .frame(height: 3)
                                    .scaleEffect(x: max(0, falseStartLeft / window), anchor: .leading)
                                    .padding(.horizontal, 18)
                                    .padding(.bottom, 7)
                                    .animation(.linear(duration: 0.5), value: falseStartLeft)
                            }
                        }
                        .transition(.scale(scale: 0.4, anchor: .trailing).combined(with: .opacity))
                } else if stacked, content.canFalseStart {
                    falseStartButton(content, stacked: true)
                        .hidden()
                        .accessibilityHidden(true)
                }
                // After the last exit «Завершить» keeps the main button's place, «Ещё выход» beside it.
                if content.canStartOpenExit {
                    BigButton(title: String(localized: "Another Exit"), icon: .outside, style: .secondary, height: height,
                              growsWithText: stacked) {
                        session.startOpenExit()
                    }
                }
            }
            .animation(.smooth(duration: 0.35), value: showsFalseStart)
        }
    }

    /// «Фальстарт» — the exit it is about is the one the card shows (the pink chip); VoiceOver hears its number.
    private func falseStartButton(_ content: ReadoutContent, stacked: Bool) -> some View {
        BigButton(title: String(localized: "False Start"), systemImage: "arrow.uturn.backward", style: .caution,
                  height: height, growsWithText: stacked) {
            model.falseStart()
        }
        .accessibilityLabel(content.falseStartAccessibilityLabel)
        .accessibilityHint(content.falseStartHint ?? "")
    }
}

/// One chip per exit — its time, «доп.» for an extra one — and the breaks as thin gaps between them: the whole plan
/// and where the training is in it, without a sentence. Done exits dimmed, the current one pink (in a break the next
/// one, and the gap before it lit blue: the break under way). The exit repeated after a false start has the false
/// start's ↺ in its chip and an orange rim. A badge on the corner of a chip still ahead: ⚡ the exit has triggers, 🏃 it
/// may end before its plan (`TrainingPlan.canEndEarly`) — on the corner, not after the time, so the strip stays as wide
/// as the plan. A plan wider than the card scrolls, the current chip brought to the middle, and an edge fades while
/// there is more past it.
struct ExitStrip: View {
    let session: TrainingSession
    /// Mac: bigger chips for the wider panel.
    var large = false
    /// A little lower: just the room the badges need over the chips and none under them.
    var dense = false
    /// The accessibility sizes: the chips grow with the card's words, less than they do.
    var scale: CGFloat = 1

    @State private var more = ScrollMore(above: false, below: false)

    private enum ChipState { case done, current, upcoming }

    var body: some View {
        let exits = session.plan.exits
        let lit = litGap
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    // A false start before the first exit: its break is before the strip's first chip.
                    if lit == 0 { breakGap(nil, highlighted: true) }
                    ForEach(Array(exits.enumerated()), id: \.element.id) { index, exit in
                        chip(exit, state: state(for: index))
                            .id(exit.id)
                        if index < exits.count - 1 {
                            breakGap(session.plan.breakAfter(exitAt: index), highlighted: lit == index + 1)
                        }
                    }
                    // The last break, after the schedule's last exit.
                    if let lit, lit >= exits.count, !exits.isEmpty { breakGap(nil, highlighted: true) }
                }
                // Room for the badges over the chips' corners and past the last one's, and for the rim of a repeated
                // exit's chip: the scroll view clips what sticks out.
                .padding(.top, badgeSize * 0.6 + (dense ? 0.5 : 2))
                .padding(.bottom, dense ? 0 : 3)
                .padding(.leading, 3)
                .padding(.trailing, badgeSize)
            }
            .modifier(HorizontalScrollEdges(more: $more))
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: more.above ? stripFade : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: more.below ? stripFade : 0)
                }
            }
            .animation(.smooth(duration: 0.2), value: more)
            .onChange(of: session.currentExitIndex ?? -1, initial: true) { _, index in
                guard exits.indices.contains(index) else { return }
                withAnimation { proxy.scrollTo(exits[index].id, anchor: .center) }
            }
            .onAppear {
                // Laid out by now: the current chip in the middle from the start.
                guard let index = session.currentExitIndex, exits.indices.contains(index) else { return }
                DispatchQueue.main.async { proxy.scrollTo(exits[index].id, anchor: .center) }
            }
        }
    }

    private var badgeSize: CGFloat { (large ? 16 : 13) * scale }
    private var stripFade: CGFloat { 22 * scale }

    /// In a break, the exit the lit gap leads to: the next one — after a false start the same exit again, so the gap
    /// lit is the one before it, not the one after it — or past the strip's end after the last exit. Nil outside.
    private var litGap: Int? {
        guard case .breakTime(let after, _, _, let next) = session.phase else { return nil }
        return next ?? (after + 1)
    }

    private func chip(_ exit: PlannedExit, state: ChipState) -> some View {
        // Exits done have nothing ahead to prepare or watch for: no badges.
        let triggers = !exit.triggers.isEmpty && state != .done
        let early = session.plan.canEndEarly(exit) && state != .done
        // The exit is being repeated after a false start: the false start's ↺, and its orange round the chip.
        let retry = state == .current && session.attempt > 1
        let font = (large ? 14 : 12) * scale
        return HStack(spacing: 2 * scale) {
            if retry {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: font * 0.82, weight: .bold))
            }
            Text(exit.isOpen ? String(localized: "extra") : DurationText.compact(exit.duration))
        }
            .font(.system(size: font, weight: .semibold, design: .rounded).monospacedDigit())
            .padding(.horizontal, (large ? 10 : 8) * scale)
            .padding(.vertical, (large ? 6 : dense ? 4 : 5) * scale)
            .background(state == .current ? Theme.accent : Theme.control, in: Capsule())
            .foregroundStyle(state == .current ? .black : .white)
            .overlay {
                if retry {
                    Capsule().strokeBorder(Theme.warning, lineWidth: 1.5).padding(-2.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if triggers || early {
                    // Two side by side, their rings apart — never one over the other; a pair reaches a little further
                    // past the corner, short of the next chip. A little over the chip's top edge, clear of its time.
                    HStack(spacing: 3.5) {
                        if triggers { badge("bolt.fill", Theme.warning) }
                        if early { badge("figure.run", Theme.info) }
                    }
                    .fixedSize()
                    .offset(x: badgeSize * (triggers && early ? 0.7 : 0.4), y: -badgeSize * 0.6)
                }
            }
            .opacity(state == .done ? 0.35 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(chipLabel(exit, triggers: triggers, early: early, retry: retry))
    }

    /// A coloured circle with a black symbol, ringed in the card's colour so it stands off the chip.
    private func badge(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: badgeSize * 0.58, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: badgeSize, height: badgeSize)
            .background(tint, in: Circle())
            .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 1.5).padding(-1.5))
    }

    private func chipLabel(_ exit: PlannedExit, triggers: Bool, early: Bool, retry: Bool) -> String {
        var parts = [String(localized: "Exit \(exit.number)"),
                     exit.isOpen ? String(localized: "no set time") : DurationText.short(exit.duration)]
        if retry { parts.append(String(localized: "attempt \(session.attempt)")) }
        if triggers { parts.append(String(localized: "triggers")) }
        if early { parts.append(String(localized: "may come back early")) }
        return parts.joined(separator: ", ")
    }

    /// A break: a thin line as long as the break (within limits); the one under way blue, thicker and at least as long
    /// as a short chip, so it reads at a glance.
    private func breakGap(_ duration: TimeInterval?, highlighted: Bool) -> some View {
        let plain = max(6, min(large ? 28 : 22, (duration ?? 0) / 20))
        return Capsule()
            .fill(highlighted ? Theme.info : Color.white.opacity(0.18))
            .frame(width: highlighted ? max(plain, (large ? 22 : 16) * scale) : plain, height: highlighted ? 3 : 2)
    }

    private func state(for index: Int) -> ChipState {
        guard let current = session.currentExitIndex else { return .done }
        if index < current { return .done }
        if index == current { return .current }
        return .upcoming
    }
}

/// Whether a horizontal scroll view has more before (`above`) and after (`below`) what it shows (iOS 18 and later;
/// before, neither — no fades).
private struct HorizontalScrollEdges: ViewModifier {
    @Binding var more: ScrollMore

    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content
                .onScrollGeometryChange(for: ScrollMore.self) { geometry in
                    ScrollMore(above: geometry.contentOffset.x > 1,
                               below: geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1)
                } action: { _, value in
                    more = value
                }
        } else {
            content
        }
    }
}

/// Shown right after a session finishes: when and how long, the numbers (exits done, the longest one, false starts
/// when there were any), the plan and fact of each exit as a table, and the next thing to do — send the log to the
/// trainer, the one button. No sentence about the training: the table says it. ✕ closes it (the main screen has «Новая
/// тренировка»); the history is in the top bar.
struct SummaryCard: View {
    @Environment(AppModel.self) private var model
    let record: TrainingRecord
    var onClose: () -> Void
    /// The history (no longer offered on the card: the top bar has it).
    var onHistory: () -> Void

    var body: some View {
        let log = SessionLogFormatter.text(for: record)
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Training Complete")
                            .font(Theme.display(22, weight: .bold))
                        Text(verbatim: Self.when(record))
                            .font(.system(.subheadline, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    IconButton(systemImage: "xmark", label: String(localized: "Close"), action: onClose)
                }

                HStack(alignment: .top, spacing: 22) {
                    stat(String(localized: "\(record.completedExits) of \(record.plan.exits.count)"), String(localized: "exits"))
                    if let longest = record.longestResult, longest.awayDuration > 0 {
                        stat(DurationText.clock(longest.awayDuration), String(localized: "longest"))
                    }
                    if record.falseStarts > 0 {
                        stat("\(record.falseStarts)", CountText.falseStartWord(record.falseStarts), tint: Theme.warning)
                    }
                }

                ResultsTable(record: record, limit: 5)
                    .padding(12)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                // No video, no line: «Запись не включали» said what was never there.
                if RecordingReport(record: record, model: model).kind != .none {
                    recordingLine
                }
                if let name = record.recordingFileName, let error = model.photosStatus(for: name).error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Theme.warning)
                }

                ShareLink(item: log, preview: SharePreview(record.plan.displayTitle)) {
                    Label("Send to Trainer", systemImage: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    /// What goes to the trainer, as a table: plan and fact of each attempt in the same columns, a repeat named as one
    /// («Выход 7 · попытка 2»), a false start in orange, and under an exit what the owner marked behind the door —
    /// moments, «легла на 0:43», wrapping by whole marks. The full text is what «Отправить тренеру» sends.
    private struct ResultsTable: View {
        let record: TrainingRecord
        var limit: Int

        var body: some View {
            let shown = Array(record.results.prefix(limit))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("Exits").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Plan").gridColumnAlignment(.trailing)
                    Text("Actual").gridColumnAlignment(.trailing)
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                ForEach(shown) { result in
                    GridRow {
                        HStack(spacing: 5) {
                            Text("Exit \(result.number)")
                            if result.attempt > 1 {
                                Text("· attempt \(result.attempt)").foregroundStyle(Theme.warning)
                            }
                            if result.falseStart {
                                Text("false start").foregroundStyle(Theme.warning)
                            }
                        }
                        .lineLimit(1)
                        Text(result.isOpen ? "—" : DurationText.clock(result.plannedDuration))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(DurationText.clock(result.awayDuration))
                            .fontWeight(.semibold)
                            .foregroundStyle(result.falseStart ? Theme.warning : .white)
                    }
                    .font(.system(size: 14, design: .rounded).monospacedDigit())
                    // What the owner marked, and when: the reason behind a return. The whole row's width, so it
                    // wraps instead of being cut; a row without marks stays one line.
                    let marks = SummaryCard.marks(of: result, in: record)
                    if !marks.isEmpty {
                        GridRow {
                            // By whole marks, a «·» only between two on one line: none ends or starts a line.
                            SeparatedFlowLayout(spacing: 4, lineSpacing: 1) {
                                ForEach(Array(marks.enumerated()), id: \.offset) { index, mark in
                                    if index > 0 { FlowDot() }
                                    Text(verbatim: mark)
                                }
                            }
                            .font(.system(size: 13, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 10)
                            .padding(.top, -3)
                            .padding(.bottom, 2)
                            .gridCellColumns(3)
                        }
                    }
                }
                if record.results.count > shown.count {
                    GridRow {
                        Text("\(record.results.count - shown.count) more")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                            .gridCellColumns(3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "Log for the Trainer"))
        }
    }

    /// What became of the video, in one quiet line whatever it was (design council, round 8: the finish said nothing
    /// without a recording, and the start promises «тренировку и запись»): «Готовим видео…» while the file is being
    /// finished, then the history's own words (`RecordingReport`) — «Видео сохранено» (in Photos too, when it went
    /// there), «Видео сохранено · запись прерывалась в 18:44 на 2:10» with which exits are in it under that,
    /// «Запись не включали», «Видео — в истории на Mac», «Видео не записалось», «Файл видео удалён».
    private var recordingLine: some View {
        let report = RecordingReport(record: record, model: model)
        let name = record.recordingFileName
        let preparing = name.map { model.finalizingFileNames.contains($0) } ?? false
        let inPhotos = name.map { model.photosStatus(for: $0).saved } ?? false
        let text: String
        var detail: String?
        if preparing {
            text = String(localized: "Preparing video…")
        } else {
            switch report.kind {
            case .whole:
                text = inPhotos ? String(localized: "Video saved to Photos") : String(localized: "Video saved")
            case .partial:
                let how = report.text.prefix(1).lowercased() + String(report.text.dropFirst())
                text = String(localized: "Video saved · \(how)")
                detail = report.detail
            default:
                text = report.text
            }
        }
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: text)
                if let detail { Text(verbatim: detail) }
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: preparing ? "hourglass" : report.systemImage)
        }
        .font(.system(.footnote, design: .rounded))
        .foregroundStyle(.white.opacity(0.6))
    }

    /// The plan's name as the trainer titled it, without the trainer's date («05.10.2026 · …» was a second date in
    /// another format next to the day it was done); nil when it only says «Тренировка».
    static func planName(_ record: TrainingRecord) -> String? {
        let name = record.plan.title.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == TrainingPlan.defaultTitle ? nil : name
    }

    /// When, and how long: «Ср, 4 нояб. · 22:22–22:37 · 15 мин» (a lone «14:41» read as a time of day).
    static func when(_ record: TrainingRecord) -> String {
        let minutes = DurationText.short(max(60, (record.duration / 60).rounded() * 60))
        return "\(HistoryDate.day(record.startedAt)) · \(HistoryDate.time(record.startedAt))–\(HistoryDate.time(record.finishedAt)) · \(minutes)"
    }

    /// What the owner marked during this attempt, in the core's one form for a mark («легла на 0:43», «залаяла на
    /// 1:24»: moments from behind the door, as the log, the history and the Mac say them). Each mark unbroken, so a
    /// line wraps between marks.
    static func marks(of result: ExitResult, in record: TrainingRecord) -> [String] {
        SessionLogFormatter.observations(of: result, in: record).map(HistoryText.unbroken)
    }

    /// One neutral sentence about the training that the numbers above don't already say: which exits were false
    /// starts («Фальстарт на выходе 7»), which ended before their plan («Выход 3 короче плана: 0:43 из 1:00»), or
    /// that none did and by how much they ran over («Все выходы — до конца плана, в среднем +0:03»: said as what
    /// happened, design council, round 9 — «не короче плана» read as a report of a fault). Only what the times show:
    /// the trainer's conditions and rule aren't checked here, so nothing claims they were kept («по плану»). Never
    /// «без фальстартов» under «0 фальстартов».
    static func insight(_ record: TrainingRecord) -> String? {
        var falseStarts: [Int] = []
        for result in record.results where result.falseStart && !falseStarts.contains(result.number) {
            falseStarts.append(result.number)
        }
        if !falseStarts.isEmpty {
            let numbers = falseStarts.map(String.init).joined(separator: ", ")
            // One false start and its exit done after it: how («со второй попытки — 2:32», as the history's card
            // says it; Opus, round 10).
            if falseStarts.count == 1,
               let retry = record.results.last(where: { $0.number == falseStarts[0] && !$0.falseStart && $0.leftAt != nil }),
               let attempt = HistoryText.fromAttempt(retry.attempt) {
                // Where it wraps, «со второй попытки — 2:32» goes to the next line whole.
                let whole = attempt.replacingOccurrences(of: " ", with: "\u{00A0}")
                return String(localized: "False start on exit \(numbers), \(whole) — \(DurationText.clock(retry.awayDuration))")
                    .replacingOccurrences(of: " — ", with: "\u{00A0}—\u{00A0}")
            }
            return falseStarts.count == 1 ? String(localized: "False start on exit \(numbers)")
                                          : String(localized: "False starts on exits \(numbers)")
        }
        let planned = record.results.filter { !$0.isOpen && !$0.falseStart && $0.leftAt != nil && $0.plannedDuration > 0 }
        let short = planned.filter { $0.awayDuration < $0.plannedDuration - 1 }
        if short.count == 1, let exit = short.first {
            return String(localized: "Exit \(exit.number) shorter than planned: \(DurationText.clock(exit.awayDuration)) of \(DurationText.clock(exit.plannedDuration))")
        }
        if short.count > 1 {
            return String(localized: "Shorter than planned: exits \(short.map { String($0.number) }.joined(separator: ", "))")
        }
        guard !planned.isEmpty, record.completedExits >= record.plan.exits.count else { return nil }
        let over = planned.map { $0.awayDuration - $0.plannedDuration }.reduce(0, +) / Double(planned.count)
        return over >= 1 ? String(localized: "Every exit ran its full plan, +\(DurationText.clock(over)) on average")
                         : String(localized: "Every exit ran its full plan")
    }

    /// The exit lines of the log, without its title and date lines (the card says those).
    static func preview(of log: String) -> String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.dropFirst(min(2, max(0, lines.count - 1))).joined(separator: "\n")
    }

    private func stat(_ value: String, _ label: String, tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Theme.display(22, weight: .bold)).monospacedDigit().foregroundStyle(tint)
            // Two lines rather than «план 2…» with larger text.
            Text(label).font(.system(.caption, design: .rounded)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
