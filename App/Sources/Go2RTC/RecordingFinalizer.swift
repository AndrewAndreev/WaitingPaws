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
            case .noVideo: return String(localized: "в файле нет видео")
            case .failed(let why): return why
            }
        }
    }

    /// Returns `false` when the file is already a regular MP4 with AAC sound.
    /// Throws (leaving the file untouched) when the sound cannot be converted.
    @discardableResult
    static func finalize(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw FinalizeError.noVideo }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        var audioIsAAC = false
        if let audioTrack { audioIsAAC = try await isAAC(audioTrack) }
        let fragmented = try await asset.load(.canContainFragments)
        if !fragmented, audioIsAAC { return false }

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
                let m4a = AVURLAsset(url: try await transcodeToAAC(audioTrack, of: asset))
                converted = m4a
                guard let track = try await m4a.loadTracks(withMediaType: .audio).first else {
                    throw FinalizeError.failed(String(localized: "звук не перекодировался"))
                }
                source = track
            }
            let sourceRange = try await source.load(.timeRange)
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw FinalizeError.failed(String(localized: "не удалось добавить звуковую дорожку"))
            }
            // The converted clip starts at zero; place it where the camera's sound started.
            try target.insertTimeRange(sourceRange, of: source, at: range.start)
        } else {
            try await addSilence(to: composition, until: end)
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw FinalizeError.failed(String(localized: "экспорт недоступен"))
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        session.shouldOptimizeForNetworkUse = true
        try await export(session, to: output)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: output)
        return true
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
    static func join(_ segments: [RecordingSegment], startedAt: Date, into output: URL) async throws -> Int {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FinalizeError.failed(String(localized: "не удалось склеить запись"))
        }
        var assets: [AVURLAsset] = [] // a track does not retain its asset
        var parts: [(segment: RecordingSegment, video: AVAssetTrack, sound: AVAssetTrack?)] = []
        for segment in segments {
            let name = segment.url.lastPathComponent
            do {
                guard try await hasFrames(segment.url) else {
                    print("[rec] \(name): no video, left out of the join")
                    continue
                }
                try await finalize(segment.url)
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
            throw FinalizeError.failed(String(localized: "экспорт недоступен"))
        }
        let joined = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        session.shouldOptimizeForNetworkUse = true
        try await export(session, to: joined)
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
    private static func export(_ session: AVAssetExportSession, to output: URL) async throws {
        #if os(macOS)
        do {
            try await session.export(to: output, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw FinalizeError.failed(error.localizedDescription)
        }
        #else
        if #available(iOS 18, *) {
            do {
                try await session.export(to: output, as: .mp4)
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw FinalizeError.failed(error.localizedDescription)
            }
        } else {
            session.outputURL = output
            session.outputFileType = .mp4
            await session.export()
            guard session.status == .completed else {
                try? FileManager.default.removeItem(at: output)
                throw FinalizeError.failed(session.error?.localizedDescription ?? String(localized: "экспорт не завершился"))
            }
        }
        #endif
    }

    private static func isAAC(_ track: AVAssetTrack) async throws -> Bool {
        try await track.load(.formatDescriptions).contains { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }
    }

    /// Decodes the camera's sound (Opus, FLAC, …) and encodes it as AAC into a temporary .m4a, with silence for the
    /// pauses in it (see `SoundPauses`).
    private static func transcodeToAAC(_ track: AVAssetTrack, of asset: AVAsset) async throws -> URL {
        let description = try await track.load(.formatDescriptions).first
        let sourceChannels = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
        let channels = sourceChannels >= 2 ? 2 : 1
        let sampleRate = 44_100
        let pauses = try SoundPauses(in: track, of: asset)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

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

        guard reader.startReading(), writer.startWriting() else {
            let why = (reader.error ?? writer.error)?.localizedDescription ?? "?"
            throw FinalizeError.failed(String(localized: "не удалось прочитать звук: \(why)"))
        }
        guard let first = output.copyNextSampleBuffer() else {
            writer.cancelWriting()
            throw FinalizeError.failed(String(localized: "звуковая дорожка пустая"))
        }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(first))

        let queue = DispatchQueue(label: "su.comrade.waitingpaws.transcode")
        // Reader output, writer input and the loop state are only touched on `queue`, one callback at a time.
        nonisolated(unsafe) let writerInput = input
        nonisolated(unsafe) let readerOutput = output
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            nonisolated(unsafe) var placer = pauses
            nonisolated(unsafe) var pending = placer.place(first)
            nonisolated(unsafe) var finished = false
            writerInput.requestMediaDataWhenReady(on: queue) {
                while !finished, writerInput.isReadyForMoreMediaData {
                    if pending.isEmpty, let next = readerOutput.copyNextSampleBuffer() {
                        pending = placer.place(next)
                    }
                    guard !pending.isEmpty, writerInput.append(pending.removeFirst()) else {
                        finished = true
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
        await writer.finishWriting()

        guard reader.status != .failed, writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            let why = (reader.error ?? writer.error)?.localizedDescription ?? "?"
            throw FinalizeError.failed(String(localized: "не удалось перекодировать звук: \(why)"))
        }
        return url
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
        init(in track: AVAssetTrack, of asset: AVAsset) throws {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            var packets: [(start: CMTime, duration: CMTime)] = []
            if reader.startReading() {
                while let buffer = output.copyNextSampleBuffer() {
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
            throw FinalizeError.failed(String(localized: "не удалось добавить звуковую дорожку"))
        }
        let range = try await source.load(.timeRange)
        guard range.duration > .zero else { throw FinalizeError.failed(String(localized: "пустая звуковая дорожка")) }
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
                throw FinalizeError.failed(String(localized: "не удалось подготовить тишину"))
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
