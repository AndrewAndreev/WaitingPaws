#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Right panel during a session: the big readout and the four steps with their keys.
struct ConsoleReadout: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    let live: LiveSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            readout
            transport
            if let exit = live.session.currentExit, exit.untilStanding, !live.isBreak {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "figure.stand").foregroundStyle(MacPalette.blue)
                    Text("Выход «или до вставания»: собака встала — сразу возвращайтесь.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let note = live.session.currentExit?.note, !note.isEmpty, !live.isBreak {
                Label(note, systemImage: "text.bubble")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button { ui.confirmFinish = true } label: {
                    ShortcutLabel(title: "Завершить", symbol: "flag.checkered", key: "⌘.")
                }
                Spacer()
                Text("Пробел — следующий шаг")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(live.isBreak ? "ПЕРЕРЫВ" : "ВЫХОД \(live.session.currentExit?.number ?? 0)")
                if live.session.attempt > 1, !live.isBreak {
                    Text("ПОПЫТКА \(live.session.attempt)").foregroundStyle(MacPalette.orange)
                }
                Spacer()
                PhaseBadge(text: live.overdue ? "Сверх плана" : live.phaseName, tint: live.tint)
            }
            .font(.system(size: 11, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(.secondary)

            Text(live.timerText)
                .font(MacPalette.digits(80, weight: .medium))
                .foregroundStyle(live.isLeaving || live.isReady ? Color.primary : live.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.vertical, -6)

            Text(detail)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            ThinProgress(value: live.isAway || live.isBreak ? live.progress : 0, tint: live.tint, height: 3)
                .padding(.top, 2)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    stat("\(live.session.completedExitsCount) из \(live.plan.exits.count)", "выходов")
                    stat("\(live.session.falseStartsCount)", "фальстартов", tint: live.session.falseStartsCount > 0 ? MacPalette.orange : nil)
                }
                GridRow {
                    stat(DurationText.clock(live.now.timeIntervalSince(live.session.startedAt)), "идёт тренировка")
                    stat("≈ \(MacFormat.time.string(from: live.eta))", "конец по плану")
                }
            }
            .padding(.top, 8)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.32))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.07)))
        }
    }

    private var detail: String {
        switch live.phase {
        case .ready: return "\(live.timerCaption) · \(live.subtitle)"
        case .leaving: return "идём к двери · план \(live.session.currentExit?.durationDescription ?? "")"
        case .away:
            let away = DurationText.clock(live.session.elapsed(at: live.now))
            return "за дверью \(away) · план \(live.session.currentExit?.durationDescription ?? "")"
        case .breakTime: return "\(live.timerCaption) · \(live.subtitle)"
        case .finished: return live.subtitle
        }
    }

    private func stat(_ value: String, _ label: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(MacPalette.digits(17, weight: .semibold)).foregroundStyle(tint ?? .primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Transport

    private var transport: some View {
        let phase = live.phase
        let canStart: Bool = { if case .ready = phase { return true }; if case .breakTime(_, _, _, let next) = phase { return next != nil }; return false }()
        let canDoor: Bool = { if case .leaving = phase { return true }; return false }()
        let canReturn = phase.isOutside
        let primary: Int = canDoor ? 1 : (live.isAway ? 2 : (canStart ? 0 : -1))
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                step(live.isBreak ? (live.primary?.title ?? "Начать выход") : "Начать выход", "figure.walk",
                     key: primary == 0 ? "Пробел" : nil, enabled: canStart, prominent: primary == 0) {
                    live.session.startExit()
                }
                step("За дверью", "door.left.hand.closed", key: primary == 1 ? "Пробел" : nil,
                     enabled: canDoor, prominent: primary == 1) {
                    live.session.markBehindDoor()
                }
            }
            GridRow {
                step("Вернулись", "checkmark", key: primary == 2 ? "Пробел" : nil, enabled: canReturn,
                     prominent: primary == 2, tint: MacPalette.green) {
                    live.session.endExit()
                }
                step("Фальстарт", "arrow.uturn.backward", key: canReturn ? "⌫" : nil, enabled: canReturn, prominent: false) {
                    live.session.resetExit()
                }
            }
        }
    }

    private func step(_ title: String, _ symbol: String, key: String?, enabled: Bool, prominent: Bool,
                      tint: Color = MacPalette.pinkDeep, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ShortcutLabel(title: title, symbol: symbol, key: key, prominent: prominent, expand: true)
                .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .tint(prominent ? tint : Color.gray.opacity(0.35))
        .controlSize(.extraLarge)
        .disabled(!enabled)
    }
}

/// Right panel while recording without a training.
struct ClipRecordingPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                Text("Запись без тренировки").font(.title2.weight(.semibold))
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(MacPalette.red).frame(width: 12, height: 12)
                    Text(DurationText.clock(model.recordingDuration(at: context.date)))
                        .font(MacPalette.digits(64, weight: .medium))
                }
                Text("Только видео, без расписания и лога. Файл появится в истории.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button { model.stopRecording(deleteFile: false) } label: {
                    ShortcutLabel(title: "Остановить запись", symbol: "stop.fill", key: "⌘R", prominent: true, expand: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(MacPalette.red)
                .controlSize(.extraLarge)
                Spacer()
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
#endif
