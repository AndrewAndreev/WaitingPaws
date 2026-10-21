#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Right panel during a session. Under the exit strip, what this exit (or break) is; then the timer — big tinted
/// digits over a progress line, the focus of the window — and the same two buttons as on the iPhone, with their
/// keys. Under them, outside: when to come back early, when not to come in and the exit's notes; in a break: what to
/// take for the next exit. The rest of the panel is the trainer's text with that exit marked. The numbers of the whole
/// training live in the timeline's header, «Завершить» in the toolbar.
struct ConsoleReadout: View {
    @Environment(AppModel.self) private var model
    let session: TrainingSession
    @State private var showTrainerText = false

    var body: some View {
        let content = ReadoutContent(session: session)
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                ExitStrip(session: session, large: true)
                about(content)
                    .padding(.top, 14)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    timer(content.timer(at: context.date))
                }
                .padding(.top, 22)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.32))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.07)))
            }
            buttons(content)
            if let brief = content.brief {
                if content.isBreak {
                    prepare(brief)
                } else {
                    conditions(brief)
                }
            }
            if session.plan.rawText.isEmpty {
                Spacer(minLength: 0)
            } else {
                trainerText(content)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// «Выход 4 · попытка 2» with ⚡ 🏃 📝 of the exit, and its plan — or the next exit in a break.
    private func about(_ content: ReadoutContent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(content.title)
                    .font(.system(size: 22, weight: .bold))
                if let attempt = content.attempt {
                    Text(attempt)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let brief = content.brief {
                    ExitMarks(plan: session.plan, exit: brief.exit, size: 13)
                }
            }
            if let line = content.line {
                Text(line).font(.system(size: 15, weight: .medium))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - The exit

    /// Outside: «Ранний вход» — the conditions with the trainer's words under them, the rule against coming in, the
    /// notes folded.
    @ViewBuilder
    private func conditions(_ brief: ExitBrief) -> some View {
        if !brief.entries.isEmpty || brief.doNotEnter != nil || !brief.notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !brief.entries.isEmpty {
                    sectionTitle(String(localized: "Ранний вход"), symbol: "figure.run")
                    ForEach(brief.entries) { entry in
                        EarlyEntryPlate(entry: entry, showsDetail: true, height: 46, digits: 20)
                    }
                }
                if let rule = brief.doNotEnter {
                    DoNotEnterPlate(rule: rule, showsDetail: true, height: 46, digits: 20)
                }
                if !brief.notes.isEmpty {
                    FoldedNotes(notes: brief.notes, size: 12.5)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                        .id(brief.exit.id)
                }
            }
        }
    }

    /// In a break: what to take for the next exit, and its conditions in one line.
    @ViewBuilder
    private func prepare(_ brief: ExitBrief) -> some View {
        if !brief.exit.triggers.isEmpty || brief.entriesSummary != nil {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(String(localized: "Подготовить к выходу \(brief.exit.number)"), symbol: "bolt.fill")
                ForEach(Array(brief.exit.triggers.enumerated()), id: \.offset) { _, trigger in
                    TriggerRow(text: trigger, size: 14)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if let summary = brief.entriesSummary {
                    Label("На выходе: \(summary)", systemImage: "figure.run")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    /// The trainer's text, always there: the exit of the moment marked and kept in view. When the panel is too short
    /// for it (a small window), one row that opens it next to the panel; ↗ opens it larger in any case.
    private func trainerText(_ content: ReadoutContent) -> some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    sectionTitle(String(localized: "Текст тренера"), symbol: "doc.text")
                    Spacer(minLength: 0)
                    trainerTextButton(content, label: Image(systemName: "arrow.up.left.and.arrow.down.right"))
                        .help("Открыть текст тренера крупнее")
                }
                TrainerTextView(text: session.plan.rawText, exitNumber: content.textExitNumber, fontSize: 12.5)
                    .frame(maxHeight: .infinity)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.black.opacity(0.22))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06)))
                    }
            }
            .frame(idealHeight: 96, maxHeight: .infinity)
            trainerTextButton(content, label: Label("Текст тренера", systemImage: "doc.text"))
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(height: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func trainerTextButton(_ content: ReadoutContent, label: some View) -> some View {
        Button { showTrainerText = true } label: { label }
            .buttonStyle(.borderless)
            .popover(isPresented: $showTrainerText, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Текст тренера").font(.headline).padding(.horizontal, 10)
                    TrainerTextView(text: session.plan.rawText, exitNumber: content.textExitNumber, fontSize: 13.5)
                }
                .padding(.vertical, 12)
                .frame(width: 460, height: 580)
            }
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .padding(.top, 2)
    }

    /// Big digits in the phase's colour (neutral before the first exit), the caption and the progress line.
    private func timer(_ timer: ReadoutContent.Timer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(timer.text)
                .font(MacPalette.digits(88, weight: .semibold))
                .foregroundStyle(timer.progress == nil && !timer.overdue ? Color.primary : timer.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .padding(.vertical, -6)
            ThinProgress(value: timer.progress ?? 0, tint: timer.tint, height: 6)
            Text(timer.caption)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(timer.overdue ? timer.tint : .secondary)
        }
    }

    // MARK: - Buttons

    /// The next step (Space) and the false start (⌫), as on the iPhone: blue toward a break, pink toward an exit.
    private func buttons(_ content: ReadoutContent) -> some View {
        HStack(spacing: 10) {
            if let step = content.step {
                StepButton(title: step.title, icon: step.icon, key: String(localized: "Пробел"),
                           fill: step.tint, foreground: .black) {
                    switch step {
                    case .outside: session.markBehindDoor()
                    case .backInside: session.endExit()
                    case .finish: model.finishSession()
                    }
                }
            }
            if content.canFalseStart {
                StepButton(title: String(localized: "Фальстарт"), icon: .symbol("arrow.uturn.backward"), key: "⌫",
                           fill: .white.opacity(0.08), foreground: MacPalette.red) {
                    session.resetExit()
                }
            }
        }
    }
}

/// A training step: a 42 pt rounded button, the title centred, its key at the trailing edge while it fits.
private struct StepButton: View {
    let title: String
    let icon: StepIcon.Kind
    let key: String
    let fill: Color
    let foreground: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                label
                    .padding(.horizontal, 56)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) { keyCap }
                label.frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(StepButtonStyle(fill: fill, foreground: foreground))
        .help("\(title) · \(key)")
    }

    private var label: some View {
        HStack(spacing: 7) {
            StepIcon(kind: icon, size: 15)
            Text(title).lineLimit(1)
        }
        .fixedSize()
    }

    private var keyCap: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 18)
            .background(foreground.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(0.8)
            .padding(.trailing, 10)
    }
}

private struct StepButtonStyle: ButtonStyle {
    let fill: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(height: 42)
            .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Recording without a training: the clock and «Остановить» on a glass panel floating over the picture. In «Только
/// камера» (not recording) the same panel offers to record or to bring the panels back.
/// Drag it anywhere; it settles in the nearest corner or edge middle and stays there next time.
struct ClipRecordingHUD: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
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

    @ViewBuilder
    private var panel: some View {
        if model.isRecordingNow {
            recordingPanel
        } else {
            watchingPanel
        }
    }

    /// «Только камера»: nothing is recorded; record from here (⌘R) or go back to the panels (Esc).
    private var watchingPanel: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "eye")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Только камера").font(.system(size: 13, weight: .semibold))
                    Text("Без записи и тренировки").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Button { model.startRecording() } label: {
                ShortcutLabel(title: String(localized: "Запись"), symbol: "record.circle", key: "⌘R")
            }
            .controlSize(.large)
            .disabled(!model.settings.isConfigured)
            Button { ui.cameraOnly = false } label: {
                ShortcutLabel(title: String(localized: "Панели"), symbol: "sidebar.right", key: "esc")
            }
            .controlSize(.large)
            .help("Вернуть расписание и шкалу · ⇧⌘F")
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
        .help("Перетащите панель в любой угол")
    }

    private var recordingPanel: some View {
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
