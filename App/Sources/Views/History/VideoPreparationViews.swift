import SwiftUI
import WaitingPawsCore

/// How a recording being prepared (`AppModel.VideoPreparation`) shows in the history, the same on iPhone and Mac
/// (lab `Design/unfinished-video-lab`, variant B): a ring where its frame or length would be, and in the player's
/// place «Готовим видео · 42 %» with a bar and «ещё ≈ 6 мин». A usual recording is ready in a second or two and
/// shows none of it for long; a night's one takes minutes.
enum PreparationText {
    /// «42 %».
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// «Готовим видео · 42 %»; «Готовим видео…» until the first step is done.
    static func title(_ preparation: AppModel.VideoPreparation?) -> String {
        guard let fraction = preparation?.fraction, fraction > 0 else { return String(localized: "Готовим видео…") }
        return String(localized: "Готовим видео · \(percent(fraction))")
    }

    /// «ещё ≈ 6 мин», «ещё ≈ 40 с»; `nil` until the pace is clear.
    static func remaining(_ preparation: AppModel.VideoPreparation?) -> String? {
        guard let seconds = preparation?.remaining else { return nil }
        let rounded = seconds < 60 ? max(10, (seconds / 10).rounded() * 10) : (seconds / 60).rounded() * 60
        return String(localized: "ещё ≈ \(DurationText.short(rounded))")
    }

    /// Why a recording from before is being prepared now.
    static var leftover: String {
        String(localized: "Запись не успела подготовиться в прошлый раз. Доделываем в фоне.")
    }

    /// A raw recording's length, read from its file's times: «≈ 14:25:00».
    static func estimate(_ seconds: TimeInterval) -> String {
        "≈ " + DurationText.clock(seconds)
    }
}

/// The part of the work done, as a ring on a faint track (a table tile, a list row).
struct PreparationRing: View {
    var fraction: Double
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(.tertiary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, fraction)))
                .stroke(.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.linear(duration: 0.4), value: fraction)
        .accessibilityElement()
        .accessibilityLabel(PreparationText.title(AppModel.VideoPreparation(fraction: fraction)))
    }
}

/// In the player's place while the video is prepared: white on its black.
struct PreparationPoster: View {
    let preparation: AppModel.VideoPreparation?
    /// The Mac inspector's smaller type.
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 7 : 10) {
            if let fraction = preparation?.fraction, fraction > 0 {
                Text(PreparationText.title(preparation))
                    .font(compact ? .callout : .body)
                    .monospacedDigit()
                bar(fraction)
                    .frame(width: compact ? 150 : 200, height: compact ? 4 : 5)
                // Always a line here, so the title does not jump when the estimate appears.
                Text(PreparationText.remaining(preparation) ?? " ")
                    .font(compact ? .caption : .footnote)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ProgressView()
                    .controlSize(compact ? .small : .regular)
                    .tint(.white)
                Text("Готовим видео…").font(compact ? .callout : .body)
            }
        }
        .foregroundStyle(.white.opacity(0.75))
        .multilineTextAlignment(.center)
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private func bar(_ fraction: Double) -> some View {
        GeometryReader { box in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(.white.opacity(0.85))
                    .frame(width: max(box.size.height, box.size.width * min(1, fraction)))
            }
        }
        .animation(.linear(duration: 0.4), value: fraction)
    }
}

/// Shows its content only if it is still there after a moment: a usual recording is prepared in a second or two, and
/// its ring or poster should not flash (as `MacHistoryDelayed` on Mac).
struct PreparationDelayed<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var visible = false

    var body: some View {
        content
            .opacity(visible ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation(.easeOut(duration: 0.15)) { visible = true }
            }
    }
}
