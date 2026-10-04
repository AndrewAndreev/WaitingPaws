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
                    ShortcutLabel(title: String(localized: "Завершить"), symbol: "flag.checkered", key: "⌘.")
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
                PhaseBadge(text: live.overdue ? String(localized: "Сверх плана") : live.phaseName, tint: live.tint)
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
                    stat(String(localized: "\(live.session.completedExitsCount) из \(live.plan.exits.count)"), String(localized: "выходов"))
                    stat("\(live.session.falseStartsCount)", String(localized: "фальстартов"), tint: live.session.falseStartsCount > 0 ? MacPalette.orange : nil)
                }
                GridRow {
                    stat(DurationText.clock(live.now.timeIntervalSince(live.session.startedAt)), String(localized: "идёт тренировка"))
                    stat("≈ \(MacFormat.time.string(from: live.eta))", String(localized: "конец по плану"))
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
        let plan = live.session.currentExit?.durationDescription ?? ""
        switch live.phase {
        case .ready: return "\(live.timerCaption) · \(live.subtitle)"
        case .leaving: return String(localized: "идём к двери · план \(plan)")
        case .away:
            let away = DurationText.clock(live.session.elapsed(at: live.now))
            return String(localized: "за дверью \(away) · план \(plan)")
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
        let space = String(localized: "Пробел")
        let startTitle = String(localized: "Начать выход")
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                step(live.isBreak ? (live.primary?.title ?? startTitle) : startTitle, "figure.walk",
                     key: primary == 0 ? space : nil, enabled: canStart, prominent: primary == 0) {
                    live.session.startExit()
                }
                step(String(localized: "За дверью"), "door.left.hand.closed", key: primary == 1 ? space : nil,
                     enabled: canDoor, prominent: primary == 1) {
                    live.session.markBehindDoor()
                }
            }
            GridRow {
                step(String(localized: "Вернулись"), "checkmark", key: primary == 2 ? space : nil, enabled: canReturn,
                     prominent: primary == 2, tint: MacPalette.green) {
                    live.session.endExit()
                }
                step(String(localized: "Фальстарт"), "arrow.uturn.backward", key: canReturn ? "⌫" : nil, enabled: canReturn, prominent: false) {
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

/// Recording without a training: the clock and «Остановить» on a glass panel floating over the picture.
/// Drag it anywhere; it settles in the nearest corner or edge middle and stays there next time.
struct ClipRecordingHUD: View {
    @Environment(AppModel.self) private var model
    @AppStorage("mac.clipHUDPosition") private var position: HUDPosition = .bottom
    @State private var drag: CGSize = .zero
    @State private var hudSize: CGSize = .zero

    enum HUDPosition: String, CaseIterable {
        case topLeading, top, topTrailing, bottomLeading, bottom, bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading: return .topLeading
            case .top: return .top
            case .topTrailing: return .topTrailing
            case .bottomLeading: return .bottomLeading
            case .bottom: return .bottom
            case .bottomTrailing: return .bottomTrailing
            }
        }

        /// Where the panel's centre sits in an area of `size` for a panel of `hud`.
        func center(in size: CGSize, hud: CGSize, margin: CGFloat) -> CGPoint {
            let left = margin + hud.width / 2, right = size.width - margin - hud.width / 2
            let top = margin + hud.height / 2, bottom = size.height - margin - hud.height / 2
            switch self {
            case .topLeading: return CGPoint(x: left, y: top)
            case .top: return CGPoint(x: size.width / 2, y: top)
            case .topTrailing: return CGPoint(x: right, y: top)
            case .bottomLeading: return CGPoint(x: left, y: bottom)
            case .bottom: return CGPoint(x: size.width / 2, y: bottom)
            case .bottomTrailing: return CGPoint(x: right, y: bottom)
            }
        }
    }

    /// Clear of the camera's own timestamp in the top-left corner.
    private static let margin: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            panel
                .onGeometryChange(for: CGSize.self, of: \.size) { hudSize = $0 }
                .offset(drag)
                .gesture(
                    DragGesture(coordinateSpace: .local)
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            let start = position.center(in: geometry.size, hud: hudSize, margin: Self.margin)
                            let end = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
                            let nearest = HUDPosition.allCases.min { a, b in
                                distance(a.center(in: geometry.size, hud: hudSize, margin: Self.margin), end)
                                    < distance(b.center(in: geometry.size, hud: hudSize, margin: Self.margin), end)
                            } ?? .bottom
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                position = nearest
                                drag = .zero
                            }
                        }
                )
                .padding(Self.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: position.alignment)
        }
    }

    private var panel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 18) {
                HStack(alignment: .center, spacing: 10) {
                    RecordingDot()
                    Text(DurationText.clock(model.recordingDuration(at: context.date)))
                        .font(MacPalette.digits(34, weight: .medium))
                        .contentTransition(.numericText())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Запись без тренировки").font(.system(size: 13, weight: .semibold))
                    Text("Видео появится в истории").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button { model.stopRecording(deleteFile: false) } label: {
                    ShortcutLabel(title: String(localized: "Остановить"), symbol: "stop.fill", key: "⌘R", prominent: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(MacPalette.red)
                .controlSize(.large)
            }
            .padding(.leading, 22)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .environment(\.colorScheme, .dark)
            .help("Перетащите панель в любой угол")
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// A red dot that breathes while recording.
private struct RecordingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(MacPalette.red)
            .frame(width: 12, height: 12)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}
#endif
