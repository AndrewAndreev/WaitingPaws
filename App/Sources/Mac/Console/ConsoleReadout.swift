#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Right panel during a session. Under the exit strip, what this exit (or break) is; then the timer — big tinted
/// digits over a progress line, the focus of the window — and the same two buttons as on the iPhone, with their
/// keys. The numbers of the whole training live in the timeline's header, «Завершить» in the toolbar.
struct ConsoleReadout: View {
    @Environment(AppModel.self) private var model
    let session: TrainingSession

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
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// «Выход 4 · попытка 2», the plan of this exit and its «или до вставания» rule — or the next exit in a break.
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
            }
            ForEach(content.lines, id: \.self) { line in
                switch line {
                case .main(let text):
                    Text(text).font(.system(size: 15, weight: .medium))
                case .standing(let text):
                    Label(text, systemImage: "figure.stand")
                        .font(.callout)
                        .foregroundStyle(MacPalette.blue)
                case .note(let text):
                    Label(text, systemImage: "text.bubble")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
                StepButton(title: step.title, symbol: step.symbol, key: String(localized: "Пробел"),
                           fill: step.tint, foreground: .black) {
                    switch step {
                    case .outside: session.markBehindDoor()
                    case .backInside: session.endExit()
                    case .finish: model.finishSession()
                    }
                }
            }
            if content.canFalseStart {
                StepButton(title: String(localized: "Фальстарт"), symbol: "arrow.uturn.backward", key: "⌫",
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
    let symbol: String
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
            Image(systemName: symbol)
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
