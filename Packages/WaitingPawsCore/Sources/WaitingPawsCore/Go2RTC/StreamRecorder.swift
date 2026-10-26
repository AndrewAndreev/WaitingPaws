import Foundation
import Observation

/// Records a go2rtc stream by downloading `/api/stream.mp4` straight into a file.
/// The resulting fragmented MP4 is playable by QuickTime / AVPlayer.
@Observable
public final class StreamRecorder: NSObject, URLSessionDataDelegate {
    public private(set) var isRecording = false
    public private(set) var startedAt: Date?
    /// When the first media fragment arrived: the file's video starts here. go2rtc sends it only with the camera's
    /// next keyframe, up to a whole GOP after `startedAt`.
    public private(set) var firstFragmentAt: Date?
    public private(set) var fileURL: URL?
    public private(set) var lastError: String?
    /// Bytes written so far. Not observed: it changes many times per second.
    public var bytesWritten: Int64 { bytesLock.withLock { bytesCount } }
    /// Called on the main thread when the stream ends without `stop()`: go2rtc lost the camera, or the server
    /// refused the stream (the reason, if any, is the argument; the file stays as written).
    @ObservationIgnored public var onEnded: ((String?) -> Void)?
    /// Called on the main thread when the first media fragment arrived (`firstFragmentAt`).
    @ObservationIgnored public var onFirstFragment: (() -> Void)?

    @ObservationIgnored private var bytesCount: Int64 = 0
    @ObservationIgnored private let bytesLock = NSLock()

    private var session: URLSession?
    private var task: URLSessionDataTask?
    /// Written from URLSession's delegate queue, opened and closed on the main thread: always under `handleLock`.
    @ObservationIgnored private var handle: FileHandle?
    @ObservationIgnored private let handleLock = NSLock()
    /// Read on URLSession's delegate queue only, reset under `handleLock` by `start`.
    @ObservationIgnored private var scanner = MP4FragmentScanner()
    private var stoppedByUser = false

    public override init() {
        super.init()
    }

    public func start(url: URL, authorization: String?, to fileURL: URL) throws {
        if isRecording { stop() }

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        var request = URLRequest(url: url)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }

        handleLock.withLock {
            self.handle = handle
            scanner = MP4FragmentScanner()
        }
        self.session = session
        self.fileURL = fileURL
        bytesLock.withLock { bytesCount = 0 }
        self.lastError = nil
        self.stoppedByUser = false
        self.startedAt = Date()
        self.firstFragmentAt = nil
        self.isRecording = true

        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    public func stop() {
        stoppedByUser = true
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        closeFile()
        isRecording = false
    }

    public func duration(at now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return now.timeIntervalSince(startedAt)
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            DispatchQueue.main.async { self.lastError = "HTTP \(http.statusCode)" }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var firstFragment = false
        let result: Result<Bool, Error> = handleLock.withLock {
            guard let handle else { return .success(false) }
            if !scanner.sawFragment { firstFragment = scanner.feed(data) }
            return Result { try handle.write(contentsOf: data); return true }
        }
        switch result {
        case .success(true):
            let count = Int64(data.count)
            bytesLock.withLock { bytesCount += count }
            if firstFragment {
                let now = Date()
                DispatchQueue.main.async {
                    // A task of an earlier `start` must not mark the current one.
                    guard dataTask === self.task, self.firstFragmentAt == nil else { return }
                    self.firstFragmentAt = now
                    self.onFirstFragment?()
                }
            }
        case .success(false):
            break
        case .failure(let error):
            DispatchQueue.main.async { self.lastError = error.localizedDescription }
        }
    }

    private func closeFile() {
        handleLock.withLock {
            try? handle?.close()
            handle = nil
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            // A task of an earlier `start` (stopped, then started again) must not end the current one.
            guard task === self.task else { return }
            if let error, !self.stoppedByUser, (error as NSError).code != NSURLErrorCancelled {
                self.lastError = error.localizedDescription
            }
            self.closeFile()
            self.task = nil
            self.isRecording = false
            if !self.stoppedByUser { self.onEnded?(self.lastError) }
        }
    }
}
