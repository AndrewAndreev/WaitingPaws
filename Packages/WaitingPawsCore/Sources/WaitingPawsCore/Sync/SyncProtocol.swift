import Foundation

/// iPhone ↔ Mac link. The Mac owns the session, the camera (embedded go2rtc) and the recording; an iPhone
/// on the same network finds it over Bonjour, asks to join (the Mac user allows it once), then shows the
/// Mac's camera and a mirror of its session and sends button presses back.
///
/// Transport: WebSocket over TCP (Network.framework on both ends), one JSON `SyncMessage` per text frame.
public enum SyncProtocol {
    /// Bonjour service type advertised by the Mac.
    public static let serviceType = "_waitingpaws._tcp"
    public static let version = 1

    /// TXT record keys of the advertised service.
    public enum TXT {
        /// Protocol version.
        public static let version = "v"
        /// Camera name shown on the iPhone ("Прихожая").
        public static let camera = "cam"
        /// "1" when go2rtc runs and a camera is selected on the Mac.
        public static let ready = "ready"
        /// "1" while a training runs on the Mac.
        public static let session = "session"
        /// Current exit number while a training runs.
        public static let exit = "exit"
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

/// What a Mac advertises before anyone connects (from the Bonjour TXT record).
public struct SyncHostInfo: Equatable, Hashable {
    public var name: String
    public var version: Int
    public var cameraTitle: String
    public var cameraReady: Bool
    public var sessionRunning: Bool
    public var currentExit: Int?

    public init(name: String, version: Int = SyncProtocol.version, cameraTitle: String = "", cameraReady: Bool = false,
                sessionRunning: Bool = false, currentExit: Int? = nil) {
        self.name = name
        self.version = version
        self.cameraTitle = cameraTitle
        self.cameraReady = cameraReady
        self.sessionRunning = sessionRunning
        self.currentExit = currentExit
    }

    public init(name: String, txt: [String: String]) {
        self.init(name: name,
                  version: Int(txt[SyncProtocol.TXT.version] ?? "") ?? 0,
                  cameraTitle: txt[SyncProtocol.TXT.camera] ?? "",
                  cameraReady: txt[SyncProtocol.TXT.ready] == "1",
                  sessionRunning: txt[SyncProtocol.TXT.session] == "1",
                  currentExit: Int(txt[SyncProtocol.TXT.exit] ?? ""))
    }

    public var txt: [String: String] {
        var txt = [SyncProtocol.TXT.version: "\(version)",
                   SyncProtocol.TXT.camera: cameraTitle,
                   SyncProtocol.TXT.ready: cameraReady ? "1" : "0",
                   SyncProtocol.TXT.session: sessionRunning ? "1" : "0"]
        if let currentExit { txt[SyncProtocol.TXT.exit] = "\(currentExit)" }
        return txt
    }
}

/// iPhone → Mac: who is asking. `token` is the one the Mac handed out last time (skips the approval).
public struct SyncHello: Codable, Equatable {
    public var deviceID: String
    public var deviceName: String
    public var token: String?
    public var protocolVersion: Int

    public init(deviceID: String, deviceName: String, token: String?, protocolVersion: Int = SyncProtocol.version) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.token = token
        self.protocolVersion = protocolVersion
    }
}

/// Mac → iPhone after approval: a token for next time and access to the Mac's go2rtc.
public struct SyncWelcome: Codable, Equatable {
    public var hostName: String
    public var token: String
    /// go2rtc API port on the Mac (LAN, Basic auth).
    public var go2rtcPort: Int
    public var username: String
    public var password: String
    /// The Mac's IPv4 addresses, in case the connection's own address is not usable for HTTP.
    public var addresses: [String]

    public init(hostName: String, token: String, go2rtcPort: Int, username: String, password: String, addresses: [String]) {
        self.hostName = hostName
        self.token = token
        self.go2rtcPort = go2rtcPort
        self.username = username
        self.password = password
        self.addresses = addresses
    }
}

/// Mac → iPhone: everything the iPhone shows, sent on every change.
public struct SyncState: Codable, Equatable {
    public var session: TrainingSession.Snapshot?
    /// When the Mac's recording started (nil = not recording).
    public var recordingSince: Date?
    public var cameraReady: Bool
    public var cameraTitle: String
    public var streamName: String
    /// The session that has just finished on the Mac (for the summary and the log on the iPhone).
    public var lastRecord: TrainingRecord?

    public init(session: TrainingSession.Snapshot?, recordingSince: Date?, cameraReady: Bool, cameraTitle: String,
                streamName: String, lastRecord: TrainingRecord?) {
        self.session = session
        self.recordingSince = recordingSince
        self.cameraReady = cameraReady
        self.cameraTitle = cameraTitle
        self.streamName = streamName
        self.lastRecord = lastRecord
    }
}

/// iPhone → Mac.
public enum SyncCommand: Codable, Equatable {
    case session(SessionCommand)
    case startSession(TrainingPlan)
    case abandonSession
    case startRecording
    case stopRecording
}

public enum SyncMessage: Codable, Equatable {
    case hello(SyncHello)
    /// The Mac shows an approval prompt; wait.
    case pending
    case rejected(String)
    case welcome(SyncWelcome)
    case state(SyncState)
    case command(SyncCommand)

    public func encoded() throws -> Data {
        try SyncProtocol.encoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> SyncMessage {
        try SyncProtocol.decoder().decode(SyncMessage.self, from: data)
    }
}
