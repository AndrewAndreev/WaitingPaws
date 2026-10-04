import Foundation
import WaitingPawsCore

/// Mirrors everything written to stdout/stderr (Swift `print`, go2rtc logs) into
/// `Documents/Waiting Paws/Logs/<timestamp>.log` while still passing it to the console.
/// Keeps the last few files. Lets the log be read from the Files app or pulled with devicectl.
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

        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(readEnd, &buffer, buffer.count)
                if count <= 0 { break }
                buffer.withUnsafeBufferPointer { pointer in
                    _ = write(originalOut, pointer.baseAddress, count)
                    _ = fwrite(pointer.baseAddress, 1, count, file)
                }
            }
            fclose(file)
            close(originalErr)
        }
        thread.name = "wp.log-mirror"
        thread.qualityOfService = .utility
        thread.start()

        let header = "=== Waiting Paws launch \(Date()) ===\n"
        _ = header.withCString { fputs($0, stdout) }
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
