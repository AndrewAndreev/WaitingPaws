#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Get Info–style inspector of the selected row: video with the exit strip, totals, the per-exit log, the file.
struct MacHistoryInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(MacHistoryController.self) private var controller
    let row: MacHistoryRow

    private var preparing: Bool {
        row.video.map { model.finalizingFileNames.contains($0.fileName) } ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    preview
                    if let record = row.record { strip(record) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.system(size: 15, weight: .semibold))
                            .textSelection(.enabled)
                        Text(MacHistoryFormat.longDay(row))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.top, 2)
                }
                .padding(14)

                if let record = row.record {
                    InspectorSection(String(localized: "Итоги")) { totals(record) }
                    InspectorSection(String(localized: "Лог")) { log(record) }
                }
                InspectorSection(String(localized: "Видео")) { videoInfo }

                Divider()
                deleteButton
                    .padding(14)
            }
        }
        #if DEBUG
        .defaultScrollAnchor(MacHistoryDebug.inspectorAnchor)
        #endif
        // Recordings are remuxed once after stopping (or on first open, for older ones); the player waits for that.
        .task(id: row.video?.url) {
            guard let url = row.video?.url else {
                controller.player.load(nil)
                return
            }
            if !controller.finalizedURLs.contains(url) {
                await model.finalizeRecording(url)
                controller.finalizedURLs.insert(url)
            }
            guard !Task.isCancelled else { return }
            controller.player.load(url)
            #if DEBUG
            if let seconds = MacHistoryDebug.seek { controller.player.seek(to: seconds) }
            #endif
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        if let video = row.video {
            ZStack {
                Color.black
                if preparing || controller.player.url != video.url {
                    MacHistoryDelayed {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(preparing ? "Готовим видео…" : "Открываем видео…").font(.callout)
                        }
                        .foregroundStyle(.white.opacity(0.7))
                    }
                } else {
                    MacHistoryPlayerView(player: controller.player.player)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        } else {
            HStack(spacing: 12) {
                Image(systemName: "video.slash")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Видео нет")
                    Text(row.record?.recordingFileName == nil ? "Запись не включали" : "Файл видео удалён")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.6)))
        }
    }

    private func strip(_ record: TrainingRecord) -> some View {
        let hasVideo = row.video != nil
        let base = hasVideo ? record.recordingStartDate : record.startedAt
        let total = hasVideo ? (row.video?.duration ?? record.finishedAt.timeIntervalSince(base)) : record.duration
        return MacHistoryExitStrip(record: record, base: base, total: total,
                                   player: hasVideo && controller.player.url == row.video?.url ? controller.player : nil)
    }

    // MARK: Sections

    private func totals(_ record: TrainingRecord) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
            if !record.plan.trainers.isEmpty { info(String(localized: "Тренеры"), record.plan.trainers) }
            info(String(localized: "Выходы"), String(localized: "\(record.completedExits) из \(record.plan.exits.count) по плану"))
            GridRow {
                label(String(localized: "Фальстарты"))
                Text(record.falseStarts == 0 ? "нет" : "\(record.falseStarts)")
                    .foregroundStyle(record.falseStarts == 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(MacHistoryInk.orange))
            }
            GridRow {
                label(String(localized: "Дольше всего"))
                Text("\(Text(DurationText.clock(record.longestStayBehindDoor)).fontWeight(.semibold))  \(Text("план \(DurationText.clock(record.longestPlannedExit))").foregroundStyle(.secondary))")
                    .monospacedDigit()
            }
            info(String(localized: "Длительность"), DurationText.clock(record.duration))
        }
    }

    private func log(_ record: TrainingRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MacHistoryExitLog(record: record, base: record.recordingStartDate,
                              player: row.video != nil && controller.player.url == row.video?.url ? controller.player : nil)

            let notes = record.events.filter { $0.kind == .note && !($0.detail ?? "").isEmpty }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notes) { note in
                        let time = MacFormat.time.string(from: note.time)
                        let when = note.exitNumber.map { String(localized: "\(time), выход \($0)") } ?? time
                        Text("\(Text(when).foregroundStyle(.secondary))  \(note.detail ?? "")")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 10)
            }

            // The shortcut hint goes first when the inspector is too narrow for it.
            ViewThatFits(in: .horizontal) {
                logButtons(record, showsShortcut: true)
                logButtons(record, showsShortcut: false)
            }
            .padding(.top, 12)
        }
    }

    private func logButtons(_ record: TrainingRecord, showsShortcut: Bool) -> some View {
        HStack(spacing: 8) {
            Button { controller.copyLog(of: row) } label: {
                if controller.copiedLog == row.id {
                    Label("Скопировано", systemImage: "checkmark")
                } else {
                    ShortcutLabel(title: String(localized: "Скопировать"), symbol: "doc.on.doc", key: showsShortcut ? "⇧⌘C" : nil)
                }
            }
            .help("Скопировать лог для тренера (⇧⌘C)")
            if let text = row.logText {
                ShareLink(item: text, subject: Text(record.plan.title), preview: SharePreview(record.plan.title)) {
                    Label("Отправить…", systemImage: "square.and.arrow.up")
                }
                .help("Отправить лог тренеру")
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var videoInfo: some View {
        if let video = row.video {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                GridRow {
                    label(String(localized: "Файл"))
                    Text(video.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(video.fileName)
                        .textSelection(.enabled)
                }
                info(String(localized: "Длина"), video.duration.map(DurationText.clock) ?? "—")
                info(String(localized: "Размер"), MacHistoryFormat.bytes(video.bytes))
            }
            HStack(spacing: 8) {
                Button("В Finder", systemImage: "folder") { controller.revealInFinder(row, model: model) }
                    .help("Показать видео в Finder")
                Button("В Фото", systemImage: "photo.badge.plus") { model.saveToPhotos(video.url) }
                    .disabled(preparing || model.photosStatus(for: video.fileName).saved)
                    .help("Сохранить видео в Фото")
                ShareLink(item: video.url) { Image(systemName: "square.and.arrow.up") }
                    .disabled(preparing)
                    .help("Отправить видео…")
            }
            .padding(.top, 10)
            videoStatus(video)
        } else {
            Text("От этой тренировки остался только лог.")
                .foregroundStyle(.secondary)
            if row.record != nil {
                Button("Показать лог в Finder", systemImage: "folder") { controller.revealInFinder(row, model: model) }
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private func videoStatus(_ video: MacHistoryVideo) -> some View {
        let status = model.photosStatus(for: video.fileName)
        if preparing {
            MacHistoryDelayed {
                Label("Готовим видео для отправки…", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }
        } else if let error = status.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(MacHistoryInk.orange).padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
        } else if status.saved {
            Label("Сохранено в Фото", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(MacHistoryInk.green).padding(.top, 8)
        }
    }

    @ViewBuilder
    private var deleteButton: some View {
        switch row.kind {
        case .training:
            if row.video != nil {
                Menu {
                    Button("Удалить тренировку и видео…", role: .destructive) { controller.confirmDelete(row, onlyLog: false) }
                    Button("Удалить только лог, видео оставить…") { controller.confirmDelete(row, onlyLog: true) }
                } label: {
                    Label("Удалить…", systemImage: "trash")
                }
                .menuStyle(.button)
                .fixedSize()
            } else {
                Button("Удалить тренировку…", systemImage: "trash", role: .destructive) { controller.confirmDelete(row) }
            }
        case .clip:
            Button("Удалить запись…", systemImage: "trash", role: .destructive) { controller.confirmDelete(row) }
        }
    }

    // MARK: Helpers

    private func label(_ text: String) -> some View {
        Text(text + ":").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func info(_ title: String, _ value: String) -> some View {
        GridRow {
            label(title)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }
}

/// Shows its content only if it is still on screen after a moment (no flash for quick checks).
struct MacHistoryDelayed<Content: View>: View {
    var delay: Duration = .milliseconds(400)
    @ViewBuilder let content: Content
    @State private var visible = false

    var body: some View {
        content
            .opacity(visible ? 1 : 0)
            .task {
                try? await Task.sleep(for: delay)
                withAnimation(.easeOut(duration: 0.15)) { visible = true }
            }
    }
}

/// Inspector section: hairline, small title with a disclosure chevron, content.
private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @State private var expanded = true

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .accessibilityLabel(expanded ? "Свернуть «\(title)»" : "Развернуть «\(title)»")
            if expanded {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
    }
}

/// Planned vs actual, one row per attempt; with a video a click jumps to that exit.
struct MacHistoryExitLog: View {
    let record: TrainingRecord
    /// Clock time of the start of the video.
    let base: Date
    var player: MacHistoryPlayer?

    @State private var hovered: UUID?

    private enum Width {
        static let number: CGFloat = 26
        static let planned: CGFloat = 40
        static let actual: CGFloat = 42
        static let status: CGFloat = 16
        static let rest: CGFloat = 50
        static let restPlan: CGFloat = 40
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("№").frame(width: Width.number, alignment: .leading)
                Text("План").frame(width: Width.planned, alignment: .trailing)
                Text("Факт").frame(width: Width.actual, alignment: .trailing)
                Color.clear.frame(width: Width.status, height: 1)
                Text("Перерыв").frame(width: Width.rest, alignment: .trailing)
                Text("план").frame(width: Width.restPlan, alignment: .trailing)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            Divider()
            ForEach(Array(record.results.enumerated()), id: \.element.id) { index, result in
                line(result, isLast: index == record.results.count - 1)
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
    }

    private func line(_ result: ExitResult, isLast: Bool) -> some View {
        let rest = isLast ? nil : result.actualBreak
        let restOff = rest.map { abs($0 - result.plannedBreak) > 15 } ?? false
        let canJump = player != nil
        return HStack(spacing: 8) {
            Text(result.attempt > 1 ? "\(result.number)·\(result.attempt)" : "\(result.number)")
                .foregroundStyle(.secondary)
                .frame(width: Width.number, alignment: .leading)
            Text(DurationText.clock(result.plannedDuration) + (result.untilStanding ? "*" : ""))
                .foregroundStyle(.secondary)
                .frame(width: Width.planned, alignment: .trailing)
            Text(result.leftAt == nil ? "—" : DurationText.clock(result.awayDuration))
                .fontWeight(.semibold)
                .foregroundStyle(result.falseStart ? AnyShapeStyle(MacHistoryInk.orange) : AnyShapeStyle(.primary))
                .frame(width: Width.actual, alignment: .trailing)
            Image(systemName: result.falseStart ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, result.falseStart ? MacPalette.orange : MacHistoryInk.green)
                .imageScale(.small)
                .frame(width: Width.status)
            Text(rest.map(DurationText.clock) ?? "—")
                .foregroundStyle(restOff ? AnyShapeStyle(MacHistoryInk.orange) : rest == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: Width.rest, alignment: .trailing)
            Text(rest == nil ? "" : DurationText.clock(result.plannedBreak))
                .foregroundStyle(.tertiary)
                .frame(width: Width.restPlan, alignment: .trailing)
            Spacer(minLength: 0)
            if canJump {
                Image(systemName: "play.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .opacity(hovered == result.id ? 1 : 0)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(hovered == result.id && canJump ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = result.id } else if hovered == result.id { hovered = nil }
        }
        .onTapGesture {
            guard let player else { return }
            player.seek(to: result.startedAt.timeIntervalSince(base))
        }
        .help(help(for: result, canJump: canJump))
    }

    private func help(for result: ExitResult, canJump: Bool) -> String {
        var parts = [result.attempt > 1
            ? String(localized: "Выход \(result.number), попытка \(result.attempt)")
            : String(localized: "Выход \(result.number)")]
        parts.append(SessionLogFormatter.outcome(of: result))
        if result.untilStanding { parts.append(String(localized: "* план: или до вставания")) }
        let text = parts.joined(separator: ", ")
        return canJump ? String(localized: "\(text). Нажмите, чтобы перейти к этому выходу в видео.") : text
    }
}
#endif
