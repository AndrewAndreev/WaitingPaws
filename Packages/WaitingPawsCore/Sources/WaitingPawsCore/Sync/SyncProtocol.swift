import Foundation

/// iPhone ↔ Mac link. The Mac owns the session, the camera (embedded go2rtc) and the recording; an iPhone
/// on the same network finds it over Bonjour, asks to join (the Mac user allows it once), then shows the
/// Mac's camera and a mirror of its session and sends button presses back.
///
/// Transport: WebSocket over TCP (Network.framework on both ends), one JSON `SyncMessage` per text frame.
/// From the key exchange on, the frames are encrypted (`SyncCrypto`).
public enum SyncProtocol {
    /// Bonjour service type advertised by the Mac.
    public static let serviceType = "_waitingpaws._tcp"
    /// 2: key exchange, proof of pairing and encrypted messages (v1 sent everything in the clear).
    public static let version = 2

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

/// iPhone → Mac: who is asking, with the iPhone's key for this connection (Curve25519, raw).
public struct SyncHello: Codable, Equatable {
    public var deviceID: String
    public var deviceName: String
    public var publicKey: Data
    public var protocolVersion: Int

    public init(deviceID: String, deviceName: String, publicKey: Data, protocolVersion: Int = SyncProtocol.version) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.protocolVersion = protocolVersion
    }
}

/// Mac → iPhone after approval (sealed): access to the Mac's go2rtc. Sent again when the password changes.
public struct SyncWelcome: Codable, Equatable {
    public var hostName: String
    /// go2rtc API port on the Mac (LAN, Basic auth).
    public var go2rtcPort: Int
    public var username: String
    public var password: String
    /// The Mac's IPv4 addresses, in case the connection's own address is not usable for HTTP.
    public var addresses: [String]

    public init(hostName: String, go2rtcPort: Int, username: String, password: String, addresses: [String]) {
        self.hostName = hostName
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
    /// A schedule pasted on either device and waiting for «Начать» (nil while a session runs).
    public var pendingPlan: TrainingPlan?
    /// The camera's `xiaomi://` source, for its settings on the iPhone (the Mac's go2rtc config, which also
    /// holds the Xiaomi tokens, is closed to the LAN).
    public var cameraSource: String?
    /// Changes whenever the Mac's players had to reconnect (quality change): the iPhone's player reconnects too,
    /// or the old stream keeps a second connection to the camera open.
    public var streamRevision: Int?

    public init(session: TrainingSession.Snapshot?, recordingSince: Date?, cameraReady: Bool, cameraTitle: String,
                streamName: String, lastRecord: TrainingRecord?, pendingPlan: TrainingPlan? = nil, cameraSource: String? = nil,
                streamRevision: Int? = nil) {
        self.session = session
        self.recordingSince = recordingSince
        self.cameraReady = cameraReady
        self.cameraTitle = cameraTitle
        self.streamName = streamName
        self.lastRecord = lastRecord
        self.pendingPlan = pendingPlan
        self.cameraSource = cameraSource
        self.streamRevision = streamRevision
    }
}

/// iPhone → Mac.
public enum SyncCommand: Codable, Equatable {
    case session(SessionCommand)
    case startSession(TrainingPlan)
    /// A schedule pasted (or edited) on the iPhone becomes the Mac's waiting one; nil clears it.
    case setPendingPlan(TrainingPlan?)
    case abandonSession
    case startRecording
    case stopRecording
}

public enum SyncMessage: Codable, Equatable {
    case hello(SyncHello)
    /// Mac → iPhone: the Mac's key for this connection.
    case challenge(Data)
    /// iPhone → Mac: proof of an earlier pairing with this Mac, nil for a new iPhone.
    case proof(Data?)
    /// The Mac shows an approval prompt; wait.
    case pending
    case rejected(String)
    /// An encrypted `welcome`, `state` or `command` (see `SyncCipher`).
    case sealed(Data)
    case welcome(SyncWelcome)
    case state(SyncState)
    case command(SyncCommand)

    /// Messages that only ever travel sealed.
    public var needsSealing: Bool {
        switch self {
        case .welcome, .state, .command: return true
        default: return false
        }
    }

    public func encoded() throws -> Data {
        try SyncProtocol.encoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> SyncMessage {
        try SyncProtocol.decoder().decode(SyncMessage.self, from: data)
    }
}
