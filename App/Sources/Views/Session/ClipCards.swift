import SwiftUI
import WaitingPawsCore

/// Recording without a training — here or on the linked Mac: the picture takes the screen and the clock
/// with a stop button floats over it on a translucent panel (stop on a linked iPhone stops the Mac).
struct ClipRecordingOverlay: View {
    @Environment(AppModel.self) private var model
    /// Asks before stopping (`SessionScreen`).
    var onStop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 14) {
                HStack(spacing: 9) {
                    BreathingDot()
                    Text(DurationText.clock(model.recordingDuration(at: context.date)))
                        .font(Theme.display(32, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.isLinkedToMac ? "Запись на \(model.linkedHostKind)" : "Запись без тренировки")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    Text(model.isLinkedToMac ? "Видео сохранится на \(model.linkedHostKind)" : "Видео появится в истории")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Theme.danger, in: Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Остановить запись")
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            // Translucent but no blur: a backdrop blur over live video costs the iPhone too much (see GlassCard).
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
    }
}

/// A red dot that breathes while recording.
private struct BreathingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.danger)
            .frame(width: 12, height: 12)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

/// Right after a recording without a training: share it at once or find it later in history.
struct ClipSavedCard: View {
    @Environment(AppModel.self) private var model
    let clip: RecordingClip
    var onClose: () -> Void
    var onHistory: () -> Void

    @State private var duration: TimeInterval?

    var body: some View {
        let name = clip.url.lastPathComponent
        let preparing = model.finalizingFileNames.contains(name)
        let photos = model.photosStatus(for: name)
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Запись сохранена")
                        .font(Theme.display(22, weight: .bold))
                    Spacer()
                    IconButton(systemImage: "xmark", label: String(localized: "Закрыть"), action: onClose)
                }
                Text([duration.map { DurationText.clock($0) }, photos.saved ? String(localized: "в Фото") : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(.subheadline, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                if let error = photos.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Theme.warning)
                }
                HStack(spacing: 8) {
                    ShareLink(item: clip.url) {
                        Label(preparing ? "Готовим…" : "Поделиться", systemImage: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Theme.control, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(preparing)
                    BigButton(title: String(localized: "История"), systemImage: "clock.arrow.circlepath", style: .secondary, height: 44, action: onHistory)
                }
            }
        }
        // Re-read once the file is finalized: a fragmented MP4 may report a rough duration.
        .task(id: preparing) { duration = await clip.loadDuration() }
    }
}

/// Label whose icon is tinted separately from the title.
private struct TintedIconLabelStyle: LabelStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
