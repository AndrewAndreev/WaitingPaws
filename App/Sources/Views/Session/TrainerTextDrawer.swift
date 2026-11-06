import SwiftUI
import WaitingPawsCore

/// The trainer's whole text over the training screen. It is not a new screen: the camera above keeps playing without
/// reconnecting (switching to the messenger for the text used to cost the picture). It rests at 80 % of the screen to
/// scroll the text in, pulls up to the whole screen and swipes down to close (or ✕). The drag follows the finger in the
/// screen's coordinates — in the drawer's own ones it fought its own movement and shook. The lines of the current exit
/// (the next one in a break) are marked and brought into view when the exit changes; the two step buttons come along,
/// smaller, so it needn't be closed for a press. Its head is the card's live number, which it covers, and ✕; the height
/// changes by the drag.
struct TrainerTextDrawer: View {
    let session: TrainingSession
    /// The height it may take: the screen's.
    let available: CGFloat
    /// The home indicator's strip: the drawer runs down under it.
    var bottomInset: CGFloat = 0
    var onFinish: () -> Void
    var onClose: () -> Void

    private enum Detent { case middle, full }

    @State private var detent: Detent = .middle
    @GestureState(resetTransaction: Transaction(animation: .smooth(duration: 0.3))) private var drag: CGFloat = 0

    /// Where it rests, of the screen's height.
    static let middleShare: CGFloat = 0.6

    private func height(of detent: Detent) -> CGFloat {
        detent == .full ? available : available * Self.middleShare
    }

    var body: some View {
        let content = ReadoutContent(session: session)
        let height = min(available, max(160, height(of: detent) - drag))
        VStack(spacing: 8) {
            top
            TrainerTextView(plan: session.plan, exitNumber: content.textExitNumber)
            ReadoutActions(session: session, height: 46, onFinish: onFinish)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10 + bottomInset)
        .frame(height: height + bottomInset, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(Theme.panel, in: UnevenRoundedRectangle(topLeadingRadius: Theme.cornerRadius,
                                                            topTrailingRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: Theme.cornerRadius, topTrailingRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 18, y: -4)
    }

    /// The grabber, the live number and ✕. Drag it: up — the whole screen, down — back to 60 % and further down
    /// closed; the release goes where the swipe was heading.
    private var top: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(.white.opacity(0.3))
                .frame(width: 38, height: 5)
                .padding(.top, 7)
            HStack(spacing: 10) {
                // The card's number, which the drawer covers: live, in the phase's colour. That this is the trainer's
                // text the text says itself.
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let status = ReadoutContent(session: session).phoneStatus(at: context.date)
                    Text(status.value)
                        .font(Theme.display(24, weight: status.kind == .ready ? .semibold : .bold))
                        .monospacedDigit()
                        .foregroundStyle(ReadoutContent.phaseColor(status))
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .accessibilityLabel(Text(verbatim: [status.label, status.value].filter { !$0.isEmpty }
                            .joined(separator: " ")))
                }
                Spacer(minLength: 0)
                IconButton(systemImage: "xmark", action: onClose)
                    .accessibilityLabel("Закрыть текст тренера")
            }
            // The whole screen or back: by the grabber's drag, and for VoiceOver as an action.
            .accessibilityAction(named: detent == .full ? Text("Уменьшить текст тренера")
                                                        : Text("Текст тренера на весь экран")) {
                withAnimation(.smooth(duration: 0.3)) { detent = detent == .full ? .middle : .full }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .updating($drag) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                    let landing = height(of: detent) - value.predictedEndTranslation.height
                    if landing < available * 0.45 {
                        onClose()
                    } else {
                        withAnimation(.smooth(duration: 0.3)) {
                            detent = landing > (height(of: .middle) + height(of: .full)) / 2 ? .full : .middle
                        }
                    }
                }
        )
    }
}
