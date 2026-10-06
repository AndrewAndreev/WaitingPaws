#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Right panel during a session: the same readout and two buttons as on the iPhone (with their keys), then the
/// numbers of the whole training and «Завершить».
struct ConsoleReadout: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    let session: TrainingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // First claim on the height: the ring grows into whatever the panel has left.
            SessionReadout(session: session, size: .mac, showsKeys: true, onFinish: { model.finishSession() })
                .padding(20)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.panel)
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
                }
                .layoutPriority(1)
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                stats(LiveSessionModel(session: session, now: context.date, recordingSince: nil))
            }
            HStack {
                Button { ui.editSessionPlan(model) } label: {
                    ShortcutLabel(title: String(localized: "Расписание"), symbol: "slider.horizontal.3", key: "⌘E")
                }
                .help("Поправить выходы и перерывы прямо во время тренировки")
                Button { ui.confirmFinish = true } label: {
                    ShortcutLabel(title: String(localized: "Завершить"), symbol: "flag.checkered", key: "⌘.")
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The whole training at a glance, below the buttons: it is not what you look at during an exit.
    private func stats(_ live: LiveSessionModel) -> some View {
        HStack(alignment: .top, spacing: 22) {
            stat(String(localized: "\(session.completedExitsCount) из \(live.plan.exits.count)"), String(localized: "выходов"))
            stat("\(session.falseStartsCount)", String(localized: "фальстартов"), tint: session.falseStartsCount > 0 ? MacPalette.orange : nil)
            stat(live.sessionElapsed, String(localized: "идёт тренировка"))
            stat("≈ \(MacFormat.time.string(from: live.eta))", String(localized: "конец по плану"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func stat(_ value: String, _ label: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(MacPalette.digits(15, weight: .semibold)).foregroundStyle(tint ?? .primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
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
