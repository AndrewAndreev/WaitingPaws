import SwiftUI
import AVKit
import WaitingPawsCore

/// Where a history row leads.
enum HistoryRoute: Hashable {
    case session(UUID)
    case clip(String)
}

/// Past sessions with their logs and recordings, and recordings made without a training.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClearAll = false
    @State private var path: [HistoryRoute] = []

    private enum Item: Identifiable {
        case session(TrainingRecord)
        case clip(RecordingClip)

        var id: HistoryRoute {
            switch self {
            case .session(let record): return .session(record.id)
            case .clip(let clip): return .clip(clip.id)
            }
        }

        var date: Date {
            switch self {
            case .session(let record): return record.startedAt
            case .clip(let clip): return clip.date
            }
        }

        var isClip: Bool {
            if case .clip = self { return true }
            return false
        }
    }

    private var items: [Item] {
        (model.history.map(Item.session) + model.clips.map(Item.clip)).sorted { $0.date > $1.date }
    }

    private func delete(_ item: Item) {
        switch item {
        case .session(let record): model.delete(record, includingRecording: true)
        case .clip(let clip): model.delete(clip)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                let items = items
                if items.isEmpty {
                    ContentUnavailableView("Пока нет тренировок", systemImage: "pawprint",
                                           description: Text("После первой тренировки здесь появятся лог и видео."))
                } else {
                    List {
                        ForEach(items) { item in
                            NavigationLink(value: item.id) {
                                switch item {
                                case .session(let record):
                                    HistoryRow(record: record, hasVideo: model.store.recordingURL(for: record) != nil)
                                case .clip(let clip):
                                    ClipRow(clip: clip)
                                }
                            }
                            .contextMenu {
                                Button(item.isClip ? "Удалить запись" : "Удалить вместе с видео", systemImage: "trash", role: .destructive) {
                                    delete(item)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { delete(items[index]) }
                        }
                    }
                    #if os(macOS)
                    .listStyle(.inset)
                    #endif
                }
            }
            .navigationTitle("История")
            .navigationDestination(for: HistoryRoute.self) { route in
                switch route {
                case .session(let id):
                    if let record = model.history.first(where: { $0.id == id }) {
                        HistoryDetailView(record: record)
                    }
                case .clip(let id):
                    if let clip = model.clips.first(where: { $0.id == id }) {
                        ClipDetailView(clip: clip)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        #if os(macOS)
                        Button("Показать папку в Finder", systemImage: "folder") { Finder.reveal(model.store.rootDirectory) }
                        #endif
                        Button("Удалить всё", systemImage: "trash", role: .destructive) { confirmClearAll = true }
                            .disabled(model.history.isEmpty && model.clips.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                #endif
            }
            .confirmationDialog("Удалить всю историю?", isPresented: $confirmClearAll, titleVisibility: .visible) {
                Button("Удалить тренировки (\(model.history.count)) и записи (\(model.clips.count))", role: .destructive) { model.deleteAll() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Логи и видео будут удалены с устройства. Копии в Фото останутся.")
            }
        }
        .onAppear {
            model.reloadHistory()
            #if DEBUG
            // `--demo-screen history-last` opens the newest entry right away.
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--demo-screen"), arguments.dropFirst(index + 1).first == "history-last",
               let newest = items.first {
                path = [newest.id]
            }
            #endif
        }
    }
}

/// "4 окт., 13:25"; the year is added for older entries.
enum HistoryDate {
    static func string(from date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return (sameYear ? thisYear : otherYear).string(from: date)
    }

    private static let thisYear = formatter("d MMM, HH:mm")
    private static let otherYear = formatter("d MMM yyyy, HH:mm")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = format
        return formatter
    }
}

private struct HistoryRow: View {
    let record: TrainingRecord
    let hasVideo: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.plan.title).font(.headline).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasVideo {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
            Text(DurationText.clock(record.duration))
                .font(.system(.subheadline, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = [HistoryDate.string(from: record.startedAt), "\(record.completedExits)/\(record.plan.exits.count) выходов"]
        if record.falseStarts > 0 { parts.append("фальстартов \(record.falseStarts)") }
        return parts.joined(separator: " · ")
    }
}

private struct ClipRow: View {
    let clip: RecordingClip
    @State private var duration: TimeInterval?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Запись без тренировки").font(.headline).lineLimit(1)
                Text(HistoryDate.string(from: clip.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "film").foregroundStyle(.secondary)
            Text(duration.map { DurationText.clock($0) } ?? " ")
                .font(.system(.subheadline, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .task(id: clip.id) { duration = await clip.loadDuration() }
    }
}

/// Player plus share / Photos / Finder buttons for one recording file.
private struct RecordingSection: View {
    @Environment(AppModel.self) private var model
    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause() }
            // Recordings made before finalization existed are converted on first open.
            .task(id: url) { await model.finalizeRecording(url) }
        let preparing = model.finalizingFileNames.contains(url.lastPathComponent)
        HStack {
            ShareLink(item: url) {
                Label(preparing ? "Готовим видео…" : "Поделиться", systemImage: "square.and.arrow.up")
            }
            .disabled(preparing)
            Button { model.saveToPhotos(url) } label: { Label("В Фото", systemImage: "photo.on.rectangle.angled") }
                .disabled(preparing)
            #if os(macOS)
            Button { Finder.reveal(url) } label: { Label("В Finder", systemImage: "folder") }
            #endif
        }
        .buttonStyle(.bordered)
        let status = model.photosStatus(for: url.lastPathComponent)
        if let error = status.error {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Theme.warning)
        } else if status.saved {
            Label("Сохранено в Фото", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.accent)
        }
    }
}

/// A recording without a training: just the video.
struct ClipDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let clip: RecordingClip

    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RecordingSection(url: clip.url)
            }
            .padding(16)
        }
        .navigationTitle(HistoryDate.string(from: clip.date))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
            }
        }
        .confirmationDialog("Удалить запись?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                model.delete(clip)
                dismiss()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Копия в Фото останется.")
        }
    }
}

struct HistoryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: TrainingRecord

    @State private var confirmDelete = false

    /// "план 5 с или до вставания · попытка 2 · перерыв 5:05"; the break after the last exit only ends the session.
    private func details(for result: ExitResult, showsBreak: Bool) -> Text {
        var plan = "план \(DurationText.short(result.plannedDuration))"
        if result.untilStanding { plan += " или до вставания" }
        let attempt = result.attempt > 1 ? " · попытка \(result.attempt)" : ""
        let pause = showsBreak ? SessionLogFormatter.breakText(for: result).map { " · \($0)" } ?? "" : ""
        return Text("\(plan)\(Text(attempt).foregroundStyle(Theme.warning))\(pause)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let url = model.store.recordingURL(for: record) {
                    RecordingSection(url: url)
                } else {
                    Label("Видео не записывалось или файл удалён", systemImage: "video.slash")
                        .foregroundStyle(.secondary)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Выходы · \(record.completedExits) из \(record.plan.exits.count)").font(.headline)
                            Spacer()
                            // The same lines as text, for the trainer.
                            ShareLink(item: SessionLogFormatter.text(for: record)) {
                                Label("Лог", systemImage: "square.and.arrow.up")
                            }
                            .font(.footnote)
                        }
                        ForEach(Array(record.results.enumerated()), id: \.element.id) { index, result in
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(result.number)")
                                    .font(.system(.headline, design: .rounded).monospacedDigit())
                                    .frame(width: 28, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(SessionLogFormatter.outcome(of: result))
                                        .font(.subheadline)
                                    details(for: result, showsBreak: index < record.results.count - 1)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: result.falseStart ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(result.falseStart ? Theme.danger : Theme.accent)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(record.plan.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
            }
        }
        .confirmationDialog("Удалить тренировку?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить вместе с видео", role: .destructive) {
                model.delete(record, includingRecording: true)
                dismiss()
            }
            if model.store.recordingURL(for: record) != nil {
                Button("Удалить только лог, видео оставить") {
                    model.delete(record, includingRecording: false)
                    dismiss()
                }
            }
            Button("Отмена", role: .cancel) {}
        }
    }
}
