import Foundation
import Observation
import WaitingPawsCore

enum PlayerMode: String, CaseIterable, Identifiable {
    case webrtc, mse, hls
    var id: String { rawValue }
    var title: String {
        switch self {
        case .webrtc: return String(localized: "WebRTC (lowest latency)")
        case .mse: return "MSE"
        case .hls: return String(localized: "HLS (fallback)")
        }
    }
    /// Mode string understood by go2rtc's `video-rtc.js`.
    var go2rtcModes: String {
        switch self {
        case .webrtc: return "webrtc,mse,hls,mjpeg"
        case .mse: return "mse,hls,mjpeg"
        case .hls: return "hls,mjpeg"
        }
    }
}

enum ConnectionMode: String, CaseIterable, Identifiable {
    /// go2rtc runs inside the app (default).
    case embedded
    /// A go2rtc server somewhere on the network.
    case external
    var id: String { rawValue }
    var title: String {
        switch self {
        case .embedded: return String(localized: "Built-in go2rtc")
        case .external: return String(localized: "Own go2rtc Server")
        }
    }
}

/// User preferences persisted in UserDefaults (the go2rtc password lives in the keychain).
@Observable
final class AppSettings {
    private static let defaults = UserDefaults.standard
    private enum Key {
        static let connectionMode = "connectionMode"
        static let serverURL = "serverURL"
        static let serverUsername = "serverUsername"
        static let password = "go2rtc.password"
        static let streamName = "streamName"
        static let cameraTitle = "cameraTitle"
        static let secondStreamName = "secondStreamName"
        static let secondCameraTitle = "secondCameraTitle"
        static let xiaomiAccountID = "xiaomiAccountID"
        static let xiaomiRegion = "xiaomiRegion"
        static let playerMode = "playerMode"
        static let audioEnabled = "audioEnabled"
        static let autoRecord = "autoRecord"
        static let saveToPhotos = "saveToPhotos"
        static let showPerformance = "showPerformance"
        static let shareWithIPhone = "shareWithIPhone"
        static let lanPassword = "go2rtc.lanPassword"
        static let withoutCamera = "withoutCamera"
        static let qualityResolutions = "qualityResolutions"
        static let cameraFraming = "cameraFraming"
        static let deviceName = "sync.deviceName"
        static let haptics = "haptics"
        static let notifications = "notifications"
    }

    var connectionMode: ConnectionMode { didSet { Self.defaults.set(connectionMode.rawValue, forKey: Key.connectionMode) } }
    var serverURLString: String { didSet { Self.defaults.set(serverURLString, forKey: Key.serverURL) } }
    var serverUsername: String { didSet { Self.defaults.set(serverUsername, forKey: Key.serverUsername) } }
    var serverPassword: String { didSet { KeychainStore.set(serverPassword, for: Key.password) } }
    var streamName: String { didSet { Self.defaults.set(streamName, forKey: Key.streamName) } }
    var cameraTitle: String { didSet { Self.defaults.set(cameraTitle, forKey: Key.cameraTitle) } }
    /// A second camera (another room): shown instead of the first one by the switcher, and recorded while it is.
    var secondStreamName: String { didSet { Self.defaults.set(secondStreamName, forKey: Key.secondStreamName) } }
    var secondCameraTitle: String { didSet { Self.defaults.set(secondCameraTitle, forKey: Key.secondCameraTitle) } }
    var xiaomiAccountID: String { didSet { Self.defaults.set(xiaomiAccountID, forKey: Key.xiaomiAccountID) } }
    var xiaomiRegion: XiaomiRegion { didSet { Self.defaults.set(xiaomiRegion.rawValue, forKey: Key.xiaomiRegion) } }
    /// Explicit player choice; `nil` means the best default for the connection mode.
    var playerModeOverride: PlayerMode? { didSet { Self.defaults.set(playerModeOverride?.rawValue, forKey: Key.playerMode) } }
    var audioEnabled: Bool { didSet { Self.defaults.set(audioEnabled, forKey: Key.audioEnabled) } }
    var autoRecord: Bool { didSet { Self.defaults.set(autoRecord, forKey: Key.autoRecord) } }
    /// Copy finished recordings to the Photos library.
    var saveToPhotos: Bool { didSet { Self.defaults.set(saveToPhotos, forKey: Key.saveToPhotos) } }
    /// Diagnostics overlay (CPU, memory, main-thread hangs) on the main screen.
    var showPerformance: Bool { didSet { Self.defaults.set(showPerformance, forKey: Key.showPerformance) } }
    /// Mac: let iPhones on the same network find this Mac, watch its camera and drive its training.
    /// Opens the embedded go2rtc API on the LAN (Basic auth) from the next launch.
    var shareWithIPhone: Bool { didSet { Self.defaults.set(shareWithIPhone, forKey: Key.shareWithIPhone) } }
    /// This device's name for the linked ones; empty = the system's (`SyncIdentity.systemName`).
    var deviceName: String { didSet { Self.defaults.set(deviceName, forKey: Key.deviceName) } }
    /// iPhone: a short vibration when a training's timer runs out — the exit's plan, the break, a condition's countdown,
    /// the quiet (`TrainingGlance`).
    var haptics: Bool { didSet { Self.defaults.set(haptics, forKey: Key.haptics) } }
    /// iPhone: the same moments as notifications while the app is not in front (`TrainingAlerts`); they vibrate with
    /// `haptics`, and make no sound.
    var notifications: Bool { didSet { Self.defaults.set(notifications, forKey: Key.notifications) } }
    /// The user chose «Продолжить без камеры»: timer, schedule and log only, the camera can be added later.
    var withoutCamera: Bool { didSet { Self.defaults.set(withoutCamera, forKey: Key.withoutCamera) } }
    /// What each quality level of a Mi Home camera really sent ("848x480"), by the camera's `did` and `subtype`:
    /// levels mean different things on different models (on the C302 SD and HD are both 480p).
    var qualityResolutions: [String: [String: String]] {
        didSet { Self.defaults.set(qualityResolutions, forKey: Key.qualityResolutions) }
    }
    /// iPhone: how the owner framed each camera's picture (zoom, the point in the middle, zoomed in or not), by stream
    /// name — `ZoomState.Memory.saved`.
    var cameraFraming: [String: [Double]] { didSet { Self.defaults.set(cameraFraming, forKey: Key.cameraFraming) } }

    /// Password of the embedded go2rtc for LAN clients (linked iPhones); generated once.
    /// Kept in the app's own (sandboxed) defaults, not the keychain: it only guards the video on the home
    /// network, and keychain items of an ad-hoc signed Mac build trigger an access prompt after every rebuild.
    var lanPassword: String {
        if let existing = Self.defaults.string(forKey: Key.lanPassword), !existing.isEmpty { return existing }
        return rotateLanPassword()
    }

    /// A new LAN password (an iPhone was forgotten: it must lose access to the video too).
    @discardableResult
    func rotateLanPassword() -> String {
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        Self.defaults.set(generated, forKey: Key.lanPassword)
        return generated
    }

    init() {
        let d = Self.defaults
        connectionMode = ConnectionMode(rawValue: d.string(forKey: Key.connectionMode) ?? "") ?? .embedded
        serverURLString = d.string(forKey: Key.serverURL) ?? ""
        serverUsername = d.string(forKey: Key.serverUsername) ?? ""
        serverPassword = KeychainStore.get(Key.password) ?? ""
        streamName = d.string(forKey: Key.streamName) ?? ""
        cameraTitle = d.string(forKey: Key.cameraTitle) ?? ""
        secondStreamName = d.string(forKey: Key.secondStreamName) ?? ""
        secondCameraTitle = d.string(forKey: Key.secondCameraTitle) ?? ""
        xiaomiAccountID = d.string(forKey: Key.xiaomiAccountID) ?? ""
        xiaomiRegion = XiaomiRegion(rawValue: d.string(forKey: Key.xiaomiRegion) ?? "") ?? .suggested
        playerModeOverride = PlayerMode(rawValue: d.string(forKey: Key.playerMode) ?? "")
        audioEnabled = d.object(forKey: Key.audioEnabled) as? Bool ?? false
        autoRecord = d.object(forKey: Key.autoRecord) as? Bool ?? true
        showPerformance = d.object(forKey: Key.showPerformance) as? Bool ?? false
        #if os(iOS)
        saveToPhotos = d.object(forKey: Key.saveToPhotos) as? Bool ?? true
        #else
        saveToPhotos = d.object(forKey: Key.saveToPhotos) as? Bool ?? false
        #endif
        shareWithIPhone = d.object(forKey: Key.shareWithIPhone) as? Bool ?? true
        deviceName = d.string(forKey: Key.deviceName) ?? ""
        haptics = d.object(forKey: Key.haptics) as? Bool ?? true
        notifications = d.object(forKey: Key.notifications) as? Bool ?? true
        withoutCamera = d.bool(forKey: Key.withoutCamera)
        qualityResolutions = d.dictionary(forKey: Key.qualityResolutions) as? [String: [String: String]] ?? [:]
        cameraFraming = d.dictionary(forKey: Key.cameraFraming) as? [String: [Double]] ?? [:]
    }

    /// What the other devices see this one as when linking.
    @MainActor var linkName: String {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? SyncIdentity.systemName : name
    }

    var server: Go2RTCServer? {
        switch connectionMode {
        case .embedded:
            return Go2RTCServer(baseURL: EmbeddedGo2RTC.baseURL)
        case .external:
            guard let url = Go2RTCServer.parse(serverURLString) else { return nil }
            return Go2RTCServer(baseURL: url, username: serverUsername, password: serverPassword)
        }
    }

    /// MSE is the safe default for the in-process server (WebRTC over loopback is not guaranteed in WebKit);
    /// WebRTC gives the lowest latency with a real server.
    var playerMode: PlayerMode {
        get {
            let mode = playerModeOverride ?? (connectionMode == .embedded ? .mse : .webrtc)
            // WebRTC inside WKWebView cannot reach the loopback server; never use it with the embedded go2rtc.
            return connectionMode == .embedded && mode == .webrtc ? .mse : mode
        }
        set { playerModeOverride = newValue }
    }

    /// Modes offered in Settings for the current connection mode.
    var availablePlayerModes: [PlayerMode] {
        connectionMode == .embedded ? [.mse, .hls] : PlayerMode.allCases
    }

    /// A camera is selected (the stream of a reachable go2rtc).
    var isConfigured: Bool { server != nil && !streamName.isEmpty }

    /// Past the first-launch setup: with a camera, or explicitly without one.
    var isSetUp: Bool { isConfigured || withoutCamera }

    var cameraDisplayName: String { cameraTitle.isEmpty ? streamName : cameraTitle }
    var hasSecondCamera: Bool { server != nil && !secondStreamName.isEmpty && secondStreamName != streamName }
    var secondCameraDisplayName: String { secondCameraTitle.isEmpty ? secondStreamName : secondCameraTitle }
}
