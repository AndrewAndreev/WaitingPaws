import AVFoundation
import Foundation

/// Turns a finished go2rtc recording into a file other apps treat as an ordinary video.
///
/// go2rtc writes fragmented MP4 with the camera's sound as is: Opus, or FLAC made from PCMA/PCMU
/// (it cannot produce AAC without ffmpeg). Photos indexes fragmented MP4 poorly and, like most players,
/// only accepts AAC sound in MP4; Telegram sends a video without an audio track as a GIF. So the video
/// is remuxed in place without re-encoding, the sound is converted to AAC, and a silent AAC track is
/// added when the camera gave no sound at all.
enum RecordingFinalizer {
    enum FinalizeError: LocalizedError {
        case noVideo
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: return "в файле нет видео"
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
                    throw FinalizeError.failed("звук не перекодировался")
                }
                source = track
            }
            let sourceRange = try await source.load(.timeRange)
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw FinalizeError.failed("не удалось добавить звуковую дорожку")
            }
            // The converted clip starts at zero; place it where the camera's sound started.
            try target.insertTimeRange(sourceRange, of: source, at: range.start)
        } else {
            try await addSilence(to: composition, until: end)
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw FinalizeError.failed("экспорт недоступен")
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw FinalizeError.failed(session.error?.localizedDescription ?? "экспорт не завершился")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: output)
        return true
    }

    private static func isAAC(_ track: AVAssetTrack) async throws -> Bool {
        try await track.load(.formatDescriptions).contains { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }
    }

    /// Decodes the camera's sound (Opus, FLAC, …) and encodes it as AAC into a temporary .m4a.
    private static func transcodeToAAC(_ track: AVAssetTrack, of asset: AVAsset) async throws -> URL {
        let description = try await track.load(.formatDescriptions).first
        let sourceChannels = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
        let channels = sourceChannels >= 2 ? 2 : 1
        let sampleRate = 44_100

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
            throw FinalizeError.failed("не удалось прочитать звук: \((reader.error ?? writer.error)?.localizedDescription ?? "?")")
        }
        guard let first = output.copyNextSampleBuffer() else {
            writer.cancelWriting()
            throw FinalizeError.failed("звуковая дорожка пустая")
        }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(first))

        let queue = DispatchQueue(label: "su.comrade.waitingpaws.transcode")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var pending: CMSampleBuffer? = first
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while !finished, input.isReadyForMoreMediaData {
                    guard let buffer = pending ?? output.copyNextSampleBuffer(), input.append(buffer) else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    pending = nil
                }
            }
        }
        await writer.finishWriting()

        guard reader.status != .failed, writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw FinalizeError.failed("не удалось перекодировать звук: \((reader.error ?? writer.error)?.localizedDescription ?? "?")")
        }
        return url
    }

    /// Fills `[0, end)` with a looped silent clip.
    private static func addSilence(to composition: AVMutableComposition, until end: CMTime) async throws {
        let clip = AVURLAsset(url: try silentClip())
        guard let source = try await clip.loadTracks(withMediaType: .audio).first,
              let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FinalizeError.failed("не удалось добавить звуковую дорожку")
        }
        let range = try await source.load(.timeRange)
        guard range.duration > .zero else { throw FinalizeError.failed("пустая звуковая дорожка") }
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
                throw FinalizeError.failed("не удалось подготовить тишину")
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
