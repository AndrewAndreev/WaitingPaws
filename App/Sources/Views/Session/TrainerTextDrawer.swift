import SwiftUI
import WaitingPawsCore

/// The trainer's whole text over the training screen. It is not a new screen: the camera above keeps playing without
/// reconnecting (switching to the messenger for the text used to cost the picture). Half the screen or almost all
/// of it — drag the top up or down; down from half, or ✕, closes it. The lines of the current exit (the next one in a
/// break) are marked and kept in view; the two step buttons come along, smaller, so it needn't be closed for a press.
struct TrainerTextDrawer: View {
    let session: TrainingSession
    /// The height it may take: the screen's.
    let available: CGFloat
    var onFinish: () -> Void
    var onClose: () -> Void

    @State private var tall = false
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        let content = ReadoutContent(session: session)
        let height = (tall ? available * 0.9 : available * 0.52) - drag
        VStack(spacing: 8) {
            top(content)
            TrainerTextView(text: session.plan.rawText, exitNumber: content.textExitNumber)
            ReadoutActions(session: session, height: 46, onFinish: onFinish)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(height: min(available, max(220, height)), alignment: .top)
        .frame(maxWidth: .infinity)
        .background {
            // Down under the home indicator too.
            UnevenRoundedRectangle(topLeadingRadius: Theme.cornerRadius, topTrailingRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.panel)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: Theme.cornerRadius, topTrailingRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 18, y: -4)
    }

    /// The grabber, «Текст тренера», the live clock of the moment and ✕. Dragging here resizes or closes.
    private func top(_ content: ReadoutContent) -> some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(.white.opacity(0.3))
                .frame(width: 38, height: 5)
                .padding(.top, 7)
            HStack(spacing: 10) {
                Text("Текст тренера")
                    .font(Theme.display(18, weight: .bold))
                Spacer(minLength: 0)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let timer = content.timer(at: context.date)
                    Pill(text: "\(content.title) · \(timer.text)", tint: timer.tint)
                        .monospacedDigit()
                }
                IconButton(systemImage: "xmark", action: onClose)
                    .accessibilityLabel("Закрыть текст тренера")
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 6)
                .updating($drag) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                    let moved = value.translation.height
                    withAnimation(.smooth(duration: 0.3)) {
                        if moved < -50 {
                            tall = true
                        } else if moved > 70 {
                            if tall { tall = false } else { onClose() }
                        }
                    }
                }
        )
    }
}
