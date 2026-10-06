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

/// The training readout of both the iPhone and the Mac: the exit strip, the phase, the big ring timer, what the plan
/// says about this moment, and the same two buttons — "Вышли" (in a break) or "Вернулись" (outside), and "Фальстарт".
/// Only two timers: the exit counts down to its plan, the break counts down to the next exit; both count up in
/// colour once they run over.
struct SessionReadout: View {
    let session: TrainingSession
    var size: Size = .phone
    /// Mac: the keys of the two buttons.
    var showsKeys = false
    var onFinish: () -> Void

    struct Size {
        var ring: CGFloat
        var digits: CGFloat
        var title: CGFloat
        var info: CGFloat
        var spacing: CGFloat
        var button: CGFloat

        /// Mac: the ring takes the height the panel has left, within these bounds (`ring` and `digits` then only
        /// give the digits' share of the ring).
        var flexibleRing: ClosedRange<CGFloat>? = nil
        var largeStrip = false

        static let phone = Size(ring: 176, digits: 46, title: 22, info: 15, spacing: 14, button: 52)
        static let phoneCompact = Size(ring: 140, digits: 38, title: 22, info: 14, spacing: 10, button: 52)
        static let mac = Size(ring: 220, digits: 60, title: 28, info: 15, spacing: 16, button: 54,
                              flexibleRing: 150...290, largeStrip: true)
    }

    var body: some View {
        VStack(spacing: size.spacing) {
            ExitStrip(session: session, large: size.largeStrip)
            header
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                timer(at: context.date)
            }
            info
            actions
        }
    }

    // MARK: - Pieces

    /// "Выход 3" big, the attempt small and quiet next to it: the exit matters more.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(phaseTitle)
                .font(Theme.display(size.title, weight: .bold))
            if session.attempt > 1, !isBreak {
                Text("попытка \(session.attempt)")
                    .font(Theme.display(size.title * 0.64, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
    }

    private func timer(at now: Date) -> some View {
        let remaining = session.remaining(at: now)
        let overdue = (remaining ?? 0) < 0
        // An exit past its plan is a warning; a break past its plan is time lost, in red.
        let overTint = isBreak ? Theme.danger : Theme.warning
        let tint: Color = overdue ? overTint : (isBreak ? Theme.info : Theme.accent)
        let text: String
        let caption: String
        switch session.phase {
        case .ready:
            text = DurationText.clock(session.currentExit?.duration ?? 0)
            caption = String(localized: "план")
        case .leaving:
            text = DurationText.clock(session.elapsed(at: now))
            caption = String(localized: "к двери")
        case .away, .breakTime:
            text = overdue ? "+" + DurationText.clock(-(remaining ?? 0)) : DurationText.clock(remaining ?? 0)
            caption = overdue ? String(localized: "сверх плана") : String(localized: "осталось")
        case .finished:
            text = "✓"
            caption = ""
        }

        let progress = session.progress(at: now)
        return ring { side in
            // The digits keep their share of the ring (46 pt in the phone's 176 pt one).
            let digits = (side * size.digits / size.ring * (text.count > 6 ? 0.78 : 1)).rounded()
            ZStack {
                TimerRing(progress: progress, tint: tint, lineWidth: side > 200 ? 7 : 5)
                VStack(spacing: 0) {
                    Text(text)
                        .font(Theme.display(digits, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(overdue ? overTint : .white)
                        .contentTransition(.numericText())
                    Text(caption)
                        .font(.system(size: size.info - 2, weight: .semibold, design: .rounded))
                        .foregroundStyle(overdue ? overTint.opacity(0.8) : .white.opacity(0.55))
                }
            }
            .frame(width: side, height: side)
        }
    }

    /// The ring's square: fixed on the phone, as big as the free height allows on the Mac.
    @ViewBuilder
    private func ring<Content: View>(@ViewBuilder _ content: @escaping (CGFloat) -> Content) -> some View {
        if let range = size.flexibleRing {
            GeometryReader { geometry in
                content(max(range.lowerBound, min(range.upperBound, min(geometry.size.width, geometry.size.height))))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // A modest ideal height: the window's own size must not grow to fit the biggest ring.
            .frame(minHeight: range.lowerBound, idealHeight: range.lowerBound, maxHeight: range.upperBound)
        } else {
            content(size.ring)
        }
    }

    /// Only what matters now. Outside: the plan of this exit and its "или до вставания" rule. In a break: the next exit.
    @ViewBuilder
    private var info: some View {
        VStack(spacing: 5) {
            switch session.phase {
            case .ready, .leaving, .away:
                if let exit = session.currentExit {
                    Text("План \(exit.durationDescription)")
                        .foregroundStyle(.white.opacity(0.85))
                    if exit.untilStanding {
                        Label(session.plan.standingRule, systemImage: "figure.stand")
                            .foregroundStyle(Theme.info)
                    }
                    if let note = exit.note, !note.isEmpty {
                        Label(note, systemImage: "text.bubble")
                    }
                }
            case .breakTime(_, _, _, let next):
                if let next, session.plan.exits.indices.contains(next) {
                    let exit = session.plan.exits[next]
                    Text(session.attempt > 1
                         ? String(localized: "Следующий выход \(exit.number) — \(exit.durationDescription) · попытка \(session.attempt)")
                         : String(localized: "Следующий выход \(exit.number) — \(exit.durationDescription)"))
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Text("Выходы закончились: после перерыва тренировка завершится")
                }
            case .finished:
                EmptyView()
            }
        }
        .font(.system(size: size.info, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.6))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }

    /// Always the same two buttons: the next step (Space on the Mac) and the false start (⌫).
    @ViewBuilder
    private var actions: some View {
        let phase = session.phase
        let space = showsKeys ? String(localized: "Пробел") : nil
        HStack(spacing: 8) {
            if case .away = phase {
                BigButton(title: String(localized: "Вернулись"), systemImage: "checkmark", style: .success,
                          height: size.button, key: space) {
                    session.endExit()
                }
            } else if phase.canGoOutside {
                BigButton(title: String(localized: "Вышли"), systemImage: "door.left.hand.closed",
                          height: size.button, key: space) {
                    session.markBehindDoor()
                }
            } else if case .breakTime = phase {
                BigButton(title: String(localized: "Завершить"), systemImage: "flag.checkered",
                          height: size.button, key: space, action: onFinish)
            }
            if phase.canFalseStart {
                BigButton(title: String(localized: "Фальстарт"), systemImage: "arrow.uturn.backward", style: .destructive,
                          height: size.button, key: showsKeys ? "⌫" : nil) {
                    session.resetExit()
                }
            }
        }
    }

    // MARK: - Text

    private var isBreak: Bool {
        if case .breakTime = session.phase { return true }
        return false
    }

    private var phaseTitle: String {
        switch session.phase {
        case .ready, .leaving, .away:
            return String(localized: "Выход \(session.currentExit?.number ?? 0)")
        case .breakTime(_, _, _, let next):
            return next == nil ? String(localized: "Последний перерыв") : String(localized: "Перерыв")
        case .finished:
            return String(localized: "Готово")
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
