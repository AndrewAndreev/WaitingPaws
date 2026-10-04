import SwiftUI
import WaitingPawsCore

/// Heads-up display for the running session: exit strip, big timer and the action buttons.
/// Progress and "what's next" are shown by the strip instead of sentences.
struct SessionHUD: View {
    let session: TrainingSession
    /// Smaller ring and tighter spacing for portrait phones.
    var compact = false
    var onFinish: () -> Void

    var body: some View {
        GlassCard(padding: compact ? 14 : 18) {
            VStack(spacing: compact ? 10 : 14) {
                ExitStrip(session: session)
                header
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    timer(at: context.date)
                }
                actions
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Text(phaseTitle)
                .font(Theme.display(22, weight: .bold))
            if session.attempt > 1, !isBreak {
                Pill(text: "попытка \(session.attempt)", tint: Theme.warning)
            }
            if let exit = session.currentExit, exit.untilStanding, !isBreak {
                Image(systemName: "figure.stand")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.info)
                    .help("Или до вставания")
            }
            Spacer()
            if let note = session.currentExit?.note, !isBreak {
                Text(note)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func timer(at now: Date) -> some View {
        let remaining = session.remaining(at: now)
        let overdue = (remaining ?? 0) < 0
        let tint: Color = overdue ? Theme.warning : (isBreak ? Theme.info : Theme.accent)
        let text: String
        let caption: String
        switch session.phase {
        case .ready:
            text = DurationText.short(session.currentExit?.duration ?? 0)
            caption = "план"
        case .leaving:
            text = DurationText.clock(session.elapsed(at: now))
            caption = "к двери"
        case .away:
            text = overdue ? "+" + DurationText.clock(-(remaining ?? 0)) : DurationText.clock(remaining ?? 0)
            caption = "за дверью"
        case .breakTime(_, _, _, let next):
            text = overdue ? "+" + DurationText.clock(-(remaining ?? 0)) : DurationText.clock(remaining ?? 0)
            if let next, session.plan.exits.indices.contains(next) {
                caption = "до выхода \(session.plan.exits[next].number)"
            } else {
                caption = "до конца"
            }
        case .finished:
            text = "✓"
            caption = ""
        }

        let ring: CGFloat = compact ? 136 : 176
        return ZStack {
            TimerRing(progress: session.progress(at: now), tint: tint, lineWidth: 5)
                .frame(width: ring, height: ring)
            VStack(spacing: 0) {
                Text(text)
                    .font(Theme.display(compact ? (text.count > 6 ? 30 : 38) : (text.count > 6 ? 36 : 46), weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(overdue ? Theme.warning : .white)
                Text(caption)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch session.phase {
        case .ready:
            BigButton(title: "Начать выход", systemImage: "figure.walk") {
                session.startExit()
            }
        case .leaving:
            BigButton(title: "За дверью", systemImage: "door.left.hand.closed") {
                session.markBehindDoor()
            }
            HStack(spacing: 8) {
                BigButton(title: "Вернулись", systemImage: "checkmark", style: .secondary, height: 44) {
                    session.endExit()
                }
                BigButton(title: "Сброс", systemImage: "arrow.uturn.backward", style: .destructive, height: 44) {
                    session.resetExit()
                }
            }
        case .away:
            BigButton(title: "Вернулись", systemImage: "checkmark", style: .success) {
                session.endExit()
            }
            BigButton(title: "Фальстарт", systemImage: "arrow.uturn.backward", style: .destructive, height: 44) {
                session.resetExit()
            }
        case .breakTime(_, _, _, let next):
            if let next, session.plan.exits.indices.contains(next) {
                BigButton(title: "Начать выход \(session.plan.exits[next].number)", systemImage: "figure.walk") {
                    session.startExit()
                }
                BigButton(title: "Завершить", systemImage: "flag.checkered", style: .secondary, height: 44, action: onFinish)
            } else {
                BigButton(title: "Завершить", systemImage: "flag.checkered", action: onFinish)
            }
        case .finished:
            EmptyView()
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
            return "Выход \(session.currentExit?.number ?? 0)"
        case .breakTime(_, _, _, let next):
            return next == nil ? "Последний перерыв" : "Перерыв"
        case .finished:
            return "Готово"
        }
    }
}

/// One chip per exit: done ones dimmed, the current one highlighted, breaks shown as thin gaps.
/// Shows the whole plan and the position in it without any sentence.
struct ExitStrip: View {
    let session: TrainingSession

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
        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(state == .current ? Theme.accent : Theme.control, in: Capsule())
        .foregroundStyle(state == .current ? .black : .white)
        .opacity(state == .done ? 0.35 : 1)
    }

    private func breakGap(_ duration: TimeInterval, highlighted: Bool) -> some View {
        Rectangle()
            .fill(highlighted ? Theme.info : Color.white.opacity(0.18))
            .frame(width: max(6, min(22, duration / 20)), height: 2)
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
                    stat("\(record.completedExits)/\(record.plan.exits.count)", "выходов")
                    stat("\(record.falseStarts)", "фальстартов")
                    stat(DurationText.clock(record.duration), "длительность")
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
                    BigButton(title: "История", systemImage: "clock.arrow.circlepath", style: .secondary, height: 44, action: onHistory)
                }
                BigButton(title: "Новая тренировка", systemImage: "plus", action: onClose)
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
