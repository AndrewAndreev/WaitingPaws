import SwiftUI
import WaitingPawsCore

/// The iPhone's heads-up display for the running session: the shared readout on a card.
struct SessionHUD: View {
    let session: TrainingSession
    /// Smaller ring and tighter spacing for portrait phones.
    var compact = false
    var onFinish: () -> Void

    var body: some View {
        GlassCard(padding: compact ? 14 : 18) {
            SessionReadout(session: session, size: compact ? .phoneCompact : .phone, onFinish: onFinish)
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
            return String(localized: "План \(DurationText.short(exit.duration))")
        case .breakTime(_, _, _, let next):
            guard let next, session.plan.exits.indices.contains(next) else {
                return String(localized: "Выходы закончились: после перерыва тренировка завершится")
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
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                timer(content.timer(at: context.date))
            }
            info(content)
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

    private func info(_ content: ReadoutContent) -> some View {
        VStack(spacing: 8) {
            if let line = content.line {
                Text(line)
                    .font(.system(size: size.info, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let brief = content.brief {
                if content.isBreak {
                    breakDetails(brief)
                } else {
                    outsideDetails(brief)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Outside: when to come back early, big; when not to come in; the notes folded.
    private func outsideDetails(_ brief: ExitBrief) -> some View {
        VStack(spacing: 6) {
            ForEach(brief.entries) { entry in
                EarlyEntryPlate(entry: entry, height: size.plate, digits: size.plateDigits)
            }
            if let rule = brief.doNotEnter {
                DoNotEnterPlate(rule: rule, height: size.plate, digits: size.plateDigits)
            }
            if !brief.notes.isEmpty {
                FoldedNotes(notes: brief.notes, size: size.info - 2)
                    .padding(.horizontal, 4)
                    .id(brief.exit.id)
            }
        }
    }

    /// In a break: what to take for the next exit and its conditions in one line.
    private func breakDetails(_ brief: ExitBrief) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(brief.exit.triggers.enumerated()), id: \.offset) { _, trigger in
                TriggerRow(text: trigger, size: size.info)
            }
            if let summary = brief.entriesSummary {
                Label {
                    Text("На выходе: \(summary)")
                } icon: {
                    Image(systemName: "figure.run")
                }
                .font(.system(size: size.info - 2, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Always the same two buttons: the next step and the false start.
struct ReadoutActions: View {
    let session: TrainingSession
    var height: CGFloat = 52
    var onFinish: () -> Void

    var body: some View {
        let content = ReadoutContent(session: session)
        HStack(spacing: 8) {
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
            if content.canFalseStart {
                BigButton(title: String(localized: "Фальстарт"), systemImage: "arrow.uturn.backward", style: .destructive,
                          height: height) {
                    session.resetExit()
                }
            }
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
            Text(DurationText.compact(exit.duration))
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
                    IconButton(systemImage: "xmark", action: onClose)
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
