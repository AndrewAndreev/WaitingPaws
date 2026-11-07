#if os(macOS)
import AppKit
import SwiftUI
import WaitingPawsCore

/// After the last exit: the numbers, plan and fact of each exit as the trainer's log (the text itself goes out with
/// «Скопировать» and «Отправить тренеру…», the main button), the video file. No chart of the same numbers, no
/// sentence about them: the table says it.
struct MacSummarySheet: View {
    @Environment(AppModel.self) private var model
    private let record: TrainingRecord
    var onClose: () -> Void

    init(record: TrainingRecord, onClose: @escaping () -> Void) {
        // DEBUG `--demo-marks`: a demo session's record with a few marks from behind the door.
        self.record = HistoryDemoMarks.shown(record)
        self.onClose = onClose
    }

    var body: some View {
        let log = SessionLogFormatter.text(for: record)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    // Two lines, as on the iPhone: what happened and when (the schedule's name is in the history).
                    Text("Тренировка завершена").font(.title3.weight(.semibold))
                    // As on the iPhone and in the history: «Ср, 4 нояб. · 22:22–22:37 · 15 мин».
                    Text(verbatim: "\(HistoryDate.day(record.startedAt)) · \(HistoryDate.time(record.startedAt))–\(HistoryDate.time(record.finishedAt)) · \(DurationText.short(max(60, (record.duration / 60).rounded() * 60)))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            // The iPhone's order: exits, the longest one, false starts — only when there were any. The words under the
            // numbers agree with them: «из 1 выхода», «1 фальстарт», «2 фальстарта».
            HStack(spacing: 0) {
                stat(String(localized: "\(record.completedExits) из \(record.plan.exits.count)"),
                     HistoryText.word(pluralText(record.plan.exits.count, ru: ("выхода", "выходов", "выходов"),
                                                 en: ("exit", "exits"))))
                if let longest = record.longestResult, longest.awayDuration > 0 {
                    Divider().frame(height: 34)
                    stat(DurationText.clock(longest.awayDuration), String(localized: "дольше всего"))
                }
                if record.falseStarts > 0 {
                    Divider().frame(height: 34)
                    stat("\(record.falseStarts)", HistoryText.word(HistoryText.falseStarts(record.falseStarts)),
                         tint: MacPalette.orange)
                }
            }
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            // The table is the log; it goes out with «Отправить тренеру…» (its sheet copies it too, as does ⇧⌘C).
            VStack(alignment: .leading, spacing: 6) {
                // A long training scrolls inside its box instead of growing the sheet past the screen.
                if record.results.count > Self.rowsShown {
                    ScrollView { logTable }
                        .frame(height: CGFloat(Self.rowsShown) * 22 + 26)
                } else {
                    logTable
                }
                notes
            }

            if let url = model.store.recordingURL(for: record) {
                HStack(spacing: 10) {
                    Image(systemName: "film").foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(fileInfo(url)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Показать в Finder") { Finder.reveal(url) }
                        .controlSize(.small)
                }
            }

            Divider()

            // What to do next is to send the log to the trainer: that is the main button (Return); closing is Esc. The
            // history is in the toolbar.
            HStack {
                Spacer()
                Button("Готово", action: onClose)
                    .keyboardShortcut(.cancelAction)
                // The prominent look is the label's own (a plain-styled button). AppKit's picker, not ShareLink: see
                // `MacShareItem` (Telegram never sent ShareLink's log and its sheet stuck).
                MacShareButton(.text(log, title: record.plan.displayTitle)) {
                    Label("Отправить тренеру…", systemImage: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(MacPalette.pinkDeep, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .help("Отправить лог тренеру · ↩")
            }
        }
        .padding(20)
        .frame(width: 600)
        .background {
            // ⇧⌘C copies the log, without a button of its own.
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log, forType: .string)
            } label: { EmptyView() }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    // MARK: Log

    /// Rows of the log table before it scrolls in a box of its own (a long training would grow the sheet past a
    /// laptop's screen).
    private static let rowsShown = 12

    /// What goes to the trainer, as the iPhone's finish card shows it: plan and fact of each attempt in columns, a
    /// repeat named as one, a false start in orange; and while anything was marked, what the owner marked from behind
    /// the door and when («легла 0:12 · замолчала 0:41»), the why behind an early return.
    private var logTable: some View {
        let marks = record.results.map { SessionLogFormatter.observations(of: $0, in: record) }
        let hasMarks = marks.contains { !$0.isEmpty }
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
            GridRow {
                Text("Выход")
                Text("План").gridColumnAlignment(.trailing)
                Text("Факт").gridColumnAlignment(.trailing)
                if hasMarks { Text("Отмечено") }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(record.results.enumerated()), id: \.element.id) { index, result in
                GridRow(alignment: .firstTextBaseline) {
                    // Without marks the numbers go to the trailing edge, as on the iPhone.
                    exitName(result)
                        .frame(maxWidth: hasMarks ? nil : .infinity, alignment: .leading)
                    Text(result.isOpen ? "—" : DurationText.clock(result.plannedDuration))
                        .foregroundStyle(.secondary)
                    Text(result.leftAt == nil ? "—" : DurationText.clock(result.awayDuration))
                        .fontWeight(.semibold)
                        .foregroundStyle(result.falseStart ? MacHistoryInk.orange : Color.primary)
                    if hasMarks {
                        Text(verbatim: marks[index].map(HistoryText.unbroken).joined(separator: " · "))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .monospacedDigit()
                .help(help(for: result))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "план 2:00 или до вставания, за дверью 2:02": what the columns leave out.
    private func help(for result: ExitResult) -> String {
        var plan = result.isOpen ? PlannedExit.openText : DurationText.clock(result.plannedDuration)
        if result.untilStanding { plan += " " + PlannedExit.untilStandingText }
        return "\(String(localized: "план \(plan)")), \(SessionLogFormatter.outcome(of: result))"
    }

    /// "Выход 7 · попытка 2 фальстарт".
    private func exitName(_ result: ExitResult) -> some View {
        HStack(spacing: 4) {
            Text("Выход \(result.number)")
            if result.attempt > 1 {
                Text("· попытка \(result.attempt)").foregroundStyle(MacHistoryInk.orange)
            }
            if result.falseStart {
                Text("фальстарт").foregroundStyle(MacHistoryInk.orange)
            }
        }
        .lineLimit(1)
    }

    /// The owner's free notes (not the marks, which stand in their exits' rows), as the log ends with them.
    @ViewBuilder
    private var notes: some View {
        let notes = record.events.filter { $0.kind == .note && $0.observed != true && !($0.detail ?? "").isEmpty }
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(notes) { note in
                    let time = MacFormat.time.string(from: note.time)
                    let when = note.exitNumber.map { String(localized: "\(time), выход \($0)") } ?? time
                    Text("\(Text(when).foregroundStyle(.secondary))  \(note.detail ?? "")")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        }
    }

    private func fileInfo(_ url: URL) -> String {
        var parts = [DurationText.clock(record.duration)]
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if model.finalizingFileNames.contains(url.lastPathComponent) { parts.append(String(localized: "готовится…")) }
        return parts.joined(separator: " · ")
    }

    private func stat(_ value: String, _ label: String, tint: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value).font(MacPalette.digits(20, weight: .semibold)).foregroundStyle(tint ?? .primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// After «Записать без тренировки»: where the file is.
struct MacClipSavedSheet: View {
    let clip: RecordingClip
    var onHistory: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "film.stack")
                    .font(.system(size: 26))
                    .foregroundStyle(MacPalette.pink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Запись сохранена").font(.title3.weight(.semibold))
                    Text(clip.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack {
                MacShareButton(.file(clip.url)) { Label("Отправить…", systemImage: "square.and.arrow.up") }
                Button("Показать в Finder") { Finder.reveal(clip.url) }
                Spacer()
                Button("История", action: onHistory)
                Button("Готово", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(MacPalette.pinkDeep)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
#endif
