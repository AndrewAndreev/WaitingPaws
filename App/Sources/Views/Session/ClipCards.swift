import SwiftUI
import WaitingPawsCore

/// Recording without a training: only the running time and a stop button.
struct ClipRecordingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Запись без тренировки", systemImage: "record.circle.fill")
                    .font(Theme.display(20, weight: .bold))
                    .labelStyle(TintedIconLabelStyle(tint: Theme.danger))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(DurationText.clock(model.recorder.duration(at: context.date)))
                        .font(Theme.display(48, weight: .bold))
                        .monospacedDigit()
                }
                BigButton(title: "Остановить запись", systemImage: "stop.fill", style: .destructive) {
                    model.stopRecording(deleteFile: false)
                }
            }
        }
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
                    IconButton(systemImage: "xmark", action: onClose)
                }
                Text([duration.map { DurationText.clock($0) }, photos.saved ? "в Фото" : nil].compactMap { $0 }.joined(separator: " · "))
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
                    BigButton(title: "История", systemImage: "clock.arrow.circlepath", style: .secondary, height: 44, action: onHistory)
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
