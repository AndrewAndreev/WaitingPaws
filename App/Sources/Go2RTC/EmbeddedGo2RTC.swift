import Foundation
import Observation
import WaitingPawsCore
#if canImport(Go2RTC)
import Go2RTC
#endif

/// Runs go2rtc inside the app process (built from `GoMobile/` with gomobile) and
/// exposes it on `http://127.0.0.1:11984/` exactly like an external server.
@MainActor
@Observable
final class EmbeddedGo2RTC {
    enum Status: Equatable {
        case idle
        case starting
        case running(version: String)
        case failed(String)
        /// The app was built without `Frameworks/Go2RTC.xcframework`.
        case unavailable

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// Non-standard port so a go2rtc running on the same Mac (default 1984) does not clash.
    static let apiPort = 11984
    static let webrtcPort = 11985
    static let baseURL = URL(string: "http://127.0.0.1:\(apiPort)/")!

    static var isAvailable: Bool {
        #if canImport(Go2RTC)
        return true
        #else
        return false
        #endif
    }

    private(set) var status: Status = .idle

    /// `Application Support/go2rtc/go2rtc.yaml` — go2rtc stores Xiaomi tokens and streams here.
    nonisolated static var configURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("go2rtc", isDirectory: true)
            .appendingPathComponent("go2rtc.yaml")
    }

    /// Written on first start; go2rtc patches this file later (tokens, streams), so it is never overwritten.
    static let defaultConfig = """
    # Waiting Paws embedded go2rtc. Listen addresses are enforced by the app on every launch.
    log:
      level: info

    """

    /// Inline config merged on top of the file at every launch: loopback only, RTSP server off.
    static let overrides = """
    {"api":{"listen":"127.0.0.1:\(apiPort)"},"rtsp":{"listen":""},"webrtc":{"listen":"127.0.0.1:\(webrtcPort)","candidates":["127.0.0.1:\(webrtcPort)"]}}
    """

    func start() async {
        switch status {
        case .starting, .running, .unavailable: return
        case .idle, .failed: break
        }
        status = .starting

        #if canImport(Go2RTC)
        // go2rtc only logs a failed bind, so make sure nobody else answers on our port first.
        if !MobileIsRunning(), await Self.isReachable() {
            status = .failed("Порт \(Self.apiPort) уже занят другим процессом (другой экземпляр приложения?)")
            return
        }
        let configURL = Self.configURL
        let task = Task.detached(priority: .userInitiated) { () throws -> String in
            try Self.ensureConfig(at: configURL)
            var error: NSError?
            if !MobileStart(configURL.path, Self.overrides, &error) {
                throw error ?? NSError(domain: "go2rtc", code: 1, userInfo: [NSLocalizedDescriptionKey: "go2rtc не запустился"])
            }
            return MobileVersion().components(separatedBy: "+").first ?? MobileVersion()
        }
        switch await task.result {
        case .success(let version):
            if await Self.waitUntilReachable() {
                status = .running(version: version)
            } else {
                status = .failed("go2rtc запустился, но API на 127.0.0.1:\(Self.apiPort) не отвечает")
            }
        case .failure(let error):
            status = .failed(error.localizedDescription)
        }
        #else
        status = .unavailable
        #endif
    }

    nonisolated private static func ensureConfig(at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try defaultConfig.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    nonisolated private static func isReachable() async -> Bool {
        let client = Go2RTCClient(server: Go2RTCServer(baseURL: baseURL))
        return (try? await client.version()) != nil
    }

    /// Polls `GET /api` for a couple of seconds after start.
    nonisolated private static func waitUntilReachable() async -> Bool {
        for _ in 0..<20 {
            if await isReachable() { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }
}
