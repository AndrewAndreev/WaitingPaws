import Foundation
import Observation
import WaitingPawsCore
#if canImport(Go2RTC)
import Go2RTC
#endif

/// Runs go2rtc inside the app process (built from `GoMobile/` with gomobile) and
/// exposes it on `http://127.0.0.1:11984/` (or the next free port) exactly like an external server.
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
    nonisolated static let preferredAPIPort = 11984
    /// The ports actually used: 11984/11985, or the next free pair when another process holds them
    /// (typically Waiting Paws in the iOS simulator on the same Mac — they share 127.0.0.1).
    nonisolated(unsafe) private(set) static var apiPort = preferredAPIPort
    nonisolated(unsafe) private(set) static var webrtcPort = preferredAPIPort + 1
    nonisolated static var baseURL: URL { URL(string: "http://127.0.0.1:\(apiPort)/")! }
    /// go2rtc was started in this process (`closeCameraSessions` has something to close).
    nonisolated(unsafe) private static var goStarted = false

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
    nonisolated static let defaultConfig = """
    # Waiting Paws embedded go2rtc. Listen addresses are enforced by the app on every launch.
    log:
      level: info

    """

    /// Basic-auth user for LAN clients (the iPhone linked to this Mac).
    nonisolated static let lanUsername = "waitingpaws"

    /// Inline config merged on top of the file at every launch: loopback only, RTSP server off.
    /// With `lanPassword` the API also listens on the LAN; go2rtc skips auth for loopback requests
    /// (`local_auth: false`), so the app itself keeps talking to 127.0.0.1 without credentials.
    nonisolated static func overrides(lanPassword: String?) -> String {
        let api: String
        if let lanPassword {
            api = #"{"listen":":\#(apiPort)","username":"\#(lanUsername)","password":"\#(lanPassword)"}"#
        } else {
            api = #"{"listen":"127.0.0.1:\#(apiPort)"}"#
        }
        return #"{"api":\#(api),"rtsp":{"listen":""},"webrtc":{"listen":"127.0.0.1:\#(webrtcPort)","candidates":["127.0.0.1:\#(webrtcPort)"]}}"#
    }

    /// Whether the API listens on the LAN (decided at start; go2rtc cannot be restarted in-process).
    private(set) var lanEnabled = false

    func start(lanPassword: String? = nil) async {
        switch status {
        case .starting, .running, .unavailable: return
        case .idle, .failed: break
        }
        status = .starting

        #if canImport(Go2RTC)
        let configURL = Self.configURL
        lanEnabled = lanPassword != nil
        // Everything that calls into Go runs here, off the main thread: the first call waits for the Go runtime
        // to come up, which took 2–4 s on an iPhone run from Xcode (the UI stood still until go2rtc started).
        let task = Task.detached(priority: .userInitiated) { () throws -> String in
            // go2rtc only logs a failed bind, so pick ports nobody holds before starting it.
            if !MobileIsRunning() {
                guard let ports = Self.freePorts(lan: lanPassword != nil) else {
                    throw NSError(domain: "go2rtc", code: 2, userInfo: [NSLocalizedDescriptionKey: String(
                        localized: "Ports \(Self.preferredAPIPort)–\(Self.preferredAPIPort + 29) are taken by other apps — go2rtc has nowhere to run.")])
                }
                Self.apiPort = ports.api
                Self.webrtcPort = ports.webrtc
                if ports.api != Self.preferredAPIPort {
                    print("[go2rtc] port \(Self.preferredAPIPort) is taken (Waiting Paws in the simulator?), using \(ports.api)")
                }
            }
            try Self.ensureConfig(at: configURL)
            // go2rtc's log lines in local time like the app's own (on iOS Go cannot read the zone and wrote UTC).
            MobileSetTimeZone(TimeZone.current.identifier, TimeZone.current.secondsFromGMT())
            var error: NSError?
            Self.goStarted = true
            if !MobileStart(configURL.path, Self.overrides(lanPassword: lanPassword), &error) {
                throw error ?? NSError(domain: "go2rtc", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "go2rtc didn’t start")])
            }
            return MobileVersion().components(separatedBy: "+").first ?? MobileVersion()
        }
        switch await task.result {
        case .success(let version):
            if await Self.waitUntilReachable() {
                status = .running(version: version)
            } else {
                status = .failed(String(localized: "go2rtc started, but its API at 127.0.0.1:\(Self.apiPort) doesn’t respond"))
            }
        case .failure(let error):
            status = .failed(error.localizedDescription)
        }
        #else
        status = .unavailable
        #endif
    }

    /// Called when the app is active again. iOS closes the listening sockets of a suspended app; go2rtc keeps
    /// running, so only the API listener is opened again. Returns true when it had to (players reconnect).
    @discardableResult
    func recoverIfNeeded() async -> Bool {
        #if canImport(Go2RTC)
        guard status.isRunning, !(await Self.isReachable()) else { return false }
        let address = lanEnabled ? ":\(Self.apiPort)" : "127.0.0.1:\(Self.apiPort)"
        var error: NSError?
        if MobileRelisten(address, &error) {
            print("[go2rtc] API listener reopened on \(address)")
        } else {
            print("[go2rtc] reopening \(address) failed: \(error?.localizedDescription ?? "?")")
        }
        if await Self.waitUntilReachable() { return true }
        status = .failed(String(localized: "go2rtc stopped responding. Restart the app."))
        return false
        #else
        return false
        #endif
    }

    /// The app is quitting: every camera with an open session is told it is over. A camera serves one session at a
    /// time, and one left by a process that is gone made the next launch wait: connected, then no video for 15 s or
    /// "can't send command". A few datagrams, no waiting for answers; the short pause lets the log mirror write the
    /// lines before the process ends.
    nonisolated static func closeCameraSessions() {
        #if canImport(Go2RTC)
        guard goStarted, MobileIsRunning() else { return } // never wake the Go runtime just to quit
        let count = MobileCloseCameraSessions()
        print("[app] quitting: \(count) camera session(s) closed")
        Thread.sleep(forTimeInterval: 0.1)
        #endif
    }

    /// A new Basic-auth password for LAN clients, effective at once (an iPhone was forgotten).
    func setLANPassword(_ password: String) {
        #if canImport(Go2RTC)
        guard lanEnabled else { return }
        MobileSetLANPassword(Self.lanUsername, password)
        #endif
    }

    /// First pair (API, WebRTC) from 11984 up that can be bound right now. A real bind, not an HTTP probe:
    /// any process on the port counts, not only another go2rtc.
    nonisolated private static func freePorts(lan: Bool) -> (api: Int, webrtc: Int)? {
        for api in stride(from: preferredAPIPort, to: preferredAPIPort + 30, by: 2) {
            if canBind(api, anyAddress: lan), canBind(api + 1, anyAddress: false) { return (api, api + 1) }
        }
        return nil
    }

    nonisolated private static func canBind(_ port: Int, anyAddress: Bool) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = anyAddress ? INADDR_ANY.bigEndian : UInt32(0x7F00_0001).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
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
