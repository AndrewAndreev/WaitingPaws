import SwiftUI
import WaitingPawsCore

/// The trainer's whole text over the training screen. It is not a new screen: the camera above keeps playing without
/// reconnecting (switching to the messenger for the text used to cost the picture). It rests at 80 % of the screen to
/// scroll the text in, pulls up to the whole screen and swipes down to close (or ✕). The drag follows the finger in the
/// screen's coordinates — in the drawer's own ones it fought its own movement and shook. The lines of the current exit
/// (the next one in a break) are marked and brought into view when the exit changes; the two step buttons come along,
/// smaller, so it needn't be closed for a press.
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
    static let middleShare: CGFloat = 0.8

    private func height(of detent: Detent) -> CGFloat {
        detent == .full ? available : available * Self.middleShare
    }

    var body: some View {
        let content = ReadoutContent(session: session)
        let height = min(available, max(160, height(of: detent) - drag))
        VStack(spacing: 8) {
            top(content)
            TrainerTextView(text: session.plan.rawText, exitNumber: content.textExitNumber)
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

    /// The grabber, «Текст тренера», the live clock of the moment and ✕. Drag it: up — the whole screen, down — back
    /// to 80 % and further down closed; the release goes where the swipe was heading.
    private func top(_ content: ReadoutContent) -> some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(.white.opacity(0.3))
                .frame(width: 38, height: 5)
                .padding(.top, 7)
            HStack(spacing: 10) {
                Text("Текст тренера")
                    .font(Theme.display(18, weight: .bold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let timer = content.timer(at: context.date)
                    // «Последний перерыв · 1:02», or only the clock in its colour on a small iPhone.
                    ViewThatFits(in: .horizontal) {
                        Pill(text: "\(content.title) · \(timer.text)", tint: timer.tint)
                        Pill(text: timer.text, tint: timer.tint)
                    }
                    .monospacedDigit()
                }
                IconButton(systemImage: detent == .full ? "chevron.down" : "chevron.up") {
                    withAnimation(.smooth(duration: 0.3)) { detent = detent == .full ? .middle : .full }
                }
                .accessibilityLabel(detent == .full ? "Уменьшить текст тренера" : "Текст тренера на весь экран")
                IconButton(systemImage: "xmark", action: onClose)
                    .accessibilityLabel("Закрыть текст тренера")
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
