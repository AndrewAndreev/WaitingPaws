#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// Every training and recording in a sortable table; the selection drives the inspector.
struct MacHistoryTable: View {
    @Environment(AppModel.self) private var model
    @Environment(MacHistoryController.self) private var controller
    let rows: [MacHistoryRow]
    /// Longest stay behind the door over the whole history (full length of the inline bars).
    let longestEver: TimeInterval

    var body: some View {
        @Bindable var controller = controller
        ScrollViewReader { scroller in
            Table(rows, selection: $controller.selection, sortOrder: $controller.sortOrder) {
                TableColumn("Дата", value: \.date) { row in
                    HStack(spacing: 6) {
                        KindIcon(isClip: row.isClip)
                        Text(MacHistoryFormat.day(row.date))
                    }
                }
                .width(min: 96, ideal: 104)

                TableColumn("Начало", value: \.startMinute) { row in
                    Text(MacFormat.time.string(from: row.date)).monospacedDigit()
                }
                .width(min: 50, ideal: 52)

                TableColumn("Тренировка", value: \.title) { row in
                    Text(row.title)
                        .foregroundStyle(row.isClip ? .secondary : .primary)
                        .help(row.title)
                }
                .width(min: 130, ideal: 196)

                TableColumn("Тренеры", value: \.trainers) { row in
                    if row.trainers.isEmpty { Dash() } else { Text(row.trainers).help(row.trainers) }
                }
                .width(min: 70, ideal: 96)

                TableColumn("Выходы", value: \.exitsDone) { row in
                    if let record = row.record {
                        Text("\(record.completedExits) из \(record.plan.exits.count)").monospacedDigit()
                    } else {
                        Dash()
                    }
                }
                .width(min: 50, ideal: 54)

                TableColumn("Фальстарты", value: \.falseStarts) { row in
                    if let record = row.record, record.falseStarts > 0 {
                        FalseStartsCell(count: record.falseStarts)
                    } else {
                        Dash()
                    }
                }
                .width(min: 76, ideal: 80)

                TableColumn("Дольше всего", value: \.longest) { row in
                    if let record = row.record {
                        LongestCell(value: record.longestStayBehindDoor, scale: longestEver)
                    } else {
                        Dash()
                    }
                }
                .width(min: 96, ideal: 106)

                TableColumn("План", value: \.planned) { row in
                    if let record = row.record {
                        Text(DurationText.clock(record.longestPlannedExit)).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Dash()
                    }
                }
                .width(min: 40, ideal: 44)

                TableColumn("Длительность", value: \.duration) { row in
                    Group {
                        if row.duration >= 0 { Text(DurationText.clock(row.duration)).monospacedDigit() } else { Dash() }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 88, ideal: 90)

                TableColumn("Видео", value: \.videoBytes) { row in
                    VideoCell(video: row.video, preparing: row.video.map { model.finalizingFileNames.contains($0.fileName) } ?? false)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 52, ideal: 56)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: HistoryRoute.self) { ids in
                if let row = ids.first.flatMap({ id in rows.first { $0.id == id } }) {
                    MacHistoryRowMenu(row: row)
                }
            } primaryAction: { ids in
                guard let row = ids.first.flatMap({ id in rows.first { $0.id == id } }) else { return }
                if row.video != nil { controller.play(row) } else { controller.showsInspector = true }
            }
            .onKeyPress(.space) {
                guard let row = controller.row(controller.selection, model: model), row.video != nil else { return .ignored }
                controller.togglePlayback(row)
                return .handled
            }
            .onDeleteCommand {
                if let row = controller.row(controller.selection, model: model) { controller.confirmDelete(row) }
            }
            .copyable(selectedLogs)
            .onChange(of: controller.scrollRequest) {
                if let id = controller.selection { withAnimation { scroller.scrollTo(id, anchor: .center) } }
            }
        }
    }

    /// ⌘C on a training copies its log.
    private var selectedLogs: [String] {
        controller.row(controller.selection, model: model)?.logText.map { [$0] } ?? []
    }
}

/// Context menu of a row (also used by the toolbar's «…» where it makes sense).
struct MacHistoryRowMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(MacHistoryController.self) private var controller
    let row: MacHistoryRow

    var body: some View {
        Button("Воспроизвести", systemImage: "play") { controller.play(row) }
            .disabled(row.video == nil)
        Button(row.video == nil ? "Показать лог в Finder" : "Показать в Finder", systemImage: "folder") {
            controller.revealInFinder(row, model: model)
        }
        if let video = row.video {
            Button("Сохранить в Фото", systemImage: "photo.badge.plus") { model.saveToPhotos(video.url) }
            ShareLink(item: video.url) { Label("Отправить видео…", systemImage: "film") }
                .disabled(model.finalizingFileNames.contains(video.fileName))
        }
        if let record = row.record, let log = row.logText {
            Divider()
            Button("Скопировать лог", systemImage: "doc.on.doc") { controller.copyLog(of: row) }
            ShareLink(item: log, subject: Text(record.plan.title), preview: SharePreview(record.plan.title)) {
                Label("Отправить лог…", systemImage: "square.and.arrow.up")
            }
        }
        Divider()
        MacHistoryDeleteItems(row: row)
    }
}

// MARK: - Cells

/// Paw for a training, film for a recording without one.
private struct KindIcon: View {
    let isClip: Bool
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: isClip ? "film" : "pawprint.fill")
            .font(.system(size: 10.5))
            .foregroundStyle(isClip || prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(MacPalette.accent))
            .frame(width: 14)
            .help(isClip ? "Запись без тренировки" : "Тренировка")
    }
}

private struct Dash: View {
    var body: some View { Text("—").foregroundStyle(.tertiary) }
}

private struct FalseStartsCell: View {
    let count: Int
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Label("\(count)", systemImage: "arrow.uturn.backward")
            .labelStyle(.titleAndIcon)
            .monospacedDigit()
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(MacHistoryInk.orange))
    }
}

/// "2:32 ▬▬▬▬▬───" — the bar is relative to the longest stay ever.
private struct LongestCell: View {
    let value: TimeInterval
    let scale: TimeInterval
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 8) {
            Text(DurationText.clock(value))
                .monospacedDigit()
                .frame(minWidth: 34, alignment: .trailing)
            ThinProgress(value: scale > 0 ? value / scale : 0,
                         tint: prominence == .increased ? .white.opacity(0.9) : MacPalette.accent,
                         height: 5)
        }
    }
}

private struct VideoCell: View {
    let video: MacHistoryVideo?
    let preparing: Bool

    var body: some View {
        if let video {
            if preparing {
                MacHistoryDelayed { ProgressView().controlSize(.mini) }
                    .help("Готовим видео…")
            } else {
                Text(MacHistoryFormat.bytes(video.bytes)).monospacedDigit()
            }
        } else {
            Dash()
                .help("Видео нет")
                .accessibilityLabel("Без видео")
        }
    }
}
#endif
