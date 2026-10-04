#if os(macOS)
import AppKit
import AVFoundation
import SwiftUI
import WaitingPawsCore

// Data behind the «История» window: one row type for trainings and recordings, file info that is
// read once per change (not per frame), the window's selection/filter state and its actions.

// MARK: - Rows

/// A video file on disk: size is read when the history changes, the length is loaded in the background.
struct MacHistoryVideo: Equatable {
    let url: URL
    var bytes: Int64
    var duration: TimeInterval?

    var fileName: String { url.lastPathComponent }
}

/// One line of the table: a training (its log, maybe with a video) or a recording made without one.
struct MacHistoryRow: Identifiable {
    enum Kind {
        case training(TrainingRecord)
        case clip(RecordingClip)
    }

    let kind: Kind
    /// The video, if its file is still on disk.
    let video: MacHistoryVideo?

    var id: HistoryRoute {
        switch kind {
        case .training(let record): .session(record.id)
        case .clip(let clip): .clip(clip.id)
        }
    }

    var record: TrainingRecord? {
        if case .training(let record) = kind { return record }
        return nil
    }

    var clip: RecordingClip? {
        if case .clip(let clip) = kind { return clip }
        return nil
    }

    var isClip: Bool { clip != nil }

    var date: Date {
        switch kind {
        case .training(let record): record.startedAt
        case .clip(let clip): clip.date
        }
    }

    var title: String {
        record.map { $0.plan.title.trimmingCharacters(in: .whitespaces) } ?? "Запись без тренировки"
    }

    var trainers: String { record?.plan.trainers ?? "" }

    // Sort keys (−1 puts recordings without a log after the trainings).
    var startMinute: Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
    var exitsDone: Int { record?.completedExits ?? -1 }
    var falseStarts: Int { record?.falseStarts ?? -1 }
    var longest: Double { record?.longestStayBehindDoor ?? -1 }
    var planned: Double { record?.longestPlannedExit ?? -1 }
    var duration: Double { record?.duration ?? video?.duration ?? -1 }
    var videoBytes: Int64 { video?.bytes ?? -1 }

    /// End of the training or of the recording (for "19:12–19:30").
    var endDate: Date? {
        switch kind {
        case .training(let record): record.finishedAt
        case .clip(let clip): video?.duration.map { clip.date.addingTimeInterval($0) }
        }
    }

    /// "19:12–19:30" (or just the start while a recording's length is unknown).
    var timeRange: String {
        let start = MacFormat.time.string(from: date)
        return endDate.map { "\(start)–\(MacFormat.time.string(from: $0))" } ?? start
    }

    /// Everything the search field looks at: title, trainers, file name and the date in several spellings.
    var searchText: String {
        [title, trainers, video?.fileName ?? "",
         MacFormat.weekdayDay.string(from: date), MacFormat.fullDay.string(from: date),
         MacFormat.shortDate.string(from: date), MacFormat.time.string(from: date)]
            .joined(separator: " ")
    }

    var logText: String? { record.map(SessionLogFormatter.text(for:)) }
}

// MARK: - Record numbers

extension TrainingRecord {
    /// Longest successful stay behind the door (false starts don't count).
    var longestStayBehindDoor: TimeInterval {
        results.filter { !$0.falseStart }.map(\.awayDuration).max() ?? 0
    }

    /// Longest exit in the trainer's plan.
    var longestPlannedExit: TimeInterval { plan.exits.map(\.duration).max() ?? 0 }

    /// When the recording of this training began: its «Запись включена» event, else the start of the training.
    var recordingStartDate: Date {
        let starts = events.filter { $0.kind == .recordingStarted }
        let own = starts.first { $0.detail != nil && $0.detail == recordingFileName } ?? starts.first
        return own?.time ?? startedAt
    }
}

// MARK: - Formatting

enum MacHistoryFormat {
    /// "Пт, 2 окт." (the year is added for older entries).
    static func day(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return (sameYear ? MacFormat.weekdayDay : weekdayDayYear).string(from: date).capitalizedFirst
    }

    /// "2 окт."
    static func dayMonth(_ date: Date) -> String { dayMonthShort.string(from: date) }

    /// "Пятница, 2 октября, 18:36–19:02".
    static func longDay(_ row: MacHistoryRow) -> String {
        "\(MacFormat.fullDay.string(from: row.date).capitalizedFirst), \(row.timeRange)"
    }

    /// "813 МБ", "5,8 ГБ" (decimal units, as in Finder).
    static func bytes(_ count: Int64) -> String {
        let megabytes = Double(count) / 1_000_000
        if megabytes >= 1000 { return decimal(megabytes / 1000) + " ГБ" }
        if megabytes >= 10 { return "\(Int(megabytes.rounded())) МБ" }
        if megabytes >= 0.1 { return decimal(megabytes) + " МБ" }
        return "\(max(1, Int((Double(count) / 1000).rounded()))) КБ"
    }

    /// "1 тренировка", "3 тренировки", "11 тренировок".
    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = n % 100, ones = n % 10
        let word = ones == 1 && tens != 11 ? one
            : (2...4).contains(ones) && !(12...14).contains(tens) ? few : many
        return "\(n) \(word)"
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    private static let dayMonthShort = make("d MMM")
    private static let weekdayDayYear = make("EE, d MMM yyyy")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = format
        return formatter
    }
}

/// Text colours that keep contrast in both appearances (the bright brand colours stay for fills and symbols).
enum MacHistoryInk {
    static let orange = adaptive(dark: NSColor(red: 1.00, green: 0.70, blue: 0.30, alpha: 1),
                                 light: NSColor(red: 0.80, green: 0.42, blue: 0.00, alpha: 1))
    static let green = adaptive(dark: NSColor(red: 0.42, green: 0.86, blue: 0.56, alpha: 1),
                                light: NSColor(red: 0.12, green: 0.55, blue: 0.27, alpha: 1))

    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Window state

/// Selection, filters and actions of the «История» window (shared by the table, chart, toolbar and inspector).
@MainActor
@Observable
final class MacHistoryController {
    enum Scope: String, CaseIterable, Identifiable {
        case all, trainings, clips
        var id: Self { self }
        var title: String {
            switch self {
            case .all: "Все"
            case .trainings: "Тренировки"
            case .clips: "Только видео"
            }
        }
    }

    /// A delete waiting for confirmation; `onlyLog == nil` lets the dialog offer both ways.
    struct PendingDelete: Identifiable {
        let row: MacHistoryRow
        var onlyLog: Bool?
        var id: HistoryRoute { row.id }
    }

    var scope: Scope = .all
    var search = ""
    var selection: HistoryRoute?
    var sortOrder = [KeyPathComparator(\MacHistoryRow.date, order: .reverse)]
    var showsInspector = true
    var period: MacHistoryPeriod = .fourWeeks
    var pendingDelete: PendingDelete?
    var confirmDeleteAll = false
    /// Row whose log was just copied (the button shows «Скопировано» for a moment).
    var copiedLog: HistoryRoute?
    /// Bumped when the chart asks the table to bring the selection into view.
    var scrollRequest = 0

    let player = MacHistoryPlayer()
    private(set) var videos: [String: MacHistoryVideo] = [:]
    /// Videos already checked by `AppModel.finalizeRecording` in this window (each file once).
    @ObservationIgnored var finalizedURLs: Set<URL> = []

    #if DEBUG
    /// `--demo-history-videos`: sample trainings with generated videos in a folder of their own.
    var demo: MacHistoryDemo?
    #endif

    // MARK: Data

    func records(_ model: AppModel) -> [TrainingRecord] {
        #if DEBUG
        if let demo { return demo.records }
        #endif
        return model.history
    }

    func clips(_ model: AppModel) -> [RecordingClip] {
        #if DEBUG
        if let demo { return demo.clips }
        #endif
        return model.clips
    }

    func videoURL(for record: TrainingRecord, model: AppModel) -> URL? {
        #if DEBUG
        if let demo { return demo.videoURL(for: record) }
        #endif
        return model.store.recordingURL(for: record)
    }

    /// Every training and recording, unsorted.
    func allRows(_ model: AppModel) -> [MacHistoryRow] {
        records(model).map { record in
            MacHistoryRow(kind: .training(record), video: record.recordingFileName.flatMap { videos[$0] })
        } + clips(model).map { clip in
            MacHistoryRow(kind: .clip(clip), video: videos[clip.id])
        }
    }

    /// What the table shows: filtered by the segmented control and the search field, sorted by the column.
    func visibleRows(_ model: AppModel) -> [MacHistoryRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return allRows(model)
            .filter { row in
                switch scope {
                case .all: true
                case .trainings: !row.isClip
                case .clips: row.isClip
                }
            }
            .filter { query.isEmpty || $0.searchText.localizedStandardContains(query) }
            .sorted(using: sortOrder)
    }

    func row(_ id: HistoryRoute?, model: AppModel) -> MacHistoryRow? {
        guard let id else { return nil }
        return allRows(model).first { $0.id == id }
    }

    func isEmpty(_ model: AppModel) -> Bool { records(model).isEmpty && clips(model).isEmpty }

    /// Changes whenever files may have appeared, gone or been rewritten.
    func filesSignature(_ model: AppModel) -> [String] {
        records(model).map { "\($0.id)\($0.recordingFileName ?? "")" } + clips(model).map(\.id)
            + model.finalizingFileNames.sorted().map { "…" + $0 }
    }

    /// Re-reads which videos exist and their sizes, then loads the lengths that are not known yet.
    func refreshFiles(_ model: AppModel) async {
        var found: [String: MacHistoryVideo] = [:]
        func add(_ url: URL) {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            found[url.lastPathComponent] = MacHistoryVideo(url: url, bytes: bytes, duration: videos[url.lastPathComponent]?.duration)
        }
        for record in records(model) {
            if let url = videoURL(for: record, model: model) { add(url) }
        }
        for clip in clips(model) { add(clip.url) }
        videos = found
        for (name, video) in found where video.duration == nil {
            guard let length = try? await AVURLAsset(url: video.url).load(.duration), length.isNumeric else { continue }
            if Task.isCancelled { return }
            videos[name]?.duration = length.seconds
        }
    }

    // MARK: Actions

    /// Selects a row from outside the table (the chart): clears filters that hide it and scrolls to it.
    func reveal(_ id: HistoryRoute, model: AppModel) {
        if !visibleRows(model).contains(where: { $0.id == id }) {
            scope = .all
            search = ""
        }
        selection = id
        scrollRequest += 1
    }

    func copyLog(of row: MacHistoryRow) {
        guard let text = row.logText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedLog = row.id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if copiedLog == row.id { copiedLog = nil }
        }
    }

    /// The video in Finder; for a training without one, its text log.
    func revealInFinder(_ row: MacHistoryRow, model: AppModel) {
        if let url = row.video?.url {
            Finder.reveal(url)
        } else if let record = row.record {
            let log = model.store.logURL(for: record)
            Finder.reveal(FileManager.default.fileExists(atPath: log.path) ? log : model.store.sessionsDirectory)
        }
    }

    func play(_ row: MacHistoryRow) {
        guard let url = row.video?.url else { return }
        selection = row.id
        showsInspector = true
        player.play(url)
    }

    func togglePlayback(_ row: MacHistoryRow?) {
        guard let row, let url = row.video?.url else { return }
        if player.url == url { player.toggle() } else { play(row) }
    }

    func confirmDelete(_ row: MacHistoryRow, onlyLog: Bool? = nil) {
        // Without a video there is only one way to delete a training.
        let onlyLog = row.record != nil && row.video == nil ? false : onlyLog
        pendingDelete = PendingDelete(row: row, onlyLog: row.isClip ? false : onlyLog)
    }

    func delete(_ row: MacHistoryRow, onlyLog: Bool, model: AppModel, visible: [MacHistoryRow]) {
        // The next row (or the previous one at the end) takes over the selection.
        if selection == row.id, let index = visible.firstIndex(where: { $0.id == row.id }) {
            let rest = visible.filter { $0.id != row.id }
            selection = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
        }
        if let url = row.video?.url, player.url == url { player.load(nil) }
        switch row.kind {
        case .training(let record):
            #if DEBUG
            if demo != nil {
                demo?.delete(record, includingRecording: !onlyLog)
                if onlyLog, let name = record.recordingFileName { selection = .clip(name) }
                return
            }
            #endif
            model.delete(record, includingRecording: !onlyLog)
            // The video stays as a recording without a training: keep it selected.
            if onlyLog, let name = row.video?.fileName { selection = .clip(name) }
        case .clip(let clip):
            #if DEBUG
            if demo != nil {
                demo?.delete(clip)
                return
            }
            #endif
            model.delete(clip)
        }
    }

    func deleteAll(_ model: AppModel) {
        player.load(nil)
        selection = nil
        #if DEBUG
        if demo != nil {
            demo?.deleteAll()
            return
        }
        #endif
        model.deleteAll()
    }
}
#endif
