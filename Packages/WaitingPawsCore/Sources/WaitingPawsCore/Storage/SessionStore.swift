import Foundation

/// Persists finished sessions (JSON + text log) and hands out file locations for recordings.
public final class SessionStore {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
    }

    /// `Documents/Waiting Paws` on both platforms (visible in Files.app on iOS).
    public static var defaultRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("Waiting Paws", isDirectory: true)
    }

    public var sessionsDirectory: URL { rootDirectory.appendingPathComponent("Sessions", isDirectory: true) }
    public var recordingsDirectory: URL { rootDirectory.appendingPathComponent("Recordings", isDirectory: true) }

    /// Longest part of a recording's file name taken from the schedule title (Windows: `SessionStore.maxTitleLength`).
    static let maxTitleLength = 60

    /// A new file name; a second recording within the same minute gets a "-2" suffix instead of overwriting. A long
    /// schedule title is cut, as on Windows (which refuses paths over 260 characters): the same title gives the same
    /// name on both.
    public func newRecordingURL(for plan: TrainingPlan, at date: Date = Date()) -> URL {
        var slug = String(Go2RTCClient.streamName(for: plan.title).prefix(Self.maxTitleLength))
        while slug.hasSuffix("-") { slug.removeLast() }
        let base = "\(Self.fileStamp.string(from: date))-\(slug)"
        var url = recordingsDirectory.appendingPathComponent("\(base).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = recordingsDirectory.appendingPathComponent("\(base)-\(counter).mp4")
            counter += 1
        }
        return url
    }

    /// Recordings no saved session refers to: made without a training, or kept after deleting only the log.
    public func standaloneRecordings(besides records: [TrainingRecord]) -> [URL] {
        let referenced = Set(records.compactMap(\.recordingFileName))
        let files = (try? FileManager.default.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "mp4" && !referenced.contains($0.lastPathComponent) }
    }

    public func recordingURL(for record: TrainingRecord) -> URL? {
        guard let name = record.recordingFileName, Self.isRecordingFileName(name) else { return nil }
        let url = recordingsDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A video name a record may point at: a bare `*.mp4` file name in `Recordings` (any case of the extension). A
    /// history file copied from elsewhere with a path there (`../../…`, `C:…`) must not send deleting or sharing to
    /// another file. As `SessionStore.isRecordingFileName` on Windows.
    static func isRecordingFileName(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name[name.index(after: dot)...].lowercased() == "mp4" else { return false }
        return !name.unicodeScalars.contains { $0.value < 0x20 || "/\\:".unicodeScalars.contains($0) }
    }

    public func logURL(for record: TrainingRecord) -> URL {
        sessionsDirectory.appendingPathComponent("\(Self.baseName(for: record)).txt")
    }

    public func jsonURL(for record: TrainingRecord) -> URL {
        sessionsDirectory.appendingPathComponent("\(Self.baseName(for: record)).json")
    }

    public func save(_ record: TrainingRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: jsonURL(for: record), options: .atomic)
        try SessionLogFormatter.text(for: record).write(to: logURL(for: record), atomically: true, encoding: .utf8)
    }

    public func loadAll() -> [TrainingRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)) ?? []
        let records = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> TrainingRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(TrainingRecord.self, from: data)
            }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ record: TrainingRecord, includingRecording: Bool) {
        try? FileManager.default.removeItem(at: jsonURL(for: record))
        try? FileManager.default.removeItem(at: logURL(for: record))
        if includingRecording, let video = recordingURL(for: record) {
            try? FileManager.default.removeItem(at: video)
        }
    }

    private static func baseName(for record: TrainingRecord) -> String {
        "\(fileStamp.string(from: record.startedAt))-\(record.id.uuidString.prefix(8))"
    }

    public static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter
    }()
}
