import AVFoundation
import Foundation

/// Lengths of the recording files, read once per version of a file (its size and modification date) and kept on disk,
/// so the history does not open every video again each time it is shown. One read per file at a time: requests for
/// the same file share it.
///
/// A file that is not finished (`RecordingFinalizer.isUnfinished`: go2rtc's raw fragmented MP4) is never opened. To
/// read its length AVFoundation indexes every fragment, one per frame: a night's recording has millions, and three
/// such reads at once took the Mac ~3 minutes of 1.5 cores each time the history opened (2026-11-08). `estimate`
/// gives its length from the file's own times instead.
@MainActor
final class RecordingDurations {
    static let shared = RecordingDurations()

    private struct Entry: Codable {
        var bytes: Int64
        var modified: TimeInterval
        var seconds: TimeInterval
    }

    /// By file path.
    private var known: [String: Entry]
    private var running: [String: Task<TimeInterval?, Never>] = [:]
    private let storeURL: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        storeURL = caches.appendingPathComponent("recording-durations.json")
        known = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: storeURL))) ?? [:]
    }

    /// The length already read for this version of the file, without opening it.
    func cached(_ url: URL) -> TimeInterval? {
        guard let version = Self.version(of: url), let entry = known[url.path],
              entry.bytes == version.bytes, entry.modified == version.modified else { return nil }
        return entry.seconds
    }

    /// The video's length: remembered, or read once for this version of the file. `nil` for an unfinished file (it
    /// is not opened) and for one that cannot be read.
    func duration(of url: URL) async -> TimeInterval? {
        if let seconds = cached(url) { return seconds }
        guard let version = Self.version(of: url), !RecordingFinalizer.isUnfinished(url) else { return nil }
        let key = "\(url.path)|\(version.bytes)|\(version.modified)"
        if let task = running[key] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> TimeInterval? in
            guard let length = try? await AVURLAsset(url: url).load(.duration), length.isNumeric else { return nil }
            return length.seconds
        }
        running[key] = task
        let seconds = await task.value
        running[key] = nil
        if let seconds {
            known[url.path] = Entry(bytes: version.bytes, modified: version.modified, seconds: seconds)
            save()
        }
        return seconds
    }

    /// About how long an unfinished recording is: from its file's creation (go2rtc began writing) to its last change.
    nonisolated static func estimate(_ url: URL) -> TimeInterval? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let created = attributes[.creationDate] as? Date, let modified = attributes[.modificationDate] as? Date,
              modified > created else { return nil }
        return modified.timeIntervalSince(created)
    }

    private nonisolated static func version(of url: URL) -> (bytes: Int64, modified: TimeInterval)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return ((attributes[.size] as? NSNumber)?.int64Value ?? 0, modified.timeIntervalSinceReferenceDate)
    }

    private func save() {
        // Files that are gone are forgotten.
        known = known.filter { FileManager.default.fileExists(atPath: $0.key) }
        guard let data = try? JSONEncoder().encode(known) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
