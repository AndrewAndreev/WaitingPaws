import AVFoundation
import Foundation

/// Turns a finished go2rtc recording into a file other apps treat as an ordinary video.
///
/// go2rtc writes fragmented MP4 with the camera's sound as is: Opus, or FLAC made from PCMA/PCMU
/// (it cannot produce AAC without ffmpeg). Photos indexes fragmented MP4 poorly and, like most players,
/// only accepts AAC sound in MP4; Telegram sends a video without an audio track as a GIF. So the video
/// is remuxed in place without re-encoding, the sound is converted to AAC, and a silent AAC track is
/// added when the camera gave no sound at all.
/// One part of a recording: the file and when it was requested (`AppModel` starts a new part each time the camera
/// stream breaks off and comes back, and each time the other camera is put on screen).
struct RecordingSegment: Equatable {
    let url: URL
    let startedAt: Date
    /// Written by the time the part ended; 0 while it is being written.
    var bytes: Int64 = 0
    /// When its video began to arrive (`StreamRecorder.firstFragmentAt`): the camera's next keyframe after the request.
    var mediaStartedAt: Date?
    /// Where its video lands in the recording.
    var placedAt: Date { mediaStartedAt ?? startedAt }
}

enum RecordingFinalizer {
    enum FinalizeError: LocalizedError {
        case noVideo
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: return String(localized: "the file has no video")
            case .failed(let why): return why
            }
        }
    }

    /// How far a finalize or a join is, 0…1. Called on AVFoundation's queues, only when it moved by half a percent.
    typealias ProgressHandler = @Sendable (Double) -> Void

    /// Where the sound's conversion ends and the export begins on the progress scale, so the bar moves evenly in time.
    /// Measured on the night's recording of 29 Oct (14.5 h, Opus, 702 MB) on an M-series Mac: ~225 s for the sound
    /// (finding its pauses ~17 s, then decoding and AAC), ~18 s for the export — about 4 minutes in all.
    static let soundShare = 0.9
    /// Within the sound's part: finding the pauses reads every packet without decoding them.
    static let pausesShare = 0.08

    /// Whether `url` is still go2rtc's raw fragmented MP4 (a recording in progress, or one whose finalize never ran
    /// to the end: the app closed meanwhile). Reads only atom headers (the top level's and `moov`'s children's), so it is
    /// cheap for any file size:
    /// AVFoundation, on the other hand, indexes such a file by reading every fragment (a night's recording has millions)
    /// — the history must not open one. `false` for a file that cannot be read.
    static func isUnfinished(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        var offset: UInt64 = 0
        for _ in 0..<16 {
            try? file.seek(toOffset: offset)
            guard let header = try? file.read(upToCount: 16), header.count >= 8 else { return false }
            var size = UInt64(header.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if size == 1, header.count == 16 { size = header[8..<16].reduce(0) { $0 << 8 | UInt64($1) } }
            switch type {
            case "moof": return true
            case "mdat": return false
            // go2rtc's header: the movie says fragments follow (`mvex`), even before the first one is written.
            case "moov": if moovHasFragments(file, at: offset, size: size) { return true }
            default: break
            }
            guard size >= 8 else { return false } // 0 = to the end of the file
            offset += size
        }
        return false
    }

    /// Whether the `moov` at `offset` holds an `mvex` box (the movie is extended by fragments). Reads only its children's
    /// headers: a prepared file's `moov` comes first and holds the sample tables, 1–1.5 MB per recorded hour, and this
    /// runs for every recording when the app starts and the history opens.
    private static func moovHasFragments(_ file: FileHandle, at offset: UInt64, size: UInt64) -> Bool {
        guard size > 8 else { return false }
        let end = offset + size
        var child = offset + 8
        for _ in 0..<64 where child + 8 <= end {
            try? file.seek(toOffset: child)
            guard let header = try? file.read(upToCount: 16), header.count >= 8 else { return false }
            if String(decoding: header[4..<8], as: UTF8.self) == "mvex" { return true }
            var length = UInt64(header.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
            if length == 1, header.count == 16 { length = header[8..<16].reduce(0) { $0 << 8 | UInt64($1) } }
            guard length >= 8 else { return false }
            child += length
        }
        return false
    }

    /// Temporary files a finalize leaves behind when the app is closed in the middle of it (its sound converted to
    /// .m4a, a half-written export): removed at launch. A file touched in the last 10 minutes is kept, in case another
    /// copy of the app is still writing it.
    static func removeAbandonedTemporaryFiles() {
        let directory = FileManager.default.temporaryDirectory
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        for file in files where ["m4a", "mp4"].contains(file.pathExtension) && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate,
                  modified < Date().addingTimeInterval(-600) else { continue }
            let megabytes = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0) / 1_000_000
            try? FileManager.default.removeItem(at: file)
            print("[rec] removed an abandoned temporary file \(file.lastPathComponent) (\(megabytes) MB)")
        }
    }

    /// Returns `false` when the file is already a regular MP4 with AAC sound.
    /// Throws (leaving the file untouched) when the sound cannot be converted.
    @discardableResult
    static func finalize(_ url: URL, progress: ProgressHandler? = nil) async throws -> Bool {
        let reporter = ProgressReporter(progress)
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw FinalizeError.noVideo }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        var audioIsAAC = false
        if let audioTrack { audioIsAAC = try await isAAC(audioTrack) }
        let fragmented = try await asset.load(.canContainFragments)
        if !fragmented, audioIsAAC { return false }
        let exportFrom = audioTrack != nil && !audioIsAAC ? soundShare : 0

        let composition = AVMutableComposition()
        var end = CMTime.zero
        for track in videoTracks {
            let range = try await track.load(.timeRange)
            guard let target = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try target.insertTimeRange(range, of: track, at: range.start)
            target.preferredTransform = try await track.load(.preferredTransform)
            end = max(end, range.end)
        }

        // Kept alive until the export ends: a track does not retain its asset.
        var converted: AVURLAsset?
        defer { if let converted { try? FileManager.default.removeItem(at: converted.url) } }
        if let audioTrack {
            let range = try await audioTrack.load(.timeRange)
            var source = audioTrack
            if !audioIsAAC {
                let m4a = AVURLAsset(url: try await transcodeToAAC(audioTrack, of: asset, progress: reporter.part(0, exportFrom)))
                converted = m4a
                guard let track = try await m4a.loadTracks(withMediaType: .audio).first else {
                    throw FinalizeError.failed(String(localized: "the sound wasn’t converted"))
                }
                source = track
            }
            let sourceRange = try await source.load(.timeRange)
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw FinalizeError.failed(String(localized: "couldn’t add the audio track"))
            }
            // The converted clip starts at zero; place it where the camera's sound started.
            try target.insertTimeRange(sourceRange, of: source, at: range.start)
        } else {
            try await addSilence(to: composition, until: end)
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw FinalizeError.failed(String(localized: "export is unavailable"))
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        session.shouldOptimizeForNetworkUse = true
        try await export(session, to: output, progress: reporter.part(exportFrom, 1))
        _ = try FileManager.default.replaceItemAt(url, withItemAt: output)
        reporter.report(1)
        return true
    }

    /// Passes a fraction on to the handler only when it grew by half a percent (the sound reports every buffer), so
    /// the bar never moves back. Thread-safe: the sound's queue and the export's watcher both report.
    final class ProgressReporter: @unchecked Sendable {
        private let handler: ProgressHandler?
        private let lock = NSLock()
        private var last = -1.0

        init(_ handler: ProgressHandler?) { self.handler = handler }

        func report(_ fraction: Double) {
            guard let handler, fraction.isFinite else { return }
            let value = min(1, max(0, fraction))
            lock.lock()
            guard value >= last + 0.005 || (value == 1 && last < 1) else {
                lock.unlock()
                return
            }
            last = value
            lock.unlock()
            handler(value)
        }

        /// A handler for one stage of the work that fills `from…to` of this one.
        func part(_ from: Double, _ to: Double) -> ProgressHandler? {
            guard handler != nil else { return nil }
            return { [self] in report(from + (to - from) * min(1, max(0, $0))) }
        }
    }

    /// Joins the parts of a recording into `output`, each at its own time (`placedAt`) since the first part's first
    /// frame (`startedAt` when that part got no video): the time a camera was away stays in the video as an empty stretch, so the training log (and the history's «jump to the
    /// exit») still lines up with the picture. A part that runs on past the next one's start (the camera switched:
    /// the old one is kept until the new one's first keyframe) ends there. Parts from two cameras may differ in size;
    /// the track keeps each one's own format. Each part is finalized first (AAC sound, not fragmented). A part without
    /// frames (go2rtc writes the header before the camera's first keyframe) or one that cannot be read is left out: the
    /// rest still make the video. Only the parts that went into it are deleted afterwards (other than `output`): one left
    /// out stays where it is. `output` may be one of the parts, or an empty file; if it is a part with frames that
    /// failed, nothing is joined (it would be lost under the result). Returns how many parts went into the video.
    /// `progress`: each part's finalize fills its share of the first 85 %, by size; the joined export the rest.
    static func join(_ segments: [RecordingSegment], startedAt: Date, into output: URL,
                     progress: ProgressHandler? = nil) async throws -> Int {
        let reporter = ProgressReporter(progress)
        let totalBytes = Double(max(1, segments.reduce(Int64(0)) { $0 + max($1.bytes, 1) }))
        var doneBytes = 0.0
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FinalizeError.failed(String(localized: "couldn’t join the recording"))
        }
        var assets: [AVURLAsset] = [] // a track does not retain its asset
        var parts: [(segment: RecordingSegment, video: AVAssetTrack, sound: AVAssetTrack?)] = []
        for segment in segments {
            let name = segment.url.lastPathComponent
            let share = Double(max(segment.bytes, 1)) / totalBytes * 0.85
            defer {
                doneBytes += share
                reporter.report(doneBytes)
            }
            do {
                guard try await hasFrames(segment.url) else {
                    print("[rec] \(name): no video, left out of the join")
                    continue
                }
                try await finalize(segment.url, progress: reporter.part(doneBytes, doneBytes + share))
                let asset = AVURLAsset(url: segment.url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw FinalizeError.noVideo }
                assets.append(asset)
                parts.append((segment, track, try await asset.loadTracks(withMediaType: .audio).first))
            } catch {
                if segment.url.standardizedFileURL == output.standardizedFileURL { throw error }
                print("[rec] \(name): left out of the join, kept (\(error.localizedDescription))")
            }
        }
        guard !parts.isEmpty else { throw FinalizeError.noVideo }

        // The video starts with the first part's first frame, as a recording in one part does; without that part the
        // wait from the start stays empty. The first part is `output` (its file keeps the recording's name): the
        // caller passes only parts that got bytes, so `segments.first` may be a later one.
        let first = parts[0].segment.url.standardizedFileURL == output.standardizedFileURL
        let origin = first ? parts[0].segment.placedAt : startedAt
        func time(_ segment: RecordingSegment) -> CMTime {
            CMTime(seconds: max(0, segment.placedAt.timeIntervalSince(origin)), preferredTimescale: 600)
        }
        // An empty track's time range is invalid, not zero.
        func end(_ track: AVMutableCompositionTrack) -> CMTime { track.segments.isEmpty ? .zero : track.timeRange.end }
        for (index, part) in parts.enumerated() {
            let range = try await part.video.load(.timeRange)
            let at = max(end(video), time(part.segment))
            // Up to where the next part begins.
            var length = range.duration
            if index + 1 < parts.count {
                let next = time(parts[index + 1].segment)
                if next > at { length = min(length, next - at) }
            }
            if at > end(video) {
                video.insertEmptyTimeRange(CMTimeRange(start: end(video), end: at))
            }
            try video.insertTimeRange(CMTimeRange(start: range.start, duration: length), of: part.video, at: at)
            if index == 0 { video.preferredTransform = try await part.video.load(.preferredTransform) }
            if let sound = part.sound {
                let soundRange = try await sound.load(.timeRange)
                let soundAt = max(end(audio), at + (soundRange.start - range.start))
                let soundEnd = min(soundRange.end, soundRange.start + (at + length - soundAt))
                if soundEnd > soundRange.start {
                    if soundAt > end(audio) {
                        audio.insertEmptyTimeRange(CMTimeRange(start: end(audio), end: soundAt))
                    }
                    try audio.insertTimeRange(CMTimeRange(start: soundRange.start, end: soundEnd), of: sound, at: soundAt)
                }
            }
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw FinalizeError.failed(String(localized: "export is unavailable"))
        }
        let joined = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        session.shouldOptimizeForNetworkUse = true
        try await export(session, to: joined, progress: reporter.part(0.85, 1))
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: joined)
        } else {
            try FileManager.default.moveItem(at: joined, to: output)
        }
        for part in parts where part.segment.url.standardizedFileURL != output.standardizedFileURL {
            try? FileManager.default.removeItem(at: part.segment.url)
        }
        withExtendedLifetime(assets) {}
        return parts.count
    }

    /// Whether the file has any video frames: `false` for a part that got only go2rtc's header (or no video track).
    /// Throws when the file cannot be read at all.
    private static func hasFrames(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return false }
        let range = try await track.load(.timeRange)
        withExtendedLifetime(asset) {}
        return range.duration.seconds > 0
    }

    /// `export(to:as:)` where the system has it (iOS 18, macOS 15), the old completion-style export before.
    private static func export(_ session: AVAssetExportSession, to output: URL, progress: ProgressHandler? = nil) async throws {
        nonisolated(unsafe) let session = session
        if #available(iOS 18, macOS 15, *) {
            let exporting = Task { try await session.export(to: output, as: .mp4) }
            let watcher = Task.detached { await watch(session, progress) { exporting.cancel() } }
            defer { watcher.cancel() }
            do {
                try await exporting.value
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw FinalizeError.failed(exporting.isCancelled ? String(localized: "the export stalled") : error.localizedDescription)
            }
        } else {
            #if os(iOS)
            let watcher = Task.detached { await watch(session, progress) { session.cancelExport() } }
            defer { watcher.cancel() }
            session.outputURL = output
            session.outputFileType = .mp4
            await session.export()
            guard session.status == .completed else {
                try? FileManager.default.removeItem(at: output)
                throw FinalizeError.failed(session.error?.localizedDescription ?? String(localized: "the export didn’t finish"))
            }
            #endif
        }
    }

    /// Reports the export's progress about twice a second until cancelled, and calls `stalled` when it has not moved
    /// for `stallLimit` × 2: the export then throws, and the recording stays as it was instead of «Готовим видео» for
    /// ever.
    private static func watch(_ session: AVAssetExportSession, _ report: ProgressHandler?,
                              stalled: @escaping @Sendable () -> Void) async {
        var last = -1.0
        var movedAt = Date()
        /// `false` once it is stuck.
        func note(_ fraction: Double) -> Bool {
            if fraction > last {
                last = fraction
                movedAt = Date()
                report?(fraction)
            } else if Date().timeIntervalSince(movedAt) > stallLimit * 2 {
                print("[rec] the export has not moved for \(Int(stallLimit * 2)) s at \(Int(last * 100)) %: cancelled")
                stalled()
                return false
            }
            return true
        }
        if #available(iOS 18, macOS 15, *) {
            for await state in session.states(updateInterval: 0.5) {
                if Task.isCancelled { return }
                // Before it starts there is no progress yet: a wait in the queue is not a stall.
                guard case .exporting(let progress) = state else {
                    movedAt = Date()
                    continue
                }
                if !note(progress.fractionCompleted) { return }
            }
        } else {
            while !Task.isCancelled {
                // The same on iOS 17: an export queued behind another (a leftover recording) is not stuck.
                if session.status == .waiting || session.status == .unknown {
                    movedAt = Date()
                } else if !note(Double(session.progress)) {
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static func isAAC(_ track: AVAssetTrack) async throws -> Bool {
        try await track.load(.formatDescriptions).contains { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }
    }

    /// Decodes the camera's sound (Opus, FLAC, …) and encodes it as AAC into a temporary .m4a, with silence for the
    /// pauses in it (see `SoundPauses`).
    private static func transcodeToAAC(_ track: AVAssetTrack, of asset: AVAsset, progress: ProgressHandler? = nil) async throws -> URL {
        let description = try await track.load(.formatDescriptions).first
        let sourceChannels = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
        let channels = sourceChannels >= 2 ? 2 : 1
        let sampleRate = 44_100
        let range = try await track.load(.timeRange)
        let reporter = ProgressReporter(progress)
        // How far into the sound a buffer starting at `time` is.
        let along: @Sendable (CMTime) -> Double = { time in
            range.duration.seconds > 0 ? (time - range.start).seconds / range.duration.seconds : 0
        }
        let pausesProgress = reporter.part(0, pausesShare)
        let pauses = try SoundPauses(in: track, of: asset) { pausesProgress?(along($0)) }
        let encodeProgress = reporter.part(pausesShare, 1)

        let reader = SoundReader(track: track, of: asset, range: range, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 2 ? 128_000 : 64_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard writer.startWriting() else {
            throw FinalizeError.failed(String(localized: "couldn’t read the sound: \(writer.error?.localizedDescription ?? "?")"))
        }
        guard let first = reader.next() else {
            writer.cancelWriting()
            if let error = reader.error {
                throw FinalizeError.failed(String(localized: "couldn’t read the sound: \(error.localizedDescription)"))
            }
            throw FinalizeError.failed(String(localized: "the audio track is empty"))
        }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(first.buffer))

        let queue = DispatchQueue(label: "su.comrade.waitingpaws.transcode", qos: .utility)
        // Reader, writer input and the loop state are only touched on `queue`, one callback at a time; `done` also by
        // the watchdog, under its lock.
        nonisolated(unsafe) let writerInput = input
        nonisolated(unsafe) let soundReader = reader
        let done = Once()
        let stalled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            nonisolated(unsafe) var placer = pauses
            nonisolated(unsafe) var pending = placer.place(first.buffer)
            let watchdog = Watchdog(limit: stallLimit) {
                if done.claim() { continuation.resume(returning: true) }
            }
            writerInput.requestMediaDataWhenReady(on: queue) {
                while !done.isClaimed, writerInput.isReadyForMoreMediaData {
                    if pending.isEmpty, let next = soundReader.next() {
                        watchdog.alive()
                        encodeProgress?(along(next.at))
                        pending = placer.place(next.buffer)
                    }
                    guard !pending.isEmpty, writerInput.append(pending.removeFirst()) else {
                        watchdog.stop()
                        if done.claim() {
                            writerInput.markAsFinished()
                            continuation.resume(returning: false)
                        }
                        return
                    }
                    // Hours of silence for a long pause are appended without a read: the conversion is alive meanwhile.
                    watchdog.alive()
                }
            }
        }
        if stalled {
            // The reader thread stays where it hung; the half-written sound goes.
            soundReader.cancel()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw FinalizeError.failed(String(localized: "reading the sound stalled"))
        }
        await writer.finishWriting()

        guard reader.error == nil, writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            let why = (reader.error ?? writer.error)?.localizedDescription ?? "?"
            throw FinalizeError.failed(String(localized: "couldn’t convert the sound: \(why)"))
        }
        return url
    }

    /// With no new sound for this long, the conversion is given up (an `AVAssetReader` that hangs never returns).
    static let stallLimit: TimeInterval = 60

    /// The camera's sound decoded, read in windows of 4 hours with a new reader for each: one `AVAssetReader` stops
    /// for good after 2³¹ samples of a track (12 h 25 min at 48 kHz) — `copyNextSampleBuffer` never returns. The night
    /// recording of 29 Oct (14.5 h, Opus) hung there on every try (found 2026-11-08). Each window's buffers are moved
    /// to follow on from the one before, so the sound runs on as from a single reader (pauses and all: `SoundPauses`
    /// places them on that timeline). Used on one queue only.
    final class SoundReader {
        static let window = CMTime(seconds: 4 * 3600, preferredTimescale: 600)

        private let track: AVAssetTrack
        private let asset: AVAsset
        private let range: CMTimeRange
        private let settings: [String: Any]
        /// Where the next window starts.
        private var start: CMTime
        private var reader: AVAssetReader?
        private var output: AVAssetReaderTrackOutput?
        /// Added to the current window's times; set by its first buffer.
        private var offset: CMTime?
        /// Where the last buffer handed out ends.
        private var end: CMTime?
        private(set) var error: Error?

        init(track: AVAssetTrack, of asset: AVAsset, range: CMTimeRange, settings: [String: Any]) {
            self.track = track
            self.asset = asset
            self.range = range
            self.settings = settings
            start = range.start
        }

        /// The next decoded buffer, and where it was in the track (for the progress); `nil` at the end or on an error.
        func next() -> (buffer: CMSampleBuffer, at: CMTime)? {
            while true {
                if output == nil, !openNextWindow() { return nil }
                guard let reader, let output else { return nil }
                if let buffer = output.copyNextSampleBuffer() {
                    let at = CMSampleBufferGetPresentationTimeStamp(buffer)
                    let offset = self.offset ?? (end.map { $0 - at } ?? .zero)
                    self.offset = offset
                    let placed = offset == .zero ? buffer : Self.moved(buffer, by: offset)
                    end = CMSampleBufferGetPresentationTimeStamp(placed) + CMSampleBufferGetDuration(placed)
                    return (placed, at)
                }
                if reader.status == .failed {
                    error = reader.error
                    return nil
                }
                self.reader = nil
                self.output = nil
            }
        }

        func cancel() { reader?.cancelReading() }

        private func openNextWindow() -> Bool {
            guard start < range.end else { return false }
            let windowEnd = min(range.end, start + Self.window)
            do {
                let reader = try AVAssetReader(asset: asset)
                // The whole sound when it fits in one window: exactly the reading it had before windows.
                if start != range.start || windowEnd != range.end {
                    reader.timeRange = CMTimeRange(start: start, end: windowEnd)
                }
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                output.alwaysCopiesSampleData = false
                reader.add(output)
                guard reader.startReading() else {
                    error = reader.error ?? FinalizeError.failed(String(localized: "couldn’t read the sound"))
                    return false
                }
                self.reader = reader
                self.output = output
                offset = nil
                start = windowEnd
                return true
            } catch {
                self.error = error
                return false
            }
        }

        /// `buffer` with every time moved by `offset`.
        static func moved(_ buffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer {
            guard var timings = try? buffer.sampleTimingInfos() else { return buffer }
            for i in timings.indices { timings[i].presentationTimeStamp = timings[i].presentationTimeStamp + offset }
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                                                        sampleTimingEntryCount: timings.count, sampleTimingArray: timings,
                                                        sampleBufferOut: &copy) == noErr, let copy else { return buffer }
            return copy
        }
    }

    /// A flag set once, from any thread: the first to `claim` it wins.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        var isClaimed: Bool { lock.withLock { claimed } }
        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }

    /// Calls `fire` once if `alive` is not called for `limit` seconds (checked every few seconds), until `stop`.
    final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        private var stopped = false

        init(limit: TimeInterval, fire: @escaping @Sendable () -> Void) {
            let check = min(5, limit / 2)
            Thread.detachNewThread { [self] in
                while true {
                    Thread.sleep(forTimeInterval: check)
                    let (quiet, over) = lock.withLock { (Date().timeIntervalSince(last), stopped) }
                    if over { return }
                    if quiet > limit {
                        fire()
                        return
                    }
                }
            }
        }

        func alive() { lock.withLock { last = Date() } }
        func stop() { lock.withLock { stopped = true } }
    }

    /// Puts back the pauses that decoding takes out of the camera's sound. Our go2rtc keeps a pause in the recording
    /// (packets the camera dropped, a reconnect) as a longer last packet before it, but a decoder gives every packet
    /// its own length and runs the sound on, and the encoder joins whatever it gets end to end: without this the sound
    /// after a pause would play ahead of the picture by the length of the pause.
    struct SoundPauses {
        /// Each pause on the decoded sound's timeline (from its start), and how long it is.
        private(set) var left: [(at: CMTime, length: CMTime)]
        private var origin: CMTime?   // where the decoded sound starts
        private var inserted = CMTime.zero

        /// Finds the pauses from the packet times of `track` (without decoding it): a packet longer than the usual
        /// length by 5 ms or more is followed by a pause.
        /// `reached`: the start of each buffer read, for the progress.
        init(in track: AVAssetTrack, of asset: AVAsset, reached: ((CMTime) -> Void)? = nil) throws {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            var packets: [(start: CMTime, duration: CMTime)] = []
            if reader.startReading() {
                while let buffer = output.copyNextSampleBuffer() {
                    reached?(CMSampleBufferGetPresentationTimeStamp(buffer))
                    let timings = (try? buffer.sampleTimingInfos()) ?? []
                    let count = CMSampleBufferGetNumSamples(buffer)
                    if timings.count == 1, count > 1, timings[0].duration.isNumeric { // one timing for packets of one length
                        for i in 0..<count {
                            packets.append((timings[0].presentationTimeStamp + CMTimeMultiply(timings[0].duration, multiplier: Int32(i)),
                                            timings[0].duration))
                        }
                    } else {
                        packets += timings.filter { $0.duration.isNumeric }.map { ($0.presentationTimeStamp, $0.duration) }
                    }
                }
            }
            self.init(packets: packets)
        }

        /// `packets`: start and duration of every packet, in order.
        init(packets: [(start: CMTime, duration: CMTime)]) {
            left = []
            // A camera sends packets of one length: the most common one.
            var counts: [Int64: (duration: CMTime, count: Int)] = [:]
            for packet in packets {
                let key = Int64((packet.duration.seconds * 1_000_000).rounded())
                counts[key] = (packet.duration, (counts[key]?.count ?? 0) + 1)
            }
            guard let usual = counts.values.max(by: { $0.count < $1.count })?.duration, let first = packets.first?.start else {
                return
            }
            var paused = CMTime.zero
            for packet in packets where packet.duration - usual >= CMTime(value: 5, timescale: 1000) {
                let length = packet.duration - usual
                left.append((at: packet.start + usual - first - paused, length: length))
                paused = paused + length
            }
        }

        /// `buffer` (the decoded sound, in order) as it goes to the encoder: split where a pause falls inside it, with
        /// silence for the pause, and moved later by the pauses so far.
        mutating func place(_ buffer: CMSampleBuffer) -> [CMSampleBuffer] {
            let origin = self.origin ?? CMSampleBufferGetPresentationTimeStamp(buffer)
            self.origin = origin
            guard let rate = Self.sampleRate(of: buffer) else { return [buffer] }
            var placed: [CMSampleBuffer] = []
            var rest = buffer
            while let pause = left.first {
                let frames = CMSampleBufferGetNumSamples(rest)
                let split = Int(((pause.at - (CMSampleBufferGetPresentationTimeStamp(rest) - origin)).seconds * rate).rounded())
                if split >= frames { break } // the pause comes after this buffer
                var tail = rest
                if split > 0, let head = Self.slice(rest, 0..<split), let after = Self.slice(rest, split..<frames) {
                    placed.append(moved(head))
                    tail = after
                }
                placed += Self.silence(like: rest, at: origin + pause.at + inserted, length: pause.length)
                inserted = inserted + pause.length
                left.removeFirst()
                rest = tail
            }
            placed.append(moved(rest))
            return placed
        }

        private func moved(_ buffer: CMSampleBuffer) -> CMSampleBuffer {
            guard inserted > .zero, var timings = try? buffer.sampleTimingInfos() else { return buffer }
            for i in timings.indices { timings[i].presentationTimeStamp = timings[i].presentationTimeStamp + inserted }
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                                                        sampleTimingEntryCount: timings.count, sampleTimingArray: timings,
                                                        sampleBufferOut: &copy) == noErr, let copy else { return buffer }
            return copy
        }

        private static func sampleRate(of buffer: CMSampleBuffer) -> Double? {
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate, rate > 0 else {
                return nil
            }
            return rate
        }

        private static func slice(_ buffer: CMSampleBuffer, _ range: Range<Int>) -> CMSampleBuffer? {
            var piece: CMSampleBuffer?
            guard CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                                                         sampleRange: CFRange(location: range.lowerBound, length: range.count),
                                                         sampleBufferOut: &piece) == noErr else { return nil }
            return piece
        }

        /// Silent buffers in the format of `buffer` (linear PCM) from `at` for `length`, in pieces of up to 1 s.
        private static func silence(like buffer: CMSampleBuffer, at: CMTime, length: CMTime) -> [CMSampleBuffer] {
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  stream.mSampleRate > 0, stream.mBytesPerFrame > 0 else { return [] }
            let rate = CMTimeScale(stream.mSampleRate)
            var frames = Int((length.seconds * stream.mSampleRate).rounded())
            var at = at
            var pieces: [CMSampleBuffer] = []
            while frames > 0 {
                let count = min(frames, Int(rate))
                let bytes = count * Int(stream.mBytesPerFrame)
                var block: CMBlockBuffer?
                var piece: CMSampleBuffer?
                guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                         blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                         offsetToData: 0, dataLength: bytes,
                                                         flags: kCMBlockBufferAssureMemoryNowFlag,
                                                         blockBufferOut: &block) == kCMBlockBufferNoErr,
                      let block,
                      CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                                 dataLength: bytes) == kCMBlockBufferNoErr,
                      CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                           formatDescription: format, sampleCount: count,
                                                                           presentationTimeStamp: at, packetDescriptions: nil,
                                                                           sampleBufferOut: &piece) == noErr,
                      let piece else { break }
                pieces.append(piece)
                frames -= count
                at = at + CMTime(value: CMTimeValue(count), timescale: rate)
            }
            return pieces
        }
    }

    /// Fills `[0, end)` with a looped silent clip.
    private static func addSilence(to composition: AVMutableComposition, until end: CMTime) async throws {
        let clip = AVURLAsset(url: try silentClip())
        guard let source = try await clip.loadTracks(withMediaType: .audio).first,
              let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FinalizeError.failed(String(localized: "couldn’t add the audio track"))
        }
        let range = try await source.load(.timeRange)
        guard range.duration > .zero else { throw FinalizeError.failed(String(localized: "empty audio track")) }
        var cursor = CMTime.zero
        while cursor < end {
            let length = min(range.duration, end - cursor)
            try target.insertTimeRange(CMTimeRange(start: range.start, duration: length), of: source, at: cursor)
            cursor = cursor + length
        }
    }

    /// One minute of silent mono AAC, encoded once per launch into the temporary directory.
    private static func silentClip() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence-60s.m4a")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate = 44_100.0
        let partial = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        do {
            // The file is closed (and the AAC trailer written) when `file` goes out of scope.
            let file = try AVAudioFile(forWriting: partial,
                                       settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                  AVSampleRateKey: sampleRate,
                                                  AVNumberOfChannelsKey: 1],
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            let frames = AVAudioFrameCount(sampleRate * 60)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
                  let samples = buffer.floatChannelData?[0] else {
                throw FinalizeError.failed(String(localized: "couldn’t prepare the silent track"))
            }
            buffer.frameLength = frames
            samples.update(repeating: 0, count: Int(frames))
            try file.write(from: buffer)
        }
        if (try? FileManager.default.moveItem(at: partial, to: url)) == nil {
            // Another finalize won the race; its clip is identical.
            try? FileManager.default.removeItem(at: partial)
        }
        return url
    }
}
