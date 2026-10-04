import Foundation
import Observation
import WaitingPawsCore

enum PlayerMode: String, CaseIterable, Identifiable {
    case webrtc, mse, hls
    var id: String { rawValue }
    var title: String {
        switch self {
        case .webrtc: return "WebRTC (минимальная задержка)"
        case .mse: return "MSE"
        case .hls: return "HLS (запасной)"
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
        case .embedded: return "Встроенный go2rtc"
        case .external: return "Свой сервер go2rtc"
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
        static let xiaomiAccountID = "xiaomiAccountID"
        static let xiaomiRegion = "xiaomiRegion"
        static let playerMode = "playerMode"
        static let audioEnabled = "audioEnabled"
        static let autoRecord = "autoRecord"
        static let autoFinish = "autoFinishAfterLastBreak"
        static let saveToPhotos = "saveToPhotos"
        static let showPerformance = "showPerformance"
        static let lastPlanText = "lastPlanText"
    }

    var connectionMode: ConnectionMode { didSet { Self.defaults.set(connectionMode.rawValue, forKey: Key.connectionMode) } }
    var serverURLString: String { didSet { Self.defaults.set(serverURLString, forKey: Key.serverURL) } }
    var serverUsername: String { didSet { Self.defaults.set(serverUsername, forKey: Key.serverUsername) } }
    var serverPassword: String { didSet { KeychainStore.set(serverPassword, for: Key.password) } }
    var streamName: String { didSet { Self.defaults.set(streamName, forKey: Key.streamName) } }
    var cameraTitle: String { didSet { Self.defaults.set(cameraTitle, forKey: Key.cameraTitle) } }
    var xiaomiAccountID: String { didSet { Self.defaults.set(xiaomiAccountID, forKey: Key.xiaomiAccountID) } }
    var xiaomiRegion: XiaomiRegion { didSet { Self.defaults.set(xiaomiRegion.rawValue, forKey: Key.xiaomiRegion) } }
    /// Explicit player choice; `nil` means the best default for the connection mode.
    var playerModeOverride: PlayerMode? { didSet { Self.defaults.set(playerModeOverride?.rawValue, forKey: Key.playerMode) } }
    var audioEnabled: Bool { didSet { Self.defaults.set(audioEnabled, forKey: Key.audioEnabled) } }
    var autoRecord: Bool { didSet { Self.defaults.set(autoRecord, forKey: Key.autoRecord) } }
    var autoFinishAfterLastBreak: Bool { didSet { Self.defaults.set(autoFinishAfterLastBreak, forKey: Key.autoFinish) } }
    /// Copy finished recordings to the Photos library.
    var saveToPhotos: Bool { didSet { Self.defaults.set(saveToPhotos, forKey: Key.saveToPhotos) } }
    /// Diagnostics overlay (CPU, memory, main-thread hangs) on the main screen.
    var showPerformance: Bool { didSet { Self.defaults.set(showPerformance, forKey: Key.showPerformance) } }
    var lastPlanText: String { didSet { Self.defaults.set(lastPlanText, forKey: Key.lastPlanText) } }

    init() {
        let d = Self.defaults
        connectionMode = ConnectionMode(rawValue: d.string(forKey: Key.connectionMode) ?? "") ?? .embedded
        serverURLString = d.string(forKey: Key.serverURL) ?? ""
        serverUsername = d.string(forKey: Key.serverUsername) ?? ""
        serverPassword = KeychainStore.get(Key.password) ?? ""
        streamName = d.string(forKey: Key.streamName) ?? ""
        cameraTitle = d.string(forKey: Key.cameraTitle) ?? ""
        xiaomiAccountID = d.string(forKey: Key.xiaomiAccountID) ?? ""
        xiaomiRegion = XiaomiRegion(rawValue: d.string(forKey: Key.xiaomiRegion) ?? "") ?? .ru
        playerModeOverride = PlayerMode(rawValue: d.string(forKey: Key.playerMode) ?? "")
        audioEnabled = d.object(forKey: Key.audioEnabled) as? Bool ?? false
        autoRecord = d.object(forKey: Key.autoRecord) as? Bool ?? true
        autoFinishAfterLastBreak = d.object(forKey: Key.autoFinish) as? Bool ?? true
        showPerformance = d.object(forKey: Key.showPerformance) as? Bool ?? false
        #if os(iOS)
        saveToPhotos = d.object(forKey: Key.saveToPhotos) as? Bool ?? true
        #else
        saveToPhotos = d.object(forKey: Key.saveToPhotos) as? Bool ?? false
        #endif
        lastPlanText = d.string(forKey: Key.lastPlanText) ?? ""
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

    var isConfigured: Bool { server != nil && !streamName.isEmpty }

    var cameraDisplayName: String { cameraTitle.isEmpty ? streamName : cameraTitle }
}
