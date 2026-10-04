import Foundation
import WaitingPawsCore

/// Mirrors everything written to stdout/stderr (Swift `print`, go2rtc logs) into `Library/Caches/Logs/<timestamp>.log`
/// (`AppModel.logsDirectory`) while still passing it to the console. Keeps the last few files; the Mac shows the
/// folder in Settings → Диагностика, on an iPhone it can be pulled with devicectl. Passwords in URLs
/// (`rtsp://user:pass@…`) are masked before anything is written.
enum LogMirror {
    private static var started = false
    private static let keepFiles = 5

    static func start(directory: URL) {
        guard !started else { return }
        started = true

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune(directory)

        let stamp = SessionStore.fileStamp.string(from: Date())
        let fileURL = directory.appendingPathComponent("\(stamp).log")
        guard let file = fopen(fileURL.path, "a") else { return }
        setvbuf(file, nil, _IOLBF, 0)

        // Keep copies of the original descriptors so the console still receives output.
        let originalOut = dup(STDOUT_FILENO)
        let originalErr = dup(STDERR_FILENO)

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        let readEnd = fds[0]
        let writeEnd = fds[1]
        dup2(writeEnd, STDOUT_FILENO)
        dup2(writeEnd, STDERR_FILENO)
        close(writeEnd)
        setvbuf(stdout, nil, _IOLBF, 0)

        // Only the mirror thread uses the file from here on.
        nonisolated(unsafe) let logFile = file
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            var pending = Data()
            func emit(_ data: Data) {
                let clean = redacted(data)
                clean.withUnsafeBytes { pointer in
                    _ = write(originalOut, pointer.baseAddress, clean.count)
                    _ = fwrite(pointer.baseAddress, 1, clean.count, logFile)
                }
            }
            while true {
                let count = read(readEnd, &buffer, buffer.count)
                if count <= 0 { break }
                pending.append(contentsOf: buffer[0..<count])
                // Whole lines only, so a URL is never split between two reads.
                if let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) {
                    emit(pending[...lastNewline])
                    pending = Data(pending[pending.index(after: lastNewline)...])
                } else if pending.count > 64 * 1024 {
                    emit(pending)
                    pending.removeAll()
                }
            }
            if !pending.isEmpty { emit(pending) }
            fclose(logFile)
            close(originalErr)
        }
        thread.name = "wp.log-mirror"
        thread.qualityOfService = .utility
        thread.start()

        let header = "=== Waiting Paws launch \(Date()) ===\n"
        _ = header.withCString { fputs($0, stdout) }
    }

    /// `scheme://user:password@host` → `scheme://user:•••@host`.
    private static let credentials = try! NSRegularExpression(pattern: #"([A-Za-z][A-Za-z0-9+.-]*://[^\s:/@]+):[^\s/@]+@"#)

    private static func redacted(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("@") else { return data }
        let range = NSRange(text.startIndex..., in: text)
        let clean = credentials.stringByReplacingMatches(in: text, range: range, withTemplate: "$1:•••@")
        return Data(clean.utf8)
    }

    private static func prune(_ directory: URL) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(keepFiles - 1) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
