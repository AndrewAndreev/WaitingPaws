#if os(macOS) && DEBUG
import AppKit
import AVFoundation
import CoreText
import WaitingPawsCore

/// `--demo-history-videos`: the sample trainings of `DemoData` with real (generated) video files, plus two
/// recordings without a training. Everything lives in its own temp folder and in memory, so neither the user's
/// history nor the preview history other windows use is touched.
struct MacHistoryDemo {
    var records: [TrainingRecord]
    var clips: [RecordingClip]
    let folder: URL

    func videoURL(for record: TrainingRecord) -> URL? {
        guard let name = record.recordingFileName else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    mutating func delete(_ record: TrainingRecord, includingRecording: Bool) {
        records.removeAll { $0.id == record.id }
        guard let url = videoURL(for: record) else { return }
        if includingRecording {
            try? FileManager.default.removeItem(at: url)
        } else {
            clips.append(RecordingClip(url: url, date: record.recordingStartDate))
            clips.sort { $0.date > $1.date }
        }
    }

    mutating func delete(_ clip: RecordingClip) {
        try? FileManager.default.removeItem(at: clip.url)
        clips.removeAll { $0.id == clip.id }
    }

    mutating func deleteAll() {
        for record in records { if let url = videoURL(for: record) { try? FileManager.default.removeItem(at: url) } }
        for clip in clips { try? FileManager.default.removeItem(at: clip.url) }
        records = []
        clips = []
    }

    /// Builds the sample (videos are generated once and reused by later launches).
    static func make() async -> MacHistoryDemo {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WaitingPawsHistoryDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let background = DemoData.cameraImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)

        var records = DemoData.history()
        var jobs: [(URL, Date, TimeInterval)] = []
        // Videos for the newer trainings; 20.09 and older stay log-only.
        for index in records.indices where index < 5 && index != 2 {
            let record = records[index]
            let name = "\(SessionStore.fileStamp.string(from: record.startedAt))-trenirovka.mp4"
            records[index].recordingFileName = name
            jobs.append((folder.appendingPathComponent(name), record.startedAt, record.duration))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var clips: [RecordingClip] = []
        for (start, length) in [("2026-10-01 21:14", 728.0), ("2026-09-27 09:02", 221.0)] {
            let date = formatter.date(from: start)!
            let url = folder.appendingPathComponent("\(SessionStore.fileStamp.string(from: date))-zapis.mp4")
            clips.append(RecordingClip(url: url, date: date))
            jobs.append((url, date, length))
        }

        let pending = jobs.filter { !FileManager.default.fileExists(atPath: $0.0.path) }
        await Task.detached(priority: .userInitiated) {
            for (url, start, length) in pending {
                do {
                    try await writeVideo(to: url, start: start, duration: length, background: background)
                } catch {
                    print("[history demo] \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }.value
        return MacHistoryDemo(records: records, clips: clips.sorted { $0.date > $1.date }, folder: folder)
    }

    /// A camera-like H.264 video: the still (or a plain room with the dog somewhere else each time), daylight or
    /// lamp light by the hour, a ticking timestamp; one frame every 2 s.
    private static func writeVideo(to url: URL, start: Date, duration: TimeInterval, background: CGImage?) async throws {
        let width = 640, height = 360
        let partial = url.deletingLastPathComponent().appendingPathComponent("partial-" + url.lastPathComponent)
        try? FileManager.default.removeItem(at: partial)
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy/MM/dd HH:mm:ss"
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 13, nil)
        let space = CGColorSpaceCreateDeviceRGB()
        let hour = Calendar.current.component(.hour, from: start)
        let light = hour < 16 ? CGColor(red: 0.85, green: 0.93, blue: 1, alpha: 0.16) : CGColor(red: 1, green: 0.55, blue: 0.15, alpha: 0.14)
        let spot = Int(start.timeIntervalSince1970 / 60) % 5
        let dog = CGPoint(x: 90 + CGFloat(spot) * 105, y: 46 + CGFloat(spot % 2) * 24)

        var second = 0
        while TimeInterval(second) <= duration {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                       bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                if let background {
                    context.draw(background, in: aspectFill(CGSize(width: background.width, height: background.height), in: bounds))
                } else {
                    context.setFillColor(CGColor(red: 0.36, green: 0.34, blue: 0.31, alpha: 1))
                    context.fill(bounds)
                    context.setFillColor(CGColor(red: 0.27, green: 0.25, blue: 0.23, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: width, height: 120))
                    context.setFillColor(CGColor(red: 0.45, green: 0.40, blue: 0.34, alpha: 1))
                    context.fill(CGRect(x: 270, y: 120, width: 100, height: 190))
                    drawDog(in: context, at: dog, facingLeft: spot >= 3)
                }
                context.setFillColor(light)
                context.fill(bounds)
                let text = NSAttributedString(string: stamp.string(from: start.addingTimeInterval(TimeInterval(second))), attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.85),
                ])
                context.textPosition = CGPoint(x: 12, y: CGFloat(height) - 24)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(second), timescale: 1))
            second += 2
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        try FileManager.default.moveItem(at: partial, to: url)
    }

    /// A lying dog, ~150 × 60 px, drawn around `origin` (bottom-left based coordinates).
    private static func drawDog(in context: CGContext, at origin: CGPoint, facingLeft: Bool) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        if facingLeft { context.scaleBy(x: -1, y: 1) }
        context.setFillColor(CGColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 0.35))
        context.fillEllipse(in: CGRect(x: -58, y: -8, width: 140, height: 18))
        context.setFillColor(CGColor(red: 0.43, green: 0.29, blue: 0.18, alpha: 1))
        context.fillEllipse(in: CGRect(x: -78, y: 6, width: 30, height: 10))
        context.setFillColor(CGColor(red: 0.69, green: 0.50, blue: 0.32, alpha: 1))
        context.fillEllipse(in: CGRect(x: -52, y: -2, width: 104, height: 40))
        context.fillEllipse(in: CGRect(x: 34, y: 14, width: 38, height: 34))
        context.fillEllipse(in: CGRect(x: 60, y: 16, width: 24, height: 16))
        context.setFillColor(CGColor(red: 0.43, green: 0.29, blue: 0.18, alpha: 1))
        context.fillEllipse(in: CGRect(x: 38, y: 26, width: 14, height: 24))
        context.fillEllipse(in: CGRect(x: 78, y: 22, width: 8, height: 7))
        context.restoreGState()
    }

    private static func aspectFill(_ size: CGSize, in bounds: CGRect) -> CGRect {
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
}
#endif
