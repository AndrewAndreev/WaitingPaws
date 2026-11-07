import SwiftUI
import AVKit
import Charts
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
    /// Swiped or long-pressed for deletion (or several rows deleted at once): asked first, as on the entry's own screen.
    @State private var pendingDelete: [Item] = []
    @State private var path: [HistoryRoute] = []
    /// Rows ticked in edit mode, deleted together from the bottom bar.
    @State private var selection: Set<HistoryRoute> = []
    /// The progress card folded into its two figures (GPT, round 6), by default (design council, round 12): the list
    /// starts on the first screen, and «Прогресс» opens the chart. Kept.
    @AppStorage("historyProgressCollapsed") private var progressCollapsed = true
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    private var isEditing: Bool {
        #if os(iOS)
        editMode.isEditing
        #else
        false
        #endif
    }

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

        var record: TrainingRecord? {
            if case .session(let record) = self { return record }
            return nil
        }

        var clip: RecordingClip? {
            if case .clip(let clip) = self { return clip }
            return nil
        }
    }

    private var items: [Item] {
        (model.history.map(Item.session) + model.clips.map(Item.clip)).sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                let items = items
                if items.isEmpty {
                    ContentUnavailableView("Пока нет тренировок", systemImage: "pawprint",
                                           description: Text("После первой тренировки здесь появятся лог и видео."))
                } else {
                    // Ticking rows only in edit mode: otherwise a tap opens the training.
                    List(selection: isEditing ? $selection : nil) {
                        // Progress before the archive, as in the Mac window: is the dog staying out longer, against what plan.
                        // A single training would only repeat its own row. Edit mode is for picking rows: the card steps
                        // aside, or a small iPhone would show nothing but the card and the bar.
                        if model.history.count > 1 && !isEditing {
                            // One card (design council, round 13: a header row «Прогресс ›» over a card of its own was
                            // two surfaces for one block): folded, its two figures and ›; a tap on them opens the chart
                            // under them, and folds it again. A tap on a training's point opens it, as its row below
                            // does (Fable, round 9).
                            Section {
                                HistoryProgressCard(records: model.history, isExpanded: !progressCollapsed,
                                                    onToggle: { setProgressCollapsed(!progressCollapsed) }) { record in
                                    path.append(.session(record.id))
                                }
                            }
                        }
                        Section {
                            ForEach(items) { item in
                                NavigationLink(value: item.id) {
                                    switch item {
                                    case .session(let record):
                                        HistoryRow(record: record,
                                                   recording: RecordingReport(record: HistoryDemoMarks.listed(record, in: model.history),
                                                                              model: model))
                                    case .clip(let clip):
                                        ClipRow(clip: clip)
                                    }
                                }
                                #if os(iOS)
                                // In edit mode a tap ticks the row instead of opening it, so no chevron (as in Mail).
                                .navigationLinkIndicatorVisibility(isEditing ? .hidden : .automatic)
                                #endif
                                .contextMenu {
                                    Button(item.isClip ? "Удалить запись…" : "Удалить тренировку…", systemImage: "trash", role: .destructive) {
                                        pendingDelete = [item]
                                    }
                                }
                                // Edit mode ticks rows for the bottom bar instead of a ⊖ on each.
                                .deleteDisabled(isEditing)
                            }
                            .onDelete { offsets in
                                pendingDelete = offsets.map { items[$0] }
                            }
                        }
                    }
                    #if os(macOS)
                    .listStyle(.inset)
                    #else
                    .modifier(EditBarModifier(isOn: isEditing) { editBarButtons })
                    #endif
                }
            }
            .navigationTitle("История")
            .navigationDestination(for: HistoryRoute.self) { route in
                switch route {
                case .session(let id):
                    if let record = model.history.first(where: { $0.id == id }) {
                        HistoryDetailView(record: HistoryDemoMarks.recorded(record))
                    }
                case .clip(let id):
                    if let clip = model.clips.first(where: { $0.id == id }) {
                        ClipDetailView(clip: clip)
                    }
                }
            }
            .toolbar { toolbar }
            #if os(iOS)
            // The EditButton in the bar and the list read the same edit mode.
            .environment(\.editMode, $editMode)
            #endif
            .confirmationDialog("Удалить всю историю?", isPresented: $confirmClearAll, titleVisibility: .visible) {
                Button("Удалить тренировки (\(model.history.count)) и записи (\(model.clips.count))", role: .destructive) {
                    model.deleteAll()
                    finishEditing()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Логи и видео будут удалены с устройства. Копии в Фото останутся.")
            }
            .confirmationDialog(deleteTitle,
                                isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
                                titleVisibility: .visible, presenting: pendingDelete.isEmpty ? nil : pendingDelete) { items in
                deleteButtons(items)
            } message: { items in
                if items.contains(where: \.isClip) {
                    if items.count == 1 { Text("Копия в Фото останется.") } else { Text("Копии в Фото останутся.") }
                }
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
            #if os(iOS)
            // `--demo-history-select N`: edit mode with the N newest rows ticked (0: none, the bottom bar's «Удалить всё»).
            if let index = arguments.firstIndex(of: "--demo-history-select"),
               let count = arguments.dropFirst(index + 1).first.flatMap({ Int($0) }) {
                editMode = .active
                selection = Set(items.prefix(count).map(\.id))
            }
            #endif
            #endif
        }
    }

    /// As in Apple's own lists: the sheet closes at the leading edge, the list is edited from the trailing one
    /// (swipe and long press delete a single row without it). In edit mode the close button gives way, and the
    /// bottom bar deletes the ticked rows, or everything while none is ticked (as Mail's «Удалить все»).
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        if !isEditing {
            ToolbarItem(placement: .cancellationAction) {
                if #available(iOS 26.0, *) {
                    Button(role: .close) { dismiss() }
                } else {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if isEditing {
                // «Готово» in words where «Править» stood, as Mail says it, not iOS 26's tinted ✓ circle.
                Button("Готово") { finishEditing() }
                    .fontWeight(.semibold)
            } else {
                EditButton().disabled(items.isEmpty)
            }
        }
        if isEditing && !editBarIsGlass {
            ToolbarItemGroup(placement: .bottomBar) { editBarButtons }
        }
        #else
        ToolbarItem(placement: .cancellationAction) {
            Button("Закрыть") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Показать папку в Finder", systemImage: "folder") { Finder.reveal(model.store.rootDirectory) }
                Button("Удалить всё", systemImage: "trash", role: .destructive) { confirmClearAll = true }
                    .disabled(model.history.isEmpty && model.clips.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Ещё")
        }
        #endif
    }

    #if os(iOS)
    /// Mail's edit bar: «Выбрать все» at the leading edge, at the trailing one the deletion with the count of what it
    /// will delete, or «Удалить всё» while nothing is ticked.
    @ViewBuilder
    private var editBarButtons: some View {
        let allSelected = !items.isEmpty && selection.count == items.count
        Button(allSelected ? "Снять выбор" : "Выбрать все") {
            selection = allSelected ? [] : Set(items.map(\.id))
        }
        Spacer()
        Group {
            if selection.isEmpty {
                Button("Удалить всё", role: .destructive) { confirmClearAll = true }
            } else {
                Button("Удалить (\(selection.count))", role: .destructive) {
                    pendingDelete = items.filter { selection.contains($0.id) }
                }
                .contentTransition(.numericText())
            }
        }
        .tint(Theme.danger)
        .foregroundStyle(Theme.danger)
    }
    #endif

    private func setProgressCollapsed(_ collapsed: Bool) {
        withAnimation(.snappy(duration: 0.3)) { progressCollapsed = collapsed }
    }

    /// Back from edit mode once its deletion is done (or there is nothing left to edit).
    private func finishEditing() {
        selection = []
        #if os(iOS)
        withAnimation { editMode = .inactive }
        #endif
    }

    /// «Удалить тренировку?», «Удалить 2 тренировки и 1 запись?».
    private var deleteTitle: String {
        let trainings = pendingDelete.filter { !$0.isClip }.count
        let clips = pendingDelete.count - trainings
        if pendingDelete.count == 1 { return clips == 1 ? String(localized: "Удалить запись?") : String(localized: "Удалить тренировку?") }
        // Accusative: «Удалить 2 тренировки».
        let trainingsText = pluralText(trainings, ru: ("тренировку", "тренировки", "тренировок"), en: ("training", "trainings"))
        let clipsText = pluralText(clips, ru: ("запись", "записи", "записей"), en: ("recording", "recordings"))
        switch (trainings, clips) {
        case (_, 0): return String(localized: "Удалить \(trainingsText)?")
        case (0, _): return String(localized: "Удалить \(clipsText)?")
        default: return String(localized: "Удалить \(trainingsText) и \(clipsText)?")
        }
    }

    @ViewBuilder
    private func deleteButtons(_ items: [Item]) -> some View {
        let records = items.compactMap(\.record)
        let clips = items.compactMap(\.clip)
        if records.isEmpty {
            Button("Удалить", role: .destructive) {
                for clip in clips { model.delete(clip) }
                finishEditing()
            }
        } else {
            Button("Удалить вместе с видео", role: .destructive) {
                for record in records { model.delete(record, includingRecording: true) }
                for clip in clips { model.delete(clip) }
                finishEditing()
            }
            // Not with recordings among them: those are videos themselves.
            if clips.isEmpty, records.contains(where: { model.store.recordingURL(for: $0) != nil }) {
                Button(records.count == 1 ? "Удалить только лог, видео оставить" : "Удалить только логи, видео оставить") {
                    for record in records { model.delete(record, includingRecording: false) }
                    finishEditing()
                }
            }
        }
        Button("Отмена", role: .cancel) {}
    }
}

/// Dates of the history in the app's language.
enum HistoryDate {
    /// "4 окт., 13:25" / "Oct 4, 1:25 PM"; the year is added for older entries.
    static func string(from date: Date) -> String {
        (isThisYear(date) ? thisYear : otherYear).string(from: date)
    }

    /// "Пт, 2 окт." / "Fri, Oct 2" (with the year for older entries).
    static func day(_ date: Date) -> String {
        let text = (isThisYear(date) ? weekdayDay : weekdayDayYear).string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// "2 окт." / "Oct 2".
    static func dayMonth(_ date: Date) -> String { dayMonthOnly.string(from: date) }

    /// "18:36" / "6:36 PM".
    static func time(_ date: Date) -> String { timeOnly.string(from: date) }

    /// "6 сент. – 2 окт." / "Sep 6 – Oct 2", "6–27 сент.", one day alone; with the years outside this one.
    static func range(_ from: Date, _ to: Date) -> String {
        ([from, to].allSatisfy(isThisYear) ? rangeThisYear : rangeOtherYear).string(from: from, to: to)
    }

    private static func isThisYear(_ date: Date) -> Bool {
        Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
    }

    private static let thisYear = CoreLanguage.current.dateFormatter("dMMMjmm")
    private static let otherYear = CoreLanguage.current.dateFormatter("dMMMyyyyjmm")
    private static let weekdayDay = CoreLanguage.current.dateFormatter("EEdMMM")
    private static let weekdayDayYear = CoreLanguage.current.dateFormatter("EEdMMMyyyy")
    private static let dayMonthOnly = CoreLanguage.current.dateFormatter("dMMM")
    private static let timeOnly = CoreLanguage.current.dateFormatter("jmm")
    private static let rangeThisYear = rangeFormatter("dMMM")
    private static let rangeOtherYear = rangeFormatter("dMMMy")

    private static func rangeFormatter(_ template: String) -> DateIntervalFormatter {
        let formatter = DateIntervalFormatter()
        formatter.locale = CoreLanguage.current.locale
        formatter.dateTemplate = template
        return formatter
    }
}

/// Wording shared by the iPhone list and the Mac history window.
enum HistoryText {
    /// "1 фальстарт", "3 фальстарта" / "1 false start", "3 false starts".
    static func falseStarts(_ count: Int) -> String {
        pluralText(count, ru: ("фальстарт", "фальстарта", "фальстартов"), en: ("false start", "false starts"))
    }

    /// "7 из 7 выходов", "1 из 1 выхода" / "7 of 7 exits".
    static func exits(_ record: TrainingRecord) -> String {
        // Genitive after «из»: «из 1 выхода», «из 5 выходов».
        let planned = pluralText(record.plan.exits.count, ru: ("выхода", "выходов", "выходов"), en: ("exit", "exits"))
        return String(localized: "\(record.completedExits) из \(planned)")
    }

    /// "2:32", or a dash while no exit has been completed.
    static func longest(_ record: TrainingRecord) -> String {
        record.longestStayBehindDoor > 0 ? DurationText.clock(record.longestStayBehindDoor) : "—"
    }

    /// The plan of the longest exit itself, for «2:32 · план 2:30»: "2:30", "без времени" for an extra exit, nil
    /// while no exit has been completed. Not the schedule's longest exit, which may be another one.
    static func longestPlan(_ record: TrainingRecord) -> String? {
        guard let result = record.longestResult, result.awayDuration > 0 else { return nil }
        return result.isOpen ? PlannedExit.openText : DurationText.clock(result.plannedDuration)
    }

    /// "25 мин": the length of a whole training, in whole minutes.
    static func length(_ record: TrainingRecord) -> String {
        DurationText.short(record.duration >= 60 ? (record.duration / 60).rounded() * 60 : record.duration)
    }

    /// The word of a counted phrase, for a label under its number: "выходов" of "7 выходов".
    static func word(_ counted: String) -> String {
        String(counted.drop { $0 != " " }.dropFirst())
    }

    /// With no-break spaces: «замолчала на 1:54» as one word, so a wrapping list of marks never splits a mark.
    static func unbroken(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// "со второй попытки" / "on the 2nd attempt" for an exit done on its `attempt`-th try; nil for the first one.
    static func fromAttempt(_ attempt: Int) -> String? {
        switch attempt {
        case ..<2: return nil
        case 2: return String(localized: "со второй попытки")
        case 3: return String(localized: "с третьей попытки")
        case 4: return String(localized: "с четвёртой попытки")
        default: return String(localized: "с \(attempt)-й попытки")
        }
    }
}

/// The sample trainings (`DemoData.history()`, a demo session's record) carry no marks from behind the door; in DEBUG
/// with `--demo-history`, `--demo-history-videos` or `--demo-marks` a few are added where an owner would have
/// tapped them, so screenshots of the training's screen, the Mac inspector and the Mac summary show them. In memory
/// only, like the samples themselves; a record that already has marks is left as it is.
enum HistoryDemoMarks {
    /// The record as the history and the summary show it: itself, outside these DEBUG launches.
    static func shown(_ record: TrainingRecord) -> TrainingRecord {
        #if DEBUG
        let arguments = CommandLine.arguments
        let recorded = withDemoRecording(record)
        guard ["--demo-history", "--demo-history-videos", "--demo-marks"].contains(where: { arguments.contains($0) }),
              !recorded.events.contains(where: { $0.observed == true }) else { return recorded }
        let english = CoreLanguage.current == .en
        let lay = english ? "lay down" : "легла"
        let bark = english ? "barked" : "залаяла"
        let quiet = english ? "went quiet" : "замолчала"
        var record = recorded
        let longest = record.longestResult?.id
        for result in record.results {
            guard let left = result.leftAt else { continue }
            let away = result.awayDuration
            var marks: [(String, TimeInterval)] = []
            if result.falseStart, away >= 10 {
                // What sent the owner back early.
                marks = [(bark, (away * 0.7).rounded())]
            } else if result.id == longest, away >= 60 {
                // Lay down, barked late on, then the quiet the rule waits for before coming in.
                let barked = (away * 0.7).rounded()
                marks = [(lay, 15), (bark, barked), (quiet, barked + 8)]
            } else if away >= 85 {
                marks = [(lay, TimeInterval(10 + (result.number * 7) % 9))]
            }
            for (text, offset) in marks {
                let event = SessionEvent(time: left.addingTimeInterval(offset), kind: .note, exitNumber: result.number,
                                         attempt: result.attempt, detail: text, observed: true)
                let index = record.events.lastIndex { $0.time <= event.time }.map { $0 + 1 } ?? 0
                record.events.insert(event, at: index)
            }
        }
        return record
        #else
        return record
        #endif
    }

    /// The record as the iPhone's training screen shows it: itself, outside DEBUG launches; with a demo recording as
    /// `--demo-recording-*` say, and no marks from behind the door (the owner no longer marks them).
    static func recorded(_ record: TrainingRecord) -> TrainingRecord {
        #if DEBUG
        return withDemoRecording(record)
        #else
        return record
        #endif
    }

    /// The record as its row in the history list shows it: itself, outside DEBUG launches. With
    /// `--demo-history-recordings` the newest training was recorded in two parts (as `--demo-recording-gap`), the one
    /// before it throughout, the third led on the Mac (its video there), the others not at all — every sign of the
    /// row in one shot; else as `--demo-recording-*` say.
    static func listed(_ record: TrainingRecord, in history: [TrainingRecord]) -> TrainingRecord {
        #if DEBUG
        guard CommandLine.arguments.contains("--demo-history-recordings") else { return withDemoRecording(record) }
        let newest = history.sorted { $0.startedAt > $1.startedAt }
        switch newest.firstIndex(where: { $0.id == record.id }) {
        case 0: return withDemoRecording(record, as: .gap)
        case 1: return withDemoRecording(record, as: .whole)
        case 2: return withDemoRecording(record, as: .elsewhere)
        default: return record
        }
        #else
        return record
        #endif
    }

    #if DEBUG
    private enum DemoRecording {
        case whole, gap, elsewhere
    }

    /// `--demo-recording-whole`: the sample training recorded throughout into `demo-2.mp4`; `--demo-recording-gap`:
    /// the recording broke off for 2:10 after the fourth exit (the app left in the background), its first part
    /// `demo-1.mp4`, the rest `demo-2.mp4`. The files are put into Recordings for the shot (`RecordingReport`;
    /// `Design/council/capture.sh` does it). `kind` given: that one, whatever the arguments; `.elsewhere` is a
    /// training led from the iPhone on the Mac, which recorded it: its marks name a file this iPhone hasn't got.
    private static func withDemoRecording(_ record: TrainingRecord, as forced: DemoRecording? = nil) -> TrainingRecord {
        let arguments = CommandLine.arguments
        let kind = forced ?? (arguments.contains("--demo-recording-whole") ? .whole
            : arguments.contains("--demo-recording-gap") ? .gap : nil)
        guard let kind, record.results.count > 4,
              !record.events.contains(where: { $0.kind == .recordingStarted }) else { return record }
        var record = record
        let first = switch kind {
        case .whole: "demo-2.mp4"
        case .gap: "demo-1.mp4"
        case .elsewhere: "demo-mac.mp4"
        }
        var marks: [(Date, SessionEventKind, String?)] = [(record.startedAt.addingTimeInterval(4), .recordingStarted, first)]
        if kind == .gap {
            let cut = record.results[3].endedAt.addingTimeInterval(25)
            marks += [(cut, .recordingStopped, nil), (cut.addingTimeInterval(130), .recordingStarted, "demo-2.mp4")]
        }
        marks.append((record.finishedAt.addingTimeInterval(-1), .recordingStopped, nil))
        for (time, mark, file) in marks {
            let index = record.events.lastIndex { $0.time <= time }.map { $0 + 1 } ?? 0
            record.events.insert(SessionEvent(time: time, kind: mark, detail: file), at: index)
        }
        record.recordingFileName = kind == .elsewhere ? nil : "demo-2.mp4"
        return record
    }
    #endif
}

/// What became of a training's video, said in the history (iPhone and the Mac inspector) instead of left to be guessed
/// (design council, round 9: GPT): no recording; the video on the Mac that recorded it; none came of it; deleted; the
/// recording ran through the whole training; or only part of it is in this video, and why — from the record's own
/// «Запись включена / остановлена» events: a late start, an early stop, a break in it (the app left in the background
/// too long, or the recording stopped and started again; the record doesn't keep which). A new start writes a new file,
/// so a part before a break is a recording of its own in the history: `earlierParts` lead to it. Frames the camera
/// didn't send while the recording went on are in no record: «шла всю тренировку» says the recording was on, not that
/// every second is in it.
@MainActor
struct RecordingReport {
    /// A stretch the recording was on: from its «Запись включена» (or the training's start, when it was on before it)
    /// to its «Запись остановлена» (or the training's end), and the file it went to.
    struct Span: Equatable {
        var start: Date
        var end: Date
        var file: String?
    }

    enum Kind: Equatable {
        case none, elsewhere, empty, deleted, whole, partial
    }

    /// An earlier part of the recording that is a recording of its own in the history, with the exits in it.
    struct Part: Identifiable {
        let clip: RecordingClip
        let start: Date
        /// Where the recording stopped for this part (the next part starts after the break).
        var end: Date
        let exits: [Int]
        var id: String { clip.id }

        /// «Выходы 1–4 — в записи 18:36», «Начало — в записи 18:36» when no exit is in it.
        var title: String {
            let time = HistoryDate.time(start)
            guard let list = RecordingReport.exitList(exits, capitalized: true) else {
                return String(localized: "Начало — в записи \(time)")
            }
            return String(localized: "\(list) — в записи \(time)")
        }
    }

    let kind: Kind
    /// The line: «Запись не включали», «Запись шла всю тренировку», «Запись прерывалась в 18:44 на 2:10».
    let text: String
    /// For a part only: «В этом видео — выходы 5–7».
    let detail: String?
    let systemImage: String
    let earlierParts: [Part]
    /// The exits in the training's own video (none without one).
    let videoExits: [Int]
    /// When the training's own video started (nil without one): the end of the break before it.
    let videoStart: Date?

    /// `hasVideo`: whether the training's video is there to watch, when the caller knows it otherwise (the Mac's demo
    /// videos live in a folder of their own); else the store says.
    init(record: TrainingRecord, model: AppModel, hasVideo: Bool? = nil) {
        let hasVideo = hasVideo ?? (model.store.recordingURL(for: record) != nil)
        let videoName = hasVideo ? record.recordingFileName : nil
        let spans = Self.spans(of: record)
        // The file of a part as it is on disk (a recording of its own in the history, unless it was deleted).
        earlierParts = spans.compactMap { span in
            guard let file = span.file, file != record.recordingFileName, file.lowercased().hasSuffix(".mp4"),
                  !file.contains("/"), !file.contains("\\") else { return nil }
            let url = model.store.recordingsDirectory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let clip = model.clips.first { $0.id == file } ?? RecordingClip(url: url, date: span.start)
            return Part(clip: clip, start: span.start, end: span.end, exits: Self.exits(of: record, in: span))
        }
        if videoName == nil {
            detail = nil
            videoExits = []
            videoStart = nil
            if record.recordingFileName != nil {
                (kind, text, systemImage) = (.deleted, String(localized: "Файл видео удалён"), "video.slash")
            } else if spans.isEmpty {
                (kind, text, systemImage) = (.none, String(localized: "Запись не включали"), "video.slash")
            } else if Self.recordedElsewhere(spans, earlierParts: earlierParts) {
                // A training led from this iPhone on the Mac: the Mac recorded it, the iPhone keeps the log only.
                (kind, text, systemImage) = (.elsewhere, String(localized: "Видео — в истории на \(model.linkedHostKind)"),
                                             "laptopcomputer")
            } else {
                (kind, text, systemImage) = (.empty, String(localized: "Видео не записалось"), "video.slash")
            }
            return
        }
        let video = spans.last { $0.file == record.recordingFileName } ?? spans.last
            ?? Span(start: record.startedAt, end: record.finishedAt, file: record.recordingFileName)
        let first = record.results.first, last = record.results.last
        // The first exit counts from going out of the door, give or take the seconds a recording turned on with the
        // training takes to begin (its «Запись включена» is written when it does).
        let late = first.map { video.start > ($0.leftAt ?? $0.endedAt).addingTimeInterval(15) } ?? false
        let early = last.map { video.end < $0.endedAt.addingTimeInterval(-1) } ?? false
        systemImage = "film"
        videoExits = Self.exits(of: record, in: video)
        videoStart = video.start
        guard spans.count > 1 || late || early else {
            (kind, text, detail) = (.whole, String(localized: "Запись шла всю тренировку"), nil)
            return
        }
        kind = .partial
        let time = HistoryDate.time
        if spans.count > 1 {
            let gaps = zip(spans, spans.dropFirst()).map { ($0.end, $1.start.timeIntervalSince($0.end)) }
            let total = DurationText.clock(gaps.reduce(0) { $0 + max(0, $1.1) })
            text = gaps.count == 1
                ? String(localized: "Запись прерывалась в \(time(gaps[0].0)) на \(total)")
                : String(localized: "Запись прерывалась \(pluralText(gaps.count, ru: ("раз", "раза", "раз"), en: ("time", "times"))), всего на \(total)")
        } else if late && early {
            text = String(localized: "Запись шла \(time(video.start))–\(time(video.end))")
        } else if late {
            text = String(localized: "Запись началась в \(time(video.start))")
        } else {
            text = String(localized: "Запись остановлена в \(time(video.end))")
        }
        detail = Self.exitList(videoExits, capitalized: false).map { String(localized: "В этом видео — \($0)") }
            ?? String(localized: "В этом видео выходов нет")
    }

    /// The recording's stretches in the training, oldest first.
    nonisolated static func spans(of record: TrainingRecord) -> [Span] {
        let marks = record.events.filter { $0.kind == .recordingStarted || $0.kind == .recordingStopped }
        let started = marks.contains { $0.kind == .recordingStarted }
        // On before the training began (a recording without one, then a training started): no «включена» of its own.
        var open: Span? = marks.first?.kind == .recordingStopped || (marks.isEmpty && record.recordingFileName != nil)
            ? Span(start: record.startedAt, end: record.finishedAt, file: started ? nil : record.recordingFileName) : nil
        var spans: [Span] = []
        for mark in marks {
            if mark.kind == .recordingStarted {
                if var span = open {
                    span.end = mark.time
                    spans.append(span)
                }
                open = Span(start: mark.time, end: record.finishedAt, file: mark.detail)
            } else if var span = open {
                span.end = mark.time
                spans.append(span)
                open = nil
            }
        }
        if let open { spans.append(open) }
        return spans
    }

    /// No file here, none of the parts a recording of its own here, and it was on for a while: the Mac (or the PC) the
    /// training was led on recorded it — not a recording stopped right away, whose empty file was dropped.
    private nonisolated static func recordedElsewhere(_ spans: [Span], earlierParts: [Part]) -> Bool {
        #if os(iOS)
        earlierParts.isEmpty && spans.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } >= 10
        #else
        false
        #endif
    }

    /// The exits (numbers, each once) whose time behind the door overlaps the span.
    nonisolated static func exits(of record: TrainingRecord, in span: Span) -> [Int] {
        var numbers: [Int] = []
        for result in record.results {
            let from = result.leftAt ?? result.startedAt
            guard min(result.endedAt, span.end) > max(from, span.start), !numbers.contains(result.number) else { continue }
            numbers.append(result.number)
        }
        return numbers
    }

    /// «выход 5», «выходы 5–7», «выходы 1–3 и 6» (capitalized: «Выходы 1–4»); nil for none.
    nonisolated static func exitList(_ numbers: [Int], capitalized: Bool) -> String? {
        guard !numbers.isEmpty else { return nil }
        var runs: [String] = []
        var index = 0
        let sorted = numbers.sorted()
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
            runs.append(end > index ? "\(sorted[index])–\(sorted[end])" : "\(sorted[index])")
            index = end + 1
        }
        let formatter = ListFormatter()
        formatter.locale = CoreLanguage.current.locale
        let list = formatter.string(from: runs) ?? runs.joined(separator: ", ")
        let single = sorted.count == 1
        switch (single, capitalized) {
        case (true, false): return String(localized: "выход \(list)")
        case (true, true): return String(localized: "Выход \(list)")
        case (false, false): return String(localized: "выходы \(list)")
        case (false, true): return String(localized: "Выходы \(list)")
        }
    }
}

#if os(iOS)
/// iOS 26 draws edit mode's bar itself (`EditBarModifier`); before it the system's bottom bar is already full-width.
private var editBarIsGlass: Bool {
    if #available(iOS 26.0, *) { true } else { false }
}

/// Edit mode's bar from iOS 26 on: one glass bar across the screen, as the tab bar of Apple's apps, with the actions at
/// its two ends; the list scrolls under it with the system's soft edge instead of being cut by a line. iOS 26's own
/// `.bottomBar` would float each button as a capsule of its own over the rows.
private struct EditBarModifier<Buttons: View>: ViewModifier {
    let isOn: Bool
    @ViewBuilder let buttons: Buttons

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .bottom) {
                if isOn {
                    HStack(spacing: 16) { buttons }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 22)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        } else {
            content
        }
    }
}

/// From iOS 26: the title bar covers what scrolls under it instead of blurring it, so no rows show through under the
/// title and its buttons (a training's figures under its date; the plan's rows under its name, GPT, round 14).
struct HardTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}
#endif

/// One line where it fits: the day, ▶ when the training has a video, its length, and only what went off the plan — «5 из
/// 7 выходов» when not all were done, the false starts «↶ 1» in the colour of their marks on the chart; the longest exit on
/// the right. No start time and no «план 2:30» under the figure (design council, round 13: six facts a row, the plan of
/// each in the training's own table). The plan's title («Тренировка на пятницу») mostly repeats the weekday, so it
/// stays on the training's own screen.
private struct HistoryRow: View {
    let record: TrainingRecord
    /// What became of its video: whether the sign after the day is there.
    let recording: RecordingReport

    var body: some View {
        HStack(spacing: 12) {
            // The date never truncates; where the line doesn't fit (a narrow iPhone, edit mode's ticks, large text) the
            // rest goes under it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    day
                    details
                }
                .lineLimit(1)
                VStack(alignment: .leading, spacing: 3) {
                    day.lineLimit(1)
                    details.lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(HistoryText.longest(record))
                .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                .accessibilityLabel(String(localized: "самый длинный выход \(HistoryText.longest(record)), план \(HistoryText.longestPlan(record) ?? "—")"))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        // What became of the video, in the training screen's words, on every row: the sign is only on those with one.
        .accessibilityValue(recording.text)
    }

    /// «Пт, 2 окт. ▶»: one sign for a training that has a video (Fable, round 9; Opus, round 10: the exception is what
    /// is marked, as Photos marks its videos). Whether it is in parts or on the Mac, the training's screen says (design
    /// council, round 12: three signs for it were three things to learn).
    private var day: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(HistoryDate.day(record.startedAt)).font(.headline)
            if hasVideo {
                Image(systemName: "play.rectangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize()
    }

    /// «28 мин», «28 мин · 5 из 7 выходов · ↶ 1»: the false starts as the log and the strip's chip mark them, orange, with
    /// their count (design council, round 14: «1 фальстарт» here, «↶ 1» on the Mac).
    private var details: some View {
        var text = Text(verbatim: HistoryText.length(record))
        var spoken = [HistoryText.length(record)]
        if record.completedExits < record.plan.exits.count {
            text = Text("\(text) · \(Text(HistoryText.exits(record)))")
            spoken.append(HistoryText.exits(record))
        }
        if record.falseStarts > 0 {
            let sign = Text("\(Text(Image(systemName: "arrow.uturn.backward"))) \(Text(verbatim: "\(record.falseStarts)"))")
            text = Text("\(text) · \(sign.foregroundStyle(Theme.warning))")
            spoken.append(HistoryText.falseStarts(record.falseStarts))
        }
        return text
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .accessibilityLabel(spoken.joined(separator: ", "))
    }

    /// A video of the training, here or on the Mac that recorded it; not for the log alone.
    private var hasVideo: Bool {
        switch recording.kind {
        case .whole, .partial, .elsewhere: true
        case .none, .empty, .deleted: false
        }
    }
}

private struct ClipRow: View {
    let clip: RecordingClip
    @State private var duration: TimeInterval?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(HistoryDate.day(clip.date)).font(.headline)
                    Text(HistoryDate.time(clip.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .lineLimit(1)
                Text("Запись без тренировки")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "film").foregroundStyle(.secondary)
            Text(duration.map { DurationText.clock($0) } ?? " ")
                .font(.system(.subheadline, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .task(id: clip.id) { duration = await clip.loadDuration() }
    }
}

// MARK: - Progress

/// Range of the progress chart and of the numbers next to it: a menu on Mac, a segmented control on iPhone, the
/// same three periods on both. The one picked last is kept (`storageKey`); until then `compact(for:)` picks.
enum HistoryPeriod: String, CaseIterable, Identifiable {
    case fourWeeks, threeMonths, all

    /// UserDefaults key of the picked period (`@AppStorage` on iPhone, `saved` on Mac).
    static let storageKey = "historyPeriod"

    /// The period picked last, nil while none was picked.
    static var saved: HistoryPeriod? {
        get { UserDefaults.standard.string(forKey: storageKey).flatMap(HistoryPeriod.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: storageKey) }
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .fourWeeks: String(localized: "4 недели")
        case .threeMonths: String(localized: "3 месяца")
        case .all: String(localized: "Всё время")
        }
    }

    /// Title of the change figure when the period starts after the first training.
    var gainTitle: String {
        switch self {
        case .fourWeeks: String(localized: "За четыре недели")
        case .threeMonths: String(localized: "За три месяца")
        case .all: String(localized: "С первой тренировки")
        }
    }

    var days: Int? {
        switch self {
        case .fourWeeks: 28
        case .threeMonths: 91
        case .all: nil
        }
    }

    /// Until a period is picked: the whole history while it fits in four weeks (a new dog's few trainings
    /// fill the chart instead of huddling at its right edge), the last four weeks once they hold a trend of their own.
    static func compact(for records: [TrainingRecord]) -> HistoryPeriod {
        let recent = HistoryProgress(records: records, period: .fourWeeks)
        return recent.includesFirstTraining || recent.sessions.count < 3 ? .all : .fourWeeks
    }
}

/// Numbers behind the progress chart: trainings of the period (oldest first) and the longest exit of all time.
struct HistoryProgress {
    let period: HistoryPeriod
    let sessions: [TrainingRecord]
    /// The training with the longest exit ever, whatever the period (none until the dog has stayed out at all).
    let longestEver: TrainingRecord?
    let domain: ClosedRange<Date>
    let includesFirstTraining: Bool

    init(records: [TrainingRecord], period: HistoryPeriod) {
        self.period = period
        let all = records.sorted { $0.startedAt < $1.startedAt }
        longestEver = all.filter { $0.longestStayBehindDoor > 0 }.max { $0.longestStayBehindDoor < $1.longestStayBehindDoor }
        let calendar = Calendar.current
        let newest = all.last?.startedAt ?? Date()
        let end = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: newest)).map { max($0, newest) } ?? newest
        let start: Date
        if let days = period.days {
            start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: newest)) ?? newest
        } else {
            start = calendar.date(byAdding: .hour, value: -12, to: calendar.startOfDay(for: all.first?.startedAt ?? newest)) ?? newest
        }
        sessions = all.filter { $0.startedAt >= start }
        includesFirstTraining = sessions.first?.id == all.first?.id
        domain = start...end.addingTimeInterval(12 * 3600)
    }

    var first: TrainingRecord? { sessions.first }
    var best: TrainingRecord? { sessions.max { $0.longestStayBehindDoor < $1.longestStayBehindDoor } }
    var cleanCount: Int { sessions.filter { $0.falseStarts == 0 }.count }
    var falseStartTotal: Int { sessions.reduce(0) { $0 + $1.falseStarts } }

    /// How much longer the dog stays behind the door now than at the start of the period.
    var gain: TimeInterval? {
        guard sessions.count > 1, let first, let best else { return nil }
        return best.longestStayBehindDoor.rounded(.down) - first.longestStayBehindDoor.rounded(.down)
    }

    /// "+2:25", "−0:10". Shown in the plain text colour: a longer exit is a change, not by itself a success.
    var gainText: String? {
        gain.map { ($0 < 0 ? "−" : "+") + DurationText.clock(abs($0)) }
    }

    /// «С первой тренировки» when the period reaches back to it, else the period's own «За четыре недели» etc.
    var gainTitle: String {
        includesFirstTraining ? String(localized: "С первой тренировки") : period.gainTitle
    }

    /// iPhone's title of the change, naming what it is counted from: «С первой тренировки» when the period reaches
    /// back to it, else the period's first training, «С 6 сент.» (the Mac says it in a note: «было 0:07 6 сент.»).
    var gainSince: String {
        guard !includesFirstTraining, let first else { return String(localized: "С первой тренировки") }
        return String(localized: "С \(HistoryDate.dayMonth(first.startedAt))")
    }

    /// The training whose date is closest to `date` (a finger or pointer on the chart).
    func nearest(to date: Date) -> TrainingRecord? {
        sessions.min { abs($0.startedAt.timeIntervalSince(date)) < abs($1.startedAt.timeIntervalSince(date)) }
    }

    /// Top of the y axis and the step of its labels: round clock values, at most `labels` steps.
    func yAxis(labels: Int) -> (max: TimeInterval, step: TimeInterval) {
        let top = sessions.map { max($0.longestStayBehindDoor, $0.longestPlannedExit) }.max() ?? 0
        let steps: [TimeInterval] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let step = steps.first { top * 1.08 / $0 <= Double(labels) } ?? 7200
        return (max(step * 2, (top * 1.08 / step).rounded(.up) * step), step)
    }

    /// Date labels (left-aligned to their day), about `labels` of them for a month, every two weeks for a quarter,
    /// monthly beyond; none within the last `edge` of the axis, where it would be cut off.
    func xAxisValues(labels: Int, edge: Double = 0.06) -> [Date] {
        let calendar = Calendar.current
        let days = domain.upperBound.timeIntervalSince(domain.lowerBound) / 86_400
        let first = calendar.startOfDay(for: domain.lowerBound.addingTimeInterval(86_400 - 1))
        let step: DateComponents = days <= 40 ? DateComponents(day: max(1, Int((days / Double(labels)).rounded())))
            // Every two weeks, every four on a narrow iPhone (six labels would run into each other).
            : days <= 120 ? DateComponents(day: days / 14 <= Double(labels) + 1 ? 14 : 28)
            : DateComponents(month: max(1, Int((days / 30 / Double(labels)).rounded(.up))))
        let lastAllowed = domain.upperBound.addingTimeInterval(-days * 86_400 * edge)
        var values: [Date] = []
        var date = first
        while date <= lastAllowed {
            values.append(date)
            guard let next = calendar.date(byAdding: step, to: date) else { break }
            date = next
        }
        return values
    }
}

/// Above the list, one card: folded, the two figures of the picked period and › (design council, rounds 12–13); a tap
/// on them unfolds the chart of the longest exit of each training against the plan under them, and the period that
/// rules both under the chart (as Gentler Streak's Week / Month / Year; under it, so the figures stay where the folded
/// card has them), and folds it again. A finger on the chart puts that training in the first figure (its day and fact);
/// letting go brings back the longest exit of the period. A tap on a point opens its training. No legend, no dates of
/// the period, no sentence (design council, round 12): the axis has the dates, the pink line is the pink figure's, the
/// dashes are the plan and the orange marks the rows' false starts.
private struct HistoryProgressCard: View {
    let records: [TrainingRecord]
    var isExpanded: Bool
    /// A tap on the figures: the chart unfolds or folds.
    var onToggle: () -> Void
    /// A tap on a training's point (or by it): that training's screen.
    var onOpen: (TrainingRecord) -> Void = { _ in }
    /// The period picked last (raw `HistoryPeriod`); empty until the first pick, `compact(for:)` decides meanwhile.
    @AppStorage(HistoryPeriod.storageKey) private var storedPeriod = ""
    @State private var selectedDate: Date?
    /// Where the chart's points are, for a tap (see `chart`).
    @State private var pointPositions: [PointPosition] = []

    var body: some View {
        let period = HistoryPeriod(rawValue: storedPeriod) ?? .compact(for: records)
        let progress = HistoryProgress(records: records, period: period)
        let selected = isExpanded ? selectedDate.flatMap(progress.nearest(to:)) : nil
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onToggle) {
                HStack(alignment: .center, spacing: 10) {
                    HistoryProgressFigures(progress: progress, selected: selected)
                    // The card opens, like a row of the list: a quiet chevron that turns down when it is open.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isExpanded ? String(localized: "развёрнуто") : String(localized: "свёрнуто"))
            if isExpanded {
                // One training is a point, not a trend.
                if progress.sessions.count > 1 {
                    chart(progress, selected: selected)
                }
                periodPicker(period)
            }
        }
        .padding(.vertical, isExpanded ? 4 : 0)
        .sensoryFeedback(.selection, trigger: selected?.id)
    }

    // MARK: Period

    /// «4 недели · 3 месяца · Всё время», the Mac menu's periods; the pick is kept.
    private func periodPicker(_ period: HistoryPeriod) -> some View {
        Picker("Период", selection: Binding(get: { period }, set: { picked in
            selectedDate = nil
            withAnimation(.snappy(duration: 0.3)) { storedPeriod = picked.rawValue }
        })) {
            ForEach(HistoryPeriod.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: Chart

    private func chart(_ progress: HistoryProgress, selected: TrainingRecord?) -> some View {
        let axis = progress.yAxis(labels: 3)
        let accent = Theme.accent
        // A strip under the zero line for the false-start marks: a false start belongs to the training's day, not to
        // its longest exit (which is never one), so its mark stays off the line's points.
        let lane = progress.falseStartTotal > 0 ? axis.max * 0.11 : 0
        return Chart {
            ForEach(progress.sessions) { record in
                // Straight lines between the trainings (GPT, round 9): a curve drew values between them that no
                // training had.
                AreaMark(x: .value("Дата", record.startedAt), yStart: .value("За дверью", 0),
                         yEnd: .value("За дверью", record.longestStayBehindDoor))
                    .interpolationMethod(.linear)
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Дата", record.startedAt), y: .value("За дверью", record.longestStayBehindDoor),
                         series: .value("Ряд", String(localized: "Факт")))
                    .interpolationMethod(.linear)
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                LineMark(x: .value("Дата", record.startedAt), y: .value("План", record.longestPlannedExit),
                         series: .value("Ряд", String(localized: "План")))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color.white.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let selected {
                RuleMark(x: .value("Дата", selected.startedAt))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(progress.sessions) { record in
                PointMark(x: .value("Дата", record.startedAt), y: .value("За дверью", record.longestStayBehindDoor))
                    .symbolSize(record.id == selected?.id ? 70 : 22)
                    .foregroundStyle(accent)
                if record.falseStarts > 0 {
                    PointMark(x: .value("Дата", record.startedAt), y: .value("Фальстарт", -lane / 2))
                        .symbol(.triangle)
                        .symbolSize(record.id == selected?.id ? 50 : 28)
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .chartYScale(domain: -lane...axis.max)
        .chartXScale(domain: progress.domain)
        .chartYAxis {
            AxisMarks(position: .trailing, values: Array(stride(from: 0, through: axis.max, by: axis.step))) { value in
                AxisGridLine()
                AxisValueLabel {
                    Text(DurationText.clock(value.as(Double.self) ?? 0)).monospacedDigit()
                }
            }
        }
        // Dates without grid lines: the horizontal ones are enough to read a time off.
        .chartXAxis {
            // A narrow plot: a date label is about a seventh of it.
            AxisMarks(values: progress.xAxisValues(labels: 4, edge: 0.15)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(HistoryDate.dayMonth(date)) }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        // Where each training's point is across the chart, for a tap: the overlay itself takes no touches (one that
        // did kept the finger moved along the chart from showing the trainings in the figure).
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let points = Self.pointPositions(proxy: proxy, geometry: geometry, sessions: progress.sessions)
                Color.clear.onChange(of: points, initial: true) { _, points in pointPositions = points }
            }
            .allowsHitTesting(false)
        }
        // A tap by a point opens that training (Fable, round 9); a finger moved along the chart still only shows it
        // in the figure.
        .simultaneousGesture(SpatialTapGesture().onEnded { tap in
            guard let nearest = pointPositions.min(by: { abs($0.x - tap.location.x) < abs($1.x - tap.location.x) }),
                  abs(nearest.x - tap.location.x) <= 22,
                  let record = progress.sessions.first(where: { $0.id == nearest.id }) else { return }
            selectedDate = nil
            onOpen(record)
        })
        .frame(height: 150)
        .accessibilityLabel("График: дольше всего за дверью по тренировкам")
    }

    /// A training's point across the chart, in the chart's own coordinates.
    private struct PointPosition: Equatable {
        let id: UUID
        let x: CGFloat
    }

    private static func pointPositions(proxy: ChartProxy, geometry: GeometryProxy,
                                       sessions: [TrainingRecord]) -> [PointPosition] {
        guard let plot = proxy.plotFrame else { return [] }
        let origin = geometry[plot].origin.x
        return sessions.compactMap { record in
            proxy.position(forX: record.startedAt).map { PointPosition(id: record.id, x: origin + $0) }
        }
    }
}

/// The progress card's two figures, of the picked period: the longest exit, and the one change — since the period's
/// first training («С первой тренировки +2:25», «С 6 сент. +2:25»). No «план 2:30» beside the first (design council,
/// round 13): the chart's dashes have it. Folded, they are the whole card; unfolded, its top, the training under a
/// finger on the chart in the first one («Пт, 2 окт. 2:01»).
private struct HistoryProgressFigures: View {
    let progress: HistoryProgress
    var selected: TrainingRecord?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let shown = selected ?? progress.best {
                figure(selected.map { HistoryDate.day($0.startedAt) } ?? String(localized: "Самый длинный выход"),
                       HistoryText.longest(shown))
                    .animation(.snappy(duration: 0.2), value: shown.id)
            }
            if let gain = progress.gainText {
                Divider()
                figure(progress.gainSince, gain)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(value)
                .font(Theme.display(20).monospacedDigit())
                .contentTransition(.numericText())
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Player plus share / Photos / Finder buttons for one recording file.
private struct RecordingSection: View {
    @Environment(AppModel.self) private var model
    let url: URL

    @State private var player: AVPlayer?
    /// The video's length, for the preview.
    @State private var duration: TimeInterval?
    /// Played once: the player's own controls from then on.
    @State private var started = false

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { if !started { poster } }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause() }
            // Recordings made before finalization existed are converted on first open; the length is read after.
            .task(id: url) {
                await model.finalizeRecording(url)
                duration = await RecordingClip(url: url, date: .now).loadDuration()
            }
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

    /// Until it is first played, the video says it is one, as Photos' previews do (Opus, round 10): ▶ in the middle
    /// and its length in the corner; a tap anywhere on it plays it, then the player's own controls take over.
    private var poster: some View {
        Button {
            started = true
            player?.play()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.black.opacity(0.45), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let duration {
                    Text(DurationText.clock(duration))
                        .font(.system(.caption, design: .rounded, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(10)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(duration.map { String(localized: "Смотреть видео, \(DurationText.clock($0))") }
                            ?? String(localized: "Смотреть видео"))
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
                    .accessibilityLabel("Удалить запись")
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

/// A training opened from the history, in the shape of the card shown right after it: what happened (exits done of
/// planned, the longest exit, false starts when there were any, length) and «Отправить тренеру» as the one main action;
/// then every exit with its plan and fact in the same two columns, and the video. No sentence drawing the conclusion
/// («Фальстарт на выходе 7, со второй попытки — 2:32») and no «0 фальстартов» (design council, round 12): the rows
/// show it. Deletion waits in «···».
struct HistoryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: TrainingRecord

    @State private var confirmDelete = false
    /// Width of the plan and fact columns ("12:30"), growing with the text size.
    @ScaledMetric(relativeTo: .body) private var column: CGFloat = 46
    private static let bottomID = "bottom"
    /// A part of a recording that broke off, opened from its tile.
    @State private var openedPart: Tile?

    var body: some View {
        let videoURL = model.store.recordingURL(for: record)
        let longest = record.longestResult
        let report = RecordingReport(record: record, model: model)
        // The parts of a recording that broke off, oldest first: tiles side by side, each with its exits.
        let parts = videoURL.map { Self.tiles(report, video: $0, record: record) } ?? []
        ScrollViewReader { proxy in
            List {
                // Whole points above the exits too: what the rows below start at (see `WholePointHeight`).
                Section { WholePointHeight { summary(longest: longest) } }

                Section {
                    ForEach(Array(record.results.enumerated()), id: \.element.id) { index, result in
                        exitRow(result, showsBreak: index < record.results.count - 1,
                                isLongest: result.id == longest?.id && result.awayDuration > 0)
                            .id(index == record.results.count - 1 && videoURL == nil ? Self.bottomID : result.id.uuidString)
                    }
                } header: {
                    WholePointHeight { columnsHeader }
                } footer: {
                    // No video where one was recorded: why, in the Mac inspector's words. Never recorded: nothing to say.
                    if videoURL == nil, report.kind != .none {
                        recordingLine(report.text, systemImage: report.systemImage)
                    }
                }

                if let videoURL {
                    Section {
                        if parts.count > 1 {
                            // Two parts (or more) side by side, each a tap away, and between two the break in the
                            // recording: «нет записи 2:10», level with the pictures (GPT, round 15: without the
                            // sentence under them, two tiles showed two files but not the 2:10 missing between them;
                            // round 17: ✂ read as a cut, not as nothing recorded).
                            HStack(alignment: .thumbnailCenter, spacing: 6) {
                                // Buttons, not links: a link in a list row draws its chevron after each tile.
                                ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                                    if index > 0 {
                                        gapMark(from: parts[index - 1].end, to: part.start)
                                    }
                                    Button { openedPart = part } label: {
                                        RecordingTile(url: part.url, caption: part.caption)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                            .id(Self.bottomID)
                        } else {
                            VStack(alignment: .leading, spacing: 12) { RecordingSection(url: videoURL) }
                                .padding(.vertical, 4)
                                .id(Self.bottomID)
                        }
                    } header: {
                        Text("Видео")
                    } footer: {
                        // Only what isn't plain: which exits a single part holds («Запись началась в 18:40», «В этом
                        // видео — выходы 3–7»). A video of the whole training says nothing, and nor do the parts of one
                        // that broke off: their tiles «Выходы 1–4», «Выходы 5–7» show the break (design council, round 14).
                        if parts.count < 2, report.kind == .partial {
                            recordingLine([report.text, report.detail].compactMap { $0 }.joined(separator: "\n"),
                                          systemImage: report.systemImage)
                        }
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #else
            .modifier(HardTopEdge())
            // On the list's own colour, solid: the summary's pink button never shows through under the date.
            .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            #if DEBUG
            // `--demo-scroll-bottom`: the end of the screen (the last exits, the video and what became of it) for
            // screenshots. To the top of the last row: the list stops at its end, the footer under it in view.
            .task {
                guard CommandLine.arguments.contains("--demo-scroll-bottom") else { return }
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo(Self.bottomID, anchor: .top)
                // Once more, after the list has settled.
                try? await Task.sleep(for: .milliseconds(600))
                withAnimation { proxy.scrollTo(Self.bottomID, anchor: .top) }
                // `--demo-open-part`: then the first part of a recording that broke off, opened from its tile.
                if CommandLine.arguments.contains("--demo-open-part") {
                    try? await Task.sleep(for: .milliseconds(800))
                    openedPart = parts.first
                }
            }
            #endif
        }
        // The day the list row led with; the plan's own title opens the summary.
        .navigationTitle(HistoryDate.day(record.startedAt))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(item: $openedPart) { part in
            RecordingPartView(url: part.url, title: part.caption)
        }
        // Deletion out of the way of «Отправить тренеру» (Fable, round 8): in «···», as Apple's own detail screens
        // keep it, with the same question before it.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Удалить тренировку…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Label("Ещё", systemImage: "ellipsis")
                }
                .accessibilityLabel("Ещё")
            }
        }
        .confirmationDialog("Удалить тренировку?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить вместе с видео", role: .destructive) {
                model.delete(record, includingRecording: true)
                dismiss()
            }
            if videoURL != nil {
                Button("Удалить только лог, видео оставить") {
                    model.delete(record, includingRecording: false)
                    dismiss()
                }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    /// A part of the training's recording as a tile: its file and «Выходы 1–4» (its start's time when no exit is in it).
    private struct Tile: Identifiable, Hashable {
        let url: URL
        let caption: String
        /// When the recording of this part began and stopped.
        let start: Date
        let end: Date
        var id: URL { url }
    }

    /// The parts that are recordings of their own here, then the training's own video, each with its exits.
    private static func tiles(_ report: RecordingReport, video: URL, record: TrainingRecord) -> [Tile] {
        guard !report.earlierParts.isEmpty else { return [] }
        let earlier = report.earlierParts.map { part in
            Tile(url: part.clip.url,
                 caption: RecordingReport.exitList(part.exits, capitalized: true) ?? HistoryDate.time(part.start),
                 start: part.start, end: part.end)
        }
        let last = Tile(url: video, caption: RecordingReport.exitList(report.videoExits, capitalized: true)
                        ?? String(localized: "Видео"),
                        start: report.videoStart ?? record.startedAt, end: record.finishedAt)
        return earlier + [last]
    }

    /// The break between two parts of the recording, small and grey: «нет записи» over its length, «2:10»; VoiceOver
    /// says it whole, «Запись прерывалась в 18:46 на 2:10».
    private func gapMark(from end: Date, to start: Date) -> some View {
        let gap = DurationText.clock(max(0, start.timeIntervalSince(end)))
        return VStack(spacing: 2) {
            Text("нет записи")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .fixedSize()
            Text(verbatim: gap)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Запись прерывалась в \(HistoryDate.time(end)) на \(gap)"))
    }

    /// What became of the video, one or two quiet lines: «Запись прерывалась в 18:46 на 2:10», «Файл видео удалён».
    private func recordingLine(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
    }

    // MARK: Summary

    private func summary(longest: ExitResult?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // "Тренировка на пятницу · Аня / Марк" over "18:36–19:01 · 25 мин", as the log starts; where the
            // first line doesn't fit, the trainers open the second one instead of breaking off mid-name.
            ViewThatFits(in: .horizontal) {
                titleLines(trainersFirst: false)
                titleLines(trainersFirst: true)
            }
            .accessibilityElement(children: .combine)

            // The finish card's figures; on a narrow iPhone, or in large text, a little closer together.
            ViewThatFits(in: .horizontal) {
                figures(longest: longest, stacked: false)
                figures(longest: longest, stacked: true)
            }

            // The one «Отправить тренеру», here at the top (design council, round 14: a second one came up at the
            // bottom once this one had scrolled away).
            shareButton
        }
        .padding(.vertical, 6)
    }

    /// «Отправить тренеру», the one main action, in the summary.
    private var shareButton: some View {
        ShareLink(item: SessionLogFormatter.text(for: record), preview: SharePreview(record.plan.displayTitle)) {
            Label("Отправить тренеру", systemImage: "square.and.arrow.up")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func titleLines(trainersFirst: Bool) -> some View {
        let title = record.plan.title.trimmingCharacters(in: .whitespaces)
        let trainers = record.plan.trainers.trimmingCharacters(in: .whitespaces)
        let when = "\(HistoryDate.time(record.startedAt))–\(HistoryDate.time(record.finishedAt)) · \(HistoryText.length(record))"
        let moved = trainersFirst && !trainers.isEmpty
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: trainers.isEmpty || moved ? title : "\(title) · \(trainers)")
                .font(.headline)
            Text(verbatim: moved ? "\(trainers) · \(when)" : when)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        // The last resort (a long title, large text) wraps rather than cuts.
        .lineLimit(trainersFirst ? 2 : 1)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// «7 из 7 выходов · 2:32 дольше всего · 1 фальстарт»: the plan of the longest exit is in its row, and false starts
    /// only when there were some.
    private func figures(longest: ExitResult?, stacked: Bool) -> some View {
        HStack(alignment: .top, spacing: stacked ? 18 : 24) {
            // Genitive after «из»: «из 1 выхода», «из 7 выходов».
            figure(String(localized: "\(record.completedExits) из \(record.plan.exits.count)"),
                   HistoryText.word(pluralText(record.plan.exits.count, ru: ("выхода", "выходов", "выходов"), en: ("exit", "exits"))))
            if let longest, longest.awayDuration > 0 {
                figure(DurationText.clock(longest.awayDuration), String(localized: "дольше всего"))
            }
            if record.falseStarts > 0 {
                figure("\(record.falseStarts)", HistoryText.word(HistoryText.falseStarts(record.falseStarts)), tint: Theme.warning)
            }
        }
    }

    private func figure(_ value: String, _ label: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(Theme.display(22, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    // MARK: Exits

    /// «Выходы … План  Факт» over the two columns of the rows.
    private var columnsHeader: some View {
        HStack(spacing: 10) {
            Text("Выходы")
            Spacer(minLength: 8)
            Text("План").frame(minWidth: column, alignment: .trailing)
            Text("Факт").frame(minWidth: column, alignment: .trailing)
        }
    }

    /// One attempt: «Выход 7» (with ↶ when a false start cut it short) on the left, its plan and fact in the columns; under the name only what the columns don't
    /// say, in the log's order: «или до вставания», what the owner marked from behind the door in an older training, and a
    /// break that was not like the others («⏸ 5:00»).
    private func exitRow(_ result: ExitResult, showsBreak: Bool, isLongest: Bool) -> some View {
        WholePointHeight {
            exitRowContent(result, showsBreak: showsBreak, isLongest: isLongest)
        }
    }

    private func exitRowContent(_ result: ExitResult, showsBreak: Bool, isLongest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                name(of: result)
                Spacer(minLength: 8)
                Text(result.isOpen ? "—" : DurationText.clock(result.plannedDuration))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: column, alignment: .trailing)
                // The false start in the colour of its ↶, as in the list and on the chart; every other fact plain, the
                // repeat and the longest one too (design council, round 14: a pink 2:32 after an orange 1:00 was a
                // second colour with no rule).
                Text(result.leftAt == nil ? "—" : DurationText.clock(result.awayDuration))
                    .fontWeight(.semibold)
                    .foregroundStyle(result.falseStart ? Theme.warning : Color.primary)
                    .frame(minWidth: column, alignment: .trailing)
            }
            // The whole width of the row, under the columns too: the numbers are on the first line only. In lines of
            // whole parts, a «·» only between two on one line (Fable, round 9: «залаяла на 1:46 ·» hung at the end of
            // a line here, as the finish card no longer lets it).
            let parts = noteParts(for: result)
            if !parts.isEmpty {
                SeparatedFlowLayout(spacing: 4, lineSpacing: 1) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        if index > 0 { FlowDot() }
                        part
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if showsBreak, let pause = specialBreak(after: result) {
                pause
                    .font(.footnote)
                    .padding(.top, 1)
            }
        }
        .monospacedDigit()
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(for: result, showsBreak: showsBreak, isLongest: isLongest))
    }

    /// "Выход 7", or "Выход 7 ↶" for the attempt a false start cut short: the false start's sign, orange as its fact and
    /// as «↶ 1» in the list (design council, rounds 13–14: «Фальстарт», «попытка 2» and a ↶ on the repeat said it three
    /// ways). The repeat that follows is a plain «Выход 7».
    private func name(of result: ExitResult) -> Text {
        let exit = Text("Выход \(result.number)")
        guard result.falseStart else { return exit }
        return Text("\(exit) \(Text(Image(systemName: "arrow.uturn.backward")).foregroundStyle(Theme.warning))")
    }

    /// "или до вставания", "залаяла на 0:42" (marks of an older training). A false start says nothing in words: its row
    /// is «Выход 7 ↶» with an orange fact, and the next one its repeat.
    private func noteParts(for result: ExitResult) -> [Text] {
        var parts: [Text] = []
        if result.leftAt == nil, !result.falseStart {
            parts.append(Text(Self.capitalized(SessionLogFormatter.outcome(of: result))))
        }
        if result.untilStanding { parts.append(Text(PlannedExit.untilStandingText)) }
        if result.isOpen { parts.append(Text(PlannedExit.openText)) }
        // A long line wraps between the parts, never inside one («замолчала» / «1:54»).
        parts += SessionLogFormatter.observations(of: result, in: record).map { Text(verbatim: HistoryText.unbroken($0)) }
        return parts
    }

    /// The break after the exit, only when it was not like the others — the exit's own one (the trainer's «Перерыв 5
    /// минут»), or one well off its plan — as the plan shows an own break: «⏸ 5:00» (design council, round 12:
    /// «перерыв после 2:02» under every exit; round 13: «После — перерыв» said what the sign and the place say). The log
    /// for the trainer keeps every break, with its plan.
    private func specialBreak(after result: ExitResult) -> Text? {
        guard let actual = result.actualBreak else { return nil }
        let own = abs(result.plannedBreak - record.plan.defaultBreak) >= 1
        let off = abs(actual - result.plannedBreak) >= max(30, result.plannedBreak * 0.25)
        guard own || off else { return nil }
        let sign = Text(Image(systemName: "pause.circle")).foregroundStyle(Theme.info)
        return Text("\(sign) \(Text(verbatim: DurationText.clock(actual)).foregroundStyle(.secondary))")
    }

    /// "Выход 7, попытка 2, план 2:30, за дверью 2:32, дольше всего, перерыв после 2:02".
    private func accessibilityText(for result: ExitResult, showsBreak: Bool, isLongest: Bool) -> String {
        var parts = [result.attempt > 1
            ? String(localized: "Выход \(result.number), попытка \(result.attempt)")
            : String(localized: "Выход \(result.number)")]
        var plan = result.isOpen ? PlannedExit.openText : DurationText.clock(result.plannedDuration)
        if result.untilStanding { plan += " " + PlannedExit.untilStandingText }
        parts.append(String(localized: "план \(plan)"))
        parts.append(SessionLogFormatter.outcome(of: result))
        if isLongest { parts.append(String(localized: "дольше всего")) }
        parts += SessionLogFormatter.observations(of: result, in: record)
        if showsBreak, specialBreak(after: result) != nil, let pause = SessionLogFormatter.breakText(for: result, in: record) {
            parts.append(pause)
        }
        return parts.joined(separator: ", ")
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// A part of a training's recording, as Photos shows a video: its first frame with ▶ and its length in the corner, and
/// under it what it holds, «Выходы 1–4».
private struct RecordingTile: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let caption: String

    @State private var frame: CGImage?
    @State private var duration: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.black.opacity(0.35)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if let frame {
                        Image(decorative: frame, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .overlay(alignment: .bottomTrailing) {
                    if let duration {
                        Text(DurationText.clock(duration))
                            .font(.system(.caption2, design: .rounded, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: Capsule())
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                // The break between two tiles stands level with their pictures, not with picture and caption.
                .alignmentGuide(.thumbnailCenter) { $0[VerticalAlignment.center] }
            Text(caption)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(duration.map { "\(caption), \(DurationText.clock($0))" } ?? caption)
        .accessibilityAddTraits(.isButton)
        .task(id: url) {
            await model.finalizeRecording(url)
            let asset = AVURLAsset(url: url)
            duration = await RecordingClip(url: url, date: .now).loadDuration()
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 360)
            frame = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        }
    }
}

extension VerticalAlignment {
    /// The middle of a recording tile's picture.
    private enum ThumbnailCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    fileprivate static let thumbnailCenter = VerticalAlignment(ThumbnailCenter.self)
}

/// One part of a training's recording, opened from its tile: the video with «Поделиться» and «В Фото».
private struct RecordingPartView: View {
    let url: URL
    let title: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RecordingSection(url: url)
            }
            .padding(16)
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Its content with the height rounded up to whole points. Text is not as high as a whole number of pixels: the
/// summary and the columns' header above the exits left the exit rows starting half a pixel off, each one's
/// background was rounded to pixels on its own, and between exits 5 and 6 one ended a pixel short of the next one's
/// start — the list's darker background showed through as a seam across the card (Opus, rounds 9–10).
private struct WholePointHeight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(proposal)
        // Less a hair first: 50.0000001 is 50, not 51.
        return CGSize(width: size.width, height: (size.height - 0.001).rounded(.up))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
