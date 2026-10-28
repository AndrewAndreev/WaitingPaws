import SwiftUI
import WaitingPawsCore

/// The iPhone's heads-up display for the running session: the shared readout on a card. The card keeps one height:
/// the exit's conditions, triggers and notes are a row of chips in it; pulled up (or the row tapped) they open in full
/// above the card like a drawer, over the camera, and go back down the same way. Nothing a press shows resizes the
/// card, so the camera above and the buttons below stay put; and the card is no taller than it needs to be.
struct SessionHUD: View {
    let session: TrainingSession
    /// Smaller ring and tighter spacing for portrait phones.
    var compact = false
    var onFinish: () -> Void

    #if DEBUG
    // `--demo-details`: the details open above the card (UI checks).
    @State private var expanded = CommandLine.arguments.contains("--demo-details")
    #else
    @State private var expanded = false
    #endif
    @GestureState private var drag: CGFloat = 0
    @State private var panelHeight: CGFloat = 0

    var body: some View {
        let size: SessionReadout.Size = compact ? .phoneCompact : .phone
        let content = ReadoutContent(session: session)
        let hasDetails = ExitBrief.hasDetails(session.plan)
        GlassCard(padding: compact ? 14 : 18) {
            SessionReadout(session: session, size: size, onFinish: onFinish,
                           onDetails: hasDetails ? { withAnimation(.smooth(duration: 0.3)) { expanded.toggle() } } : nil)
        }
        .overlay(alignment: .top) {
            if hasDetails {
                grabber
                    .padding(.top, 5)
            }
        }
        .overlay(alignment: .top) {
            if expanded, let brief = content.brief, !brief.isEmpty(inBreak: content.isBreak) {
                ExitDetailsPanel(brief: brief, isBreak: content.isBreak, size: size, maxDetailsHeight: compact ? 300 : 380,
                                 onClose: { withAnimation(.smooth(duration: 0.3)) { expanded = false } })
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { panelHeight = $0 }
                    // Above the card, over the camera: its bottom edge just over the card's top edge.
                    .offset(y: -panelHeight + 12 + max(0, drag))
                    .transition(.opacity.combined(with: .offset(y: 30)))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .updating($drag) { value, state, _ in if expanded { state = value.translation.height } }
                .onEnded { value in
                    guard hasDetails, abs(value.translation.height) > abs(value.translation.width) else { return }
                    withAnimation(.smooth(duration: 0.3)) {
                        if value.predictedEndTranslation.height < -40 { expanded = true }
                        if value.predictedEndTranslation.height > 60 { expanded = false }
                    }
                },
            including: hasDetails ? .all : .subviews
        )
    }

    /// The handle at the card's top edge: pull up for the details, down to put them away.
    private var grabber: some View {
        Capsule()
            .fill(.white.opacity(expanded ? 0.5 : 0.28))
            .frame(width: 36, height: 4)
            .accessibilityLabel(expanded ? "Свернуть подробности выхода" : "Развернуть подробности выхода")
            .accessibilityAddTraits(.isButton)
            .onTapGesture { withAnimation(.smooth(duration: 0.3)) { expanded.toggle() } }
    }
}

/// The exit's details in full, above the readout card: when to come back early, when not to come in and the notes
/// outside; what to take for the next exit in a break.
private struct ExitDetailsPanel: View {
    let brief: ExitBrief
    let isBreak: Bool
    let size: SessionReadout.Size
    /// More than this scrolls (the panel must leave some of the camera).
    var maxDetailsHeight: CGFloat
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isBreak ? String(localized: "К выходу \(brief.exit.number)") : String(localized: "Выход \(brief.exit.number)"))
                    .font(Theme.display(17, weight: .bold))
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 32, height: 32)
                        .background(Theme.control, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Свернуть подробности выхода")
            }
            ScrollView { details }
                .frame(maxHeight: maxDetailsHeight)
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 16, y: -2)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isBreak {
                ForEach(Array(brief.exit.triggers.enumerated()), id: \.offset) { _, trigger in
                    TriggerRow(text: trigger, size: size.info)
                        .padding(.horizontal, 12)
                        .frame(minHeight: size.plate)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            ForEach(brief.entries) { entry in
                EarlyEntryPlate(entry: entry, showsDetail: true, height: size.plate, digits: size.plateDigits)
                    .opacity(isBreak ? 0.7 : 1)
            }
            if !isBreak, let rule = brief.doNotEnter {
                DoNotEnterPlate(rule: rule, showsDetail: true, height: size.plate, digits: size.plateDigits)
            }
            ForEach(brief.notes, id: \.self) { note in
                Label {
                    Text(note).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "text.bubble")
                }
                .font(.system(size: size.info - 1, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }
        }
    }
}

/// What the training readout says, for the iPhone card and the Mac panel alike: the phase, the lines about this
/// moment, the timer and the same two buttons — "Вышли" (in a break) or "Вернулись" (outside), and "Фальстарт".
/// Only two timers: the exit counts down to its plan, the break to the next exit; both count up in yellow once
/// they run over.
struct ReadoutContent {
    /// The main button (Space on a computer).
    enum Step {
        case outside, backInside, finish

        var title: String {
            switch self {
            case .outside: return String(localized: "Вышли")
            case .backInside: return String(localized: "Вернулись")
            case .finish: return String(localized: "Завершить")
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
        /// Pink outside, blue in a break; past the plan yellow, both.
        let tint: Color
        let progress: Double?
    }

    let session: TrainingSession

    var isBreak: Bool {
        if case .breakTime = session.phase { return true }
        return false
    }

    var title: String {
        switch session.phase {
        case .ready, .leaving, .away:
            return String(localized: "Выход \(session.currentExit?.number ?? 0)")
        case .breakTime(_, _, _, let next):
            return next == nil ? String(localized: "Последний перерыв") : String(localized: "Перерыв")
        case .finished:
            return String(localized: "Готово")
        }
    }

    /// "попытка 2" next to the title (outside; in a break it is part of the next exit's line).
    var attempt: String? {
        session.attempt > 1 && !isBreak ? String(localized: "попытка \(session.attempt)") : nil
    }

    /// The line under the title: «План 1 мин» / «Следующий выход 4 — 45 с». The exit's conditions, triggers and
    /// notes are in `brief`.
    var line: String? {
        switch session.phase {
        case .ready, .leaving, .away:
            guard let exit = session.currentExit else { return nil }
            if exit.isOpen { return String(localized: "Выход без времени — вернитесь, когда нужно") }
            return String(localized: "План \(DurationText.short(exit.duration))")
        case .breakTime(_, _, _, let next):
            guard let next, session.plan.exits.indices.contains(next) else {
                return String(localized: "Выходы закончились: «Ещё выход» или «Завершить»")
            }
            let exit = session.plan.exits[next]
            let duration = DurationText.short(exit.duration)
            return session.attempt > 1
                ? String(localized: "Следующий выход \(exit.number) — \(duration) · попытка \(session.attempt)")
                : String(localized: "Следующий выход \(exit.number) — \(duration)")
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

    func timer(at now: Date) -> Timer {
        let remaining = session.remaining(at: now)
        let overdue = (remaining ?? 0) < 0
        let tint: Color = overdue ? Theme.warning : (isBreak ? Theme.info : Theme.accent)
        switch session.phase {
        case .ready:
            return Timer(text: DurationText.clock(session.currentExit?.duration ?? 0), caption: String(localized: "план"),
                         overdue: false, tint: tint, progress: nil)
        case .leaving:
            return Timer(text: DurationText.clock(session.elapsed(at: now)), caption: String(localized: "к двери"),
                         overdue: false, tint: tint, progress: nil)
        case .away where session.currentExit?.isOpen == true:
            // An extra exit has no plan: its time counts up.
            return Timer(text: DurationText.clock(session.elapsed(at: now)), caption: String(localized: "прошло"),
                         overdue: false, tint: Theme.accent, progress: nil)
        case .away, .breakTime:
            let value = remaining ?? 0
            return Timer(text: overdue ? "+" + DurationText.clock(-value) : DurationText.clock(value),
                         caption: overdue ? String(localized: "сверх плана") : String(localized: "осталось"),
                         overdue: overdue, tint: tint, progress: session.progress(at: now))
        case .finished:
            return Timer(text: "✓", caption: "", overdue: false, tint: Theme.accent, progress: nil)
        }
    }
}

/// The iPhone's readout: the exit strip, the phase, a big ring timer, the lines and the two buttons.
struct SessionReadout: View {
    let session: TrainingSession
    var size: Size = .phone
    var onFinish: () -> Void
    /// The row of the exit's chips opens its details (nil: the schedule has none, no row).
    var onDetails: (() -> Void)? = nil

    struct Size {
        var ring: CGFloat
        var digits: CGFloat
        var title: CGFloat
        var info: CGFloat
        var spacing: CGFloat
        var button: CGFloat
        /// The condition plates: their height and the size of their time.
        var plate: CGFloat
        var plateDigits: CGFloat

        static let phone = Size(ring: 176, digits: 46, title: 22, info: 15, spacing: 14, button: 52, plate: 44, plateDigits: 22)
        static let phoneCompact = Size(ring: 140, digits: 38, title: 22, info: 14, spacing: 10, button: 52, plate: 38,
                                       plateDigits: 20)
    }

    var body: some View {
        let content = ReadoutContent(session: session)
        VStack(spacing: size.spacing) {
            ExitStrip(session: session)
            header(content)
            if let onDetails {
                ExitChips(brief: content.brief, isBreak: content.isBreak, onTap: onDetails)
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                timer(content.timer(at: context.date))
            }
            Text(content.line ?? " ")
                .font(.system(size: size.info, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            ReadoutActions(session: session, height: size.button, onFinish: onFinish)
        }
    }

    /// "Выход 3" big, the attempt small and quiet next to it: the exit matters more. On the right ⚡ 🏃 📝 of the
    /// exit (the next one in a break).
    private func header(_ content: ReadoutContent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(content.title)
                .font(Theme.display(size.title, weight: .bold))
            if let attempt = content.attempt {
                Text(attempt)
                    .font(Theme.display(size.title * 0.64, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
            if let brief = content.brief {
                ExitMarks(plan: session.plan, exit: brief.exit, size: size.info - 2)
            }
        }
    }

    private func timer(_ timer: ReadoutContent.Timer) -> some View {
        ZStack {
            TimerRing(progress: timer.progress, tint: timer.tint, lineWidth: 5)
            VStack(spacing: 0) {
                Text(timer.text)
                    .font(Theme.display(timer.text.count > 6 ? size.digits * 0.78 : size.digits, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(timer.overdue ? timer.tint : .white)
                    .contentTransition(.numericText())
                Text(timer.caption)
                    .font(.system(size: size.info - 2, weight: .semibold, design: .rounded))
                    .foregroundStyle(timer.overdue ? timer.tint.opacity(0.8) : .white.opacity(0.55))
            }
        }
        .frame(width: size.ring, height: size.ring)
    }

}

/// The exit's details in one row of chips under the title, the same height on every exit: outside its conditions with
/// their times and «не входить», in a break the next exit's triggers; 📝 when it has notes. A tap opens them in full.
private struct ExitChips: View {
    let brief: ExitBrief?
    let isBreak: Bool
    var onTap: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let brief {
                    if isBreak {
                        ForEach(Array(brief.exit.triggers.enumerated()), id: \.offset) { _, trigger in
                            chip { Image(systemName: "bolt.fill").foregroundStyle(Theme.warning); Text(trigger) }
                        }
                    }
                    ForEach(brief.entries) { entry in
                        chip {
                            Circle().fill(entry.tone.color).frame(width: 7, height: 7)
                            Text(entry.event)
                            Text(entry.delay.flatMap { $0 > 0 ? DurationText.clock($0) : nil } ?? entry.unreadDelay ?? String(localized: "сразу"))
                                .fontWeight(.bold)
                                .monospacedDigit()
                        }
                        .opacity(isBreak ? 0.7 : 1)
                    }
                    if !isBreak, brief.doNotEnter != nil {
                        chip { Image(systemName: "flag.fill").foregroundStyle(Theme.danger); Text("не входить") }
                    }
                    if !brief.notes.isEmpty {
                        chip { Image(systemName: "text.bubble.fill") }
                    }
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Открыть подробности выхода")
    }

    private func chip<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        HStack(spacing: 5, content: label)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.white.opacity(0.08), in: Capsule())
    }
}

/// The next step and the false start. Outside, «Фальстарт» counts down the trainer's window («в первые 20 секунд…»)
/// and then folds away, the step taking the whole row. After the schedule's last exit: «Ещё выход» (an extra one
/// without a planned time) next to «Завершить» — a training ends only with that.
struct ReadoutActions: View {
    let session: TrainingSession
    var height: CGFloat = 52
    var onFinish: () -> Void

    var body: some View {
        let content = ReadoutContent(session: session)
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let falseStartLeft = content.falseStartLeft(at: context.date)
            let showsFalseStart = content.showsFalseStart(at: context.date)
            HStack(spacing: 8) {
                if content.canStartOpenExit {
                    BigButton(title: String(localized: "Ещё выход"), icon: .outside, style: .secondary, height: height) {
                        session.startOpenExit()
                    }
                }
                if let step = content.step {
                    BigButton(title: step.title, icon: step.icon, style: step == .backInside ? .rest : .primary,
                              height: height) {
                        switch step {
                        case .outside: session.markBehindDoor()
                        case .backInside: session.endExit()
                        case .finish: onFinish()
                        }
                    }
                }
                if showsFalseStart {
                    BigButton(title: String(localized: "Фальстарт"), systemImage: "arrow.uturn.backward", style: .destructive,
                              height: height) {
                        session.resetExit()
                    }
                    .overlay(alignment: .bottom) {
                        if let falseStartLeft, let window = session.plan.falseStartWindow {
                            // How long it still counts: a line running out under the title.
                            Capsule()
                                .fill(Theme.danger.opacity(0.7))
                                .frame(height: 3)
                                .scaleEffect(x: max(0, falseStartLeft / window), anchor: .leading)
                                .padding(.horizontal, 18)
                                .padding(.bottom, 7)
                                .animation(.linear(duration: 0.5), value: falseStartLeft)
                        }
                    }
                    .transition(.scale(scale: 0.4, anchor: .trailing).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.35), value: showsFalseStart)
        }
    }
}

/// One chip per exit: done ones dimmed, the current one highlighted, breaks shown as thin gaps.
/// Shows the whole plan and the position in it without any sentence.
struct ExitStrip: View {
    let session: TrainingSession
    /// Mac: bigger chips for the wider panel.
    var large = false

    private enum ChipState { case done, current, upcoming }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(session.plan.exits.enumerated()), id: \.element.id) { index, exit in
                        chip(exit, state: state(for: index))
                            .id(exit.id)
                        if index < session.plan.exits.count - 1 {
                            breakGap(session.plan.breakAfter(exitAt: index), highlighted: isBreak(after: index))
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: session.currentExitIndex ?? -1, initial: true) { _, index in
                guard session.plan.exits.indices.contains(index) else { return }
                withAnimation { proxy.scrollTo(session.plan.exits[index].id, anchor: .center) }
            }
        }
    }

    private func chip(_ exit: PlannedExit, state: ChipState) -> some View {
        HStack(spacing: 2) {
            Text(exit.isOpen ? String(localized: "доп.") : DurationText.compact(exit.duration))
            if exit.untilStanding {
                Image(systemName: "figure.stand").font(.system(size: 9, weight: .bold))
            }
        }
        .font(.system(size: large ? 14 : 12, weight: .semibold, design: .rounded).monospacedDigit())
        .padding(.horizontal, large ? 10 : 8)
        .padding(.vertical, large ? 6 : 5)
        .background(state == .current ? Theme.accent : Theme.control, in: Capsule())
        .foregroundStyle(state == .current ? .black : .white)
        .opacity(state == .done ? 0.35 : 1)
    }

    private func breakGap(_ duration: TimeInterval, highlighted: Bool) -> some View {
        Rectangle()
            .fill(highlighted ? Theme.info : Color.white.opacity(0.18))
            .frame(width: max(6, min(large ? 28 : 22, duration / 20)), height: 2)
    }

    private func state(for index: Int) -> ChipState {
        guard let current = session.currentExitIndex else { return .done }
        if index < current { return .done }
        if index == current { return .current }
        return .upcoming
    }

    private func isBreak(after index: Int) -> Bool {
        if case .breakTime(let after, _, _, _) = session.phase { return after == index }
        return false
    }
}

/// Shown right after a session finishes.
struct SummaryCard: View {
    @Environment(AppModel.self) private var model
    let record: TrainingRecord
    var onClose: () -> Void
    var onHistory: () -> Void

    var body: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Тренировка завершена")
                        .font(Theme.display(22, weight: .bold))
                    Spacer()
                    IconButton(systemImage: "xmark", label: String(localized: "Закрыть"), action: onClose)
                }
                Text(record.plan.displayTitle)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))

                HStack(spacing: 18) {
                    stat("\(record.completedExits)/\(record.plan.exits.count)", String(localized: "выходов"))
                    stat("\(record.falseStarts)", String(localized: "фальстартов"))
                    stat(DurationText.clock(record.duration), String(localized: "длительность"))
                }

                if let name = record.recordingFileName {
                    let status = model.photosStatus(for: name)
                    Label(status.saved ? "Видео в Фото" : "Видео записано",
                          systemImage: status.saved ? "photo.on.rectangle.angled" : "film")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    if let error = status.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(Theme.warning)
                    }
                }

                HStack(spacing: 8) {
                    ShareLink(item: SessionLogFormatter.text(for: record)) {
                        Label("Лог", systemImage: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Theme.control, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                    BigButton(title: String(localized: "История"), systemImage: "clock.arrow.circlepath", style: .secondary, height: 44, action: onHistory)
                }
                BigButton(title: String(localized: "Новая тренировка"), systemImage: "plus", action: onClose)
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Theme.display(22, weight: .bold)).monospacedDigit()
            Text(label).font(.system(.caption, design: .rounded)).foregroundStyle(.white.opacity(0.55))
        }
    }
}
