import Foundation
import Observation

/// Records a go2rtc stream by downloading `/api/stream.mp4` straight into a file.
/// The resulting fragmented MP4 is playable by QuickTime / AVPlayer.
@Observable
public final class StreamRecorder: NSObject, URLSessionDataDelegate {
    public private(set) var isRecording = false
    public private(set) var startedAt: Date?
    public private(set) var fileURL: URL?
    public private(set) var lastError: String?
    /// Bytes written so far. Not observed: it changes many times per second.
    public var bytesWritten: Int64 { bytesLock.withLock { bytesCount } }

    @ObservationIgnored private var bytesCount: Int64 = 0
    @ObservationIgnored private let bytesLock = NSLock()

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
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

        self.handle = handle
        self.session = session
        self.fileURL = fileURL
        bytesLock.withLock { bytesCount = 0 }
        self.lastError = nil
        self.stoppedByUser = false
        self.startedAt = Date()
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
        try? handle?.close()
        handle = nil
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
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            let count = Int64(data.count)
            bytesLock.withLock { bytesCount += count }
        } catch {
            DispatchQueue.main.async { self.lastError = error.localizedDescription }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            if let error, !self.stoppedByUser, (error as NSError).code != NSURLErrorCancelled {
                self.lastError = error.localizedDescription
            }
            try? self.handle?.close()
            self.handle = nil
            self.task = nil
            self.isRecording = false
        }
    }
}
