import SwiftUI
import WaitingPawsCore

/// The pad of the turning mode, over the picture: four arrows around «Готово», whose ring runs down to the moment
/// the mode switches itself off. Press an arrow for one step, hold it to keep turning. Nothing else on the picture
/// turns the camera.
struct PanTiltPad: View {
    @Environment(AppModel.self) private var model
    var diameter: CGFloat

    var body: some View {
        let panTilt = model.panTilt
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.6))
                    .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                arrow(.up).offset(y: -arrowOffset)
                arrow(.down).offset(y: arrowOffset)
                arrow(.left).offset(x: -arrowOffset)
                arrow(.right).offset(x: arrowOffset)
                DoneButton(diameter: diameter * 0.36) { withAnimation(.smooth(duration: 0.25)) { panTilt.stop() } }
            }
            .frame(width: diameter, height: diameter)
            VStack(spacing: 1) {
                Text("Turning the camera")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                Text(panTilt.failure ?? hint)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(panTilt.failure == nil ? .white.opacity(0.65) : Theme.warning)
                    .lineLimit(3)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(width: diameter + 48)
            .fixedSize(horizontal: false, vertical: true)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Turning the camera")
    }

    private var arrowOffset: CGFloat { diameter * 0.32 }

    private var hint: String {
        #if os(macOS)
        String(localized: "Or the arrow keys · Esc")
        #else
        String(localized: "Hold an arrow to keep turning")
        #endif
    }

    private func arrow(_ direction: PanTiltDirection) -> some View {
        let panTilt = model.panTilt
        let held = panTilt.held == direction
        return Image(systemName: direction.symbol)
            .font(.system(size: diameter * 0.15, weight: .bold))
            .foregroundStyle(held ? .black : .white)
            .frame(width: diameter * 0.3, height: diameter * 0.3)
            .background(Circle().fill(held ? Theme.accent : .white.opacity(0.08)))
            .contentShape(Circle())
            .scaleEffect(held ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: held)
            // Down starts a step (and the repeats), up ends them; sliding off the arrow keeps it held.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in panTilt.press(direction, target: model.panTiltTarget) }
                    .onEnded { _ in panTilt.release(direction) }
            )
            .accessibilityElement()
            .accessibilityLabel(direction.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                panTilt.press(direction, target: model.panTiltTarget)
                panTilt.release(direction)
            }
            #if os(macOS)
            .help(direction.title)
            #endif
    }
}

/// «Готово» in the middle of the pad; its ring shows the time left before the mode switches off by itself.
private struct DoneButton: View {
    @Environment(AppModel.self) private var model
    var diameter: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let left = model.panTilt.idleDeadline.map { $0.timeIntervalSince(context.date) / CameraPanTilt.idleTimeout } ?? 0
                ZStack {
                    Circle().fill(.white.opacity(0.14))
                    Circle()
                        .trim(from: 0, to: max(0, min(1, left)))
                        .stroke(Theme.accent.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(2)
                        // A held arrow keeps the mode on: the ring stays full.
                        .opacity(model.panTilt.held == nil ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: diameter * 0.34, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Done")
        #if os(macOS)
        .help("Done · Esc")
        #endif
    }
}

/// Thin frame round the picture while the turning mode is on: the picture's arrows act on the camera now.
struct PanTiltFrame: View {
    var body: some View {
        Rectangle()
            .strokeBorder(Theme.accent.opacity(0.85), lineWidth: 3)
            .allowsHitTesting(false)
    }
}

extension PanTiltDirection {
    var symbol: String {
        switch self {
        case .left: return "chevron.left"
        case .right: return "chevron.right"
        case .up: return "chevron.up"
        case .down: return "chevron.down"
        }
    }

    var title: String {
        switch self {
        case .left: return String(localized: "Turn Left")
        case .right: return String(localized: "Turn Right")
        case .up: return String(localized: "Tilt Up")
        case .down: return String(localized: "Tilt Down")
        }
    }
}
