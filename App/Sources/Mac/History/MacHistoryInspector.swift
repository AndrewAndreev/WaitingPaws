#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Get Info–style inspector of the selected row: the video (or one line why there is none) with the exit strip, the
/// title with when, how long and who, the per-exit log, the file.
struct MacHistoryInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(MacHistoryController.self) private var controller
    let row: MacHistoryRow

    /// «Пт, 2 окт. · 18:36–19:04 · 28 мин».
    private var when: String {
        var parts = [MacHistoryFormat.day(row.date), row.timeRange]
        if let record = row.record {
            parts.append(DurationText.short(max(60, (record.duration / 60).rounded() * 60)))
        }
        return parts.joined(separator: " · ")
    }

    private var preparing: Bool {
        row.video.map { model.finalizingFileNames.contains($0.fileName) } ?? false
    }

    /// Still raw because preparing it failed (the reason is under the buttons): played, sent and saved as it is.
    private func preparationFailed(_ video: MacHistoryVideo) -> Bool {
        !preparing && video.unfinished && model.preparationErrors[video.fileName] != nil
    }

    /// Waiting to be prepared, or being prepared: nothing opens it until then.
    private func awaitingPreparation(_ video: MacHistoryVideo) -> Bool {
        preparing || (video.unfinished && !preparationFailed(video))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    preview
                    if let record = row.record { strip(record) }
                    // Two lines, as the iPhone's: «Тренировка на пятницу · Аня/Марк» / «Пт, 2 окт. · 18:36–19:04 ·
                    // 28 мин» — the trainers and the length are what the table leaves out.
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(verbatim: row.title)
                                .font(.system(size: 15, weight: .semibold))
                                .layoutPriority(1)
                            if !row.trainers.isEmpty {
                                Text(verbatim: " · \(row.trainers)").foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        .textSelection(.enabled)
                        Text(verbatim: when)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.top, 2)
                }
                .padding(14)

                if let record = row.record {
                    InspectorSection(String(localized: "Лог")) { log(record) }
                }
                if row.video != nil {
                    InspectorSection(String(localized: "Видео")) { videoInfo }
                }

                // Deleting is the toolbar's 🗑, the row's menu and ⌫: one place, not a button here too.
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
                // Still raw: preparing it failed. The player gets it as it is, so it can still be watched: AVFoundation
                // indexes it frame by frame (seconds for a night's recording), once, and only the player opens it, not
                // the length or the frame. Selecting it again tries preparing it again.
                if !RecordingFinalizer.isUnfinished(url) { controller.finalizedURLs.insert(url) }
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
                if awaitingPreparation(video) {
                    MacHistoryDelayed {
                        PreparationPoster(preparation: model.videoPreparations[video.fileName], compact: true)
                    }
                } else if controller.player.url != video.url {
                    MacHistoryDelayed {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Открываем видео…").font(.callout)
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
        }
        // Without a video, nothing in its place: the row's missing thumbnail says it.
    }

    private func strip(_ record: TrainingRecord) -> some View {
        let hasVideo = row.video != nil
        let base = hasVideo ? record.recordingStartDate : record.startedAt
        let total = hasVideo ? (row.video?.duration ?? record.finishedAt.timeIntervalSince(base)) : record.duration
        return MacHistoryExitStrip(record: record, base: base, total: total,
                                   player: hasVideo && controller.player.url == row.video?.url ? controller.player : nil)
    }

    // MARK: Sections

    private func log(_ record: TrainingRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MacHistoryExitLog(record: record, base: record.recordingStartDate,
                              player: row.video != nil && controller.player.url == row.video?.url ? controller.player : nil)

            // The owner's marks from behind the door stand under their exits' rows; these are the free notes.
            let notes = record.events.filter { $0.kind == .note && $0.observed != true && !($0.detail ?? "").isEmpty }
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
            // Sending is the toolbar's ⬆︎ (and the row's menu); ⇧⌘C copies: no button of its own here.
        }
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
                info(String(localized: "Длина"), video.duration.map(DurationText.clock)
                     ?? video.estimate.map(PreparationText.estimate) ?? "—")
                info(String(localized: "Размер"), MacHistoryFormat.bytes(video.bytes))
                if let record = row.record {
                    recordingRow(RecordingReport(record: record, model: model, hasVideo: true))
                }
            }
            HStack(spacing: 8) {
                Button("В Finder", systemImage: "folder") { controller.revealInFinder(row, model: model) }
                    .help("Показать видео в Finder")
                Button("В Фото", systemImage: "photo.badge.plus") { model.saveToPhotos(video.url) }
                    .disabled(awaitingPreparation(video) || model.photosStatus(for: video.fileName).saved)
                    .help("Сохранить видео в Фото")
                MacShareButton(.file(video.url)) { Image(systemName: "square.and.arrow.up") }
                    .disabled(awaitingPreparation(video))
                    .help("Отправить видео…")
            }
            .padding(.top, 10)
            videoStatus(video)
        }
    }

    /// «Запись: шла всю тренировку», or how much of the training this video holds: «прерывалась в 18:44 на 2:10 ·
    /// в этом видео — выходы 5–7», with the way to the part before the break (a recording of its own).
    @ViewBuilder
    private func recordingRow(_ report: RecordingReport) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            label(String(localized: "Запись"))
            VStack(alignment: .leading, spacing: 2) {
                Text(report.text)
                if let detail = report.detail {
                    Text(detail).foregroundStyle(.secondary)
                }
                ForEach(report.earlierParts) { part in
                    Button(part.title) {
                        controller.selection = .clip(part.clip.id)
                        controller.scrollRequest += 1
                    }
                    .buttonStyle(.link)
                }
            }
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func videoStatus(_ video: MacHistoryVideo) -> some View {
        let status = model.photosStatus(for: video.fileName)
        if preparing {
            MacHistoryDelayed {
                Label(model.videoPreparations[video.fileName]?.leftover == true
                      ? PreparationText.leftover : String(localized: "Готовим видео для отправки…"),
                      systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let error = model.preparationErrors[video.fileName], video.unfinished {
            Label(String(localized: "Не удалось подготовить видео: \(error)"), systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(MacHistoryInk.orange).padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
        } else if let error = status.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(MacHistoryInk.orange).padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
        } else if status.saved {
            Label("Сохранено в Фото", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(MacHistoryInk.green).padding(.top, 8)
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

/// Planned vs actual, one row per attempt, with what the owner marked from behind the door under it («легла 0:12 ·
/// замолчала 0:41»); with a video a click jumps to that exit.
struct MacHistoryExitLog: View {
    let record: TrainingRecord
    /// Clock time of the start of the video.
    let base: Date
    var player: MacHistoryPlayer?

    @State private var hovered: UUID?

    private enum Width {
        static let number: CGFloat = 34
        static let planned: CGFloat = 40
        static let actual: CGFloat = 42
        /// «Перерыв» (after the exit), one line.
        static let rest: CGFloat = 56
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The break after the exit, as the log says it («перерыв после 2:02»; GPT, round 10: «Перерыв» alone left
            // open which side of the exit it was on), the header wrapped over its column like a spreadsheet's.
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("№").frame(width: Width.number, alignment: .leading)
                Text("План").frame(width: Width.planned, alignment: .trailing)
                Text("Факт").frame(width: Width.actual, alignment: .trailing)
                Text("Перерыв")
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: Width.rest, alignment: .trailing)
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
        let marks = SessionLogFormatter.observations(of: result, in: record)
        return VStack(alignment: .leading, spacing: 1) {
            columns(result, rest: rest, restOff: restOff, canJump: canJump)
            if !marks.isEmpty {
                // Under the plan and fact, past the number column: the why behind an early return.
                Text(verbatim: marks.map(HistoryText.unbroken).joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Width.number + 8)
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
        .help(help(for: result, marks: marks, canJump: canJump))
    }

    private func columns(_ result: ExitResult, rest: TimeInterval?, restOff: Bool, canJump: Bool) -> some View {
        HStack(spacing: 8) {
            // As the iPhone's log: the interrupted attempt «7 ↶» in orange with its orange time, the repeat a plain «7».
            Group {
                if result.falseStart {
                    Text(verbatim: "\(result.number) ↶").foregroundStyle(MacHistoryInk.orange)
                } else {
                    Text(verbatim: "\(result.number)").foregroundStyle(.secondary)
                }
            }
            .frame(width: Width.number, alignment: .leading)
            Text(DurationText.clock(result.plannedDuration) + (result.untilStanding ? "*" : ""))
                .foregroundStyle(.secondary)
                .frame(width: Width.planned, alignment: .trailing)
            Text(result.leftAt == nil ? "—" : DurationText.clock(result.awayDuration))
                .fontWeight(.semibold)
                .foregroundStyle(result.falseStart ? AnyShapeStyle(MacHistoryInk.orange) : AnyShapeStyle(.primary))
                .frame(width: Width.actual, alignment: .trailing)
            // The break as it was; orange where it was off its plan (the plan in the pointer's tip).
            Text(rest.map(DurationText.clock) ?? "—")
                .foregroundStyle(restOff ? AnyShapeStyle(MacHistoryInk.orange) : rest == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: Width.rest, alignment: .trailing)
            Spacer(minLength: 0)
            if canJump {
                Image(systemName: "play.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .opacity(hovered == result.id ? 1 : 0)
            }
        }
    }

    private func isLastResult(_ result: ExitResult) -> Bool { record.results.last?.id == result.id }

    private func help(for result: ExitResult, marks: [String], canJump: Bool) -> String {
        var parts = [result.attempt > 1
            ? String(localized: "Выход \(result.number), попытка \(result.attempt)")
            : String(localized: "Выход \(result.number)")]
        parts.append(SessionLogFormatter.outcome(of: result))
        if !isLastResult(result) { parts.append(String(localized: "перерыв \(DurationText.short(result.plannedBreak))")) }
        parts += marks
        if result.untilStanding { parts.append(String(localized: "* план: или до вставания")) }
        let text = parts.joined(separator: ", ")
        return canJump ? String(localized: "\(text). Нажмите, чтобы перейти к этому выходу в видео.") : text
    }
}
#endif
