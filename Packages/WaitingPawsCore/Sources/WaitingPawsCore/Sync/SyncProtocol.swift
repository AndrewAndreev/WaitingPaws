import Foundation

/// iPhone ↔ Mac link. The Mac owns the session, the camera (embedded go2rtc) and the recording; an iPhone
/// on the same network finds it over Bonjour, asks to join (the Mac user allows it once), then shows the
/// Mac's camera and a mirror of its session and sends button presses back. Several Macs and iPhones can share
/// a network (and later Windows PCs as hosts): each side tells who it is (`SyncDevice`: id, name, kind, model),
/// and pairings are bound to the ids.
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
        /// The host's stable id (`SyncDevice.id`); hosts before it are known by their name only.
        public static let id = "id"
        /// `SyncPlatform` raw value ("mac", "windows"); missing = a Mac.
        public static let platform = "os"
        /// "MacBook Air", "Mac mini".
        public static let model = "model"
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
    /// The Bonjour service name: the host's name, made unique on the network by Bonjour ("MacBook Pro (2)").
    public var name: String
    public var version: Int
    public var cameraTitle: String
    public var cameraReady: Bool
    public var sessionRunning: Bool
    public var currentExit: Int?
    /// nil for hosts that don't send one yet (they are told apart by name).
    public var id: String?
    /// `SyncPlatform` raw value; nil = a Mac (the only host before the field existed).
    public var platform: String?
    public var model: String

    public init(name: String, version: Int = SyncProtocol.version, cameraTitle: String = "", cameraReady: Bool = false,
                sessionRunning: Bool = false, currentExit: Int? = nil, id: String? = nil, platform: String? = nil,
                model: String = "") {
        self.name = name
        self.version = version
        self.cameraTitle = cameraTitle
        self.cameraReady = cameraReady
        self.sessionRunning = sessionRunning
        self.currentExit = currentExit
        self.id = id
        self.platform = platform
        self.model = model
    }

    public init(name: String, txt: [String: String]) {
        self.init(name: name,
                  version: Int(txt[SyncProtocol.TXT.version] ?? "") ?? 0,
                  cameraTitle: txt[SyncProtocol.TXT.camera] ?? "",
                  cameraReady: txt[SyncProtocol.TXT.ready] == "1",
                  sessionRunning: txt[SyncProtocol.TXT.session] == "1",
                  currentExit: Int(txt[SyncProtocol.TXT.exit] ?? ""),
                  id: txt[SyncProtocol.TXT.id].flatMap { $0.isEmpty ? nil : $0 },
                  platform: txt[SyncProtocol.TXT.platform],
                  model: txt[SyncProtocol.TXT.model] ?? "")
    }

    public var txt: [String: String] {
        var txt = [SyncProtocol.TXT.version: "\(version)",
                   SyncProtocol.TXT.camera: cameraTitle,
                   SyncProtocol.TXT.ready: cameraReady ? "1" : "0",
                   SyncProtocol.TXT.session: sessionRunning ? "1" : "0"]
        if let currentExit { txt[SyncProtocol.TXT.exit] = "\(currentExit)" }
        if let id { txt[SyncProtocol.TXT.id] = id }
        if let platform { txt[SyncProtocol.TXT.platform] = platform }
        if !model.isEmpty { txt[SyncProtocol.TXT.model] = model }
        return txt
    }

    /// The host as the UI shows it. Without an id the name stands in for it ("name:" keeps the two apart).
    public var device: SyncDevice {
        SyncDevice(id: id ?? "name:" + name, name: name,
                   kind: platform.map { SyncPlatform(rawValue: $0) } ?? .mac, model: model)
    }
}

/// iPhone → Mac: who is asking, with the iPhone's key for this connection (Curve25519, raw).
public struct SyncHello: Codable, Equatable {
    public var deviceID: String
    public var deviceName: String
    public var publicKey: Data
    public var protocolVersion: Int
    /// `SyncPlatform` raw value; nil from builds before it (always an iPhone then).
    public var platform: String?
    /// "iPhone 16 Pro": iOS gives apps only "iPhone" as the device name, so the model is what tells two apart.
    public var model: String?
    /// What this build understands beyond protocol v2 (`SyncFeature`); nil from builds before it.
    public var features: [String]?

    public init(deviceID: String, deviceName: String, publicKey: Data, protocolVersion: Int = SyncProtocol.version,
                platform: String? = nil, model: String? = nil, features: [String]? = nil) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.protocolVersion = protocolVersion
        self.platform = platform
        self.model = model
        self.features = features
    }

    public var device: SyncDevice {
        SyncDevice(id: deviceID, name: deviceName, kind: platform.map { SyncPlatform(rawValue: $0) } ?? .iphone,
                   model: model ?? "")
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
    /// Who the host is (as in its TXT record, but sealed); nil from builds before these fields.
    public var hostID: String?
    public var platform: String?
    public var model: String?
    /// What the host understands beyond protocol v2 (`SyncFeature`): the iPhone sends only those extra messages.
    public var features: [String]?

    public init(hostName: String, go2rtcPort: Int, username: String, password: String, addresses: [String],
                hostID: String? = nil, platform: String? = nil, model: String? = nil, features: [String]? = nil) {
        self.hostName = hostName
        self.go2rtcPort = go2rtcPort
        self.username = username
        self.password = password
        self.addresses = addresses
        self.hostID = hostID
        self.platform = platform
        self.model = model
        self.features = features
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
    /// The Mac's clock when this state left it: the iPhone keeps track of how far the two clocks are apart
    /// (`SyncClock`) to send the moment of each button press in the Mac's time. Set by the sender, not compared.
    public var sentAt: Date?
    /// The Mac's second camera (another room), recorded while it is on screen; nil without one and from builds
    /// before it.
    public var secondStreamName: String?
    public var secondCameraTitle: String?
    /// The second camera's `xiaomi://` source: its modes and turning on the iPhone, like `cameraSource`.
    public var secondCameraSource: String?
    /// The camera on the Mac's screen, the one it records: the iPhone shows the same one. Nil from Macs before the
    /// cameras were in step — those don't know `SyncCommand.showCamera` either (an unknown command closes the link).
    public var showsSecondCamera: Bool?

    public init(session: TrainingSession.Snapshot?, recordingSince: Date?, cameraReady: Bool, cameraTitle: String,
                streamName: String, lastRecord: TrainingRecord?, pendingPlan: TrainingPlan? = nil, cameraSource: String? = nil,
                streamRevision: Int? = nil, sentAt: Date? = nil, secondStreamName: String? = nil,
                secondCameraTitle: String? = nil, secondCameraSource: String? = nil, showsSecondCamera: Bool? = nil) {
        self.session = session
        self.recordingSince = recordingSince
        self.cameraReady = cameraReady
        self.cameraTitle = cameraTitle
        self.streamName = streamName
        self.lastRecord = lastRecord
        self.pendingPlan = pendingPlan
        self.cameraSource = cameraSource
        self.streamRevision = streamRevision
        self.sentAt = sentAt
        self.secondStreamName = secondStreamName
        self.secondCameraTitle = secondCameraTitle
        self.secondCameraSource = secondCameraSource
        self.showsSecondCamera = showsSecondCamera
    }
}

/// How far the iPhone's clock is from the host's, from the host's `SyncState.sentAt`: every state arrives some
/// network delay after it was sent, so the smallest delay seen (the largest `sentAt − arrival`) is the best guess.
/// A button press is then sent in the host's time — the host logs it at that moment even when the command itself
/// was held up by a weak Wi-Fi.
public struct SyncClock: Equatable {
    /// Host time minus local time, nil before the first sample (the clocks are trusted as they are then).
    public private(set) var offset: TimeInterval?

    public init() {}

    public mutating func sample(hostTime: Date, receivedAt: Date) {
        let value = hostTime.timeIntervalSince(receivedAt)
        offset = max(offset ?? value, value)
    }

    /// `local` (a moment on this device) in the host's time.
    public func hostTime(for local: Date) -> Date {
        local.addingTimeInterval(offset ?? 0)
    }
}

/// iPhone → Mac.
public enum SyncCommand: Codable, Equatable {
    /// A button press; `at` is when it was pressed, in the host's time (nil from older iPhones: the host's now).
    case session(SessionCommand, at: Date? = nil)
    case startSession(TrainingPlan)
    /// A schedule pasted (or edited) on the iPhone becomes the Mac's waiting one; nil clears it.
    case setPendingPlan(TrainingPlan?)
    /// The running session's schedule, edited on the iPhone (`TrainingSession.updatePlan`: `quiet` for a step of an
    /// edit still going on, `since` — the plan before the edit — to log it as one change).
    case updateSessionPlan(TrainingPlan, quiet: Bool? = nil, since: TrainingPlan? = nil)
    case abandonSession
    case startRecording
    case stopRecording
    /// The switcher on the iPhone: the Mac shows (and records) that camera too. Only to a Mac whose state has
    /// `showsSecondCamera`. `stream` names the camera tapped (its stream in the last state the iPhone had): the cameras
    /// may have been swapped or changed on the Mac while the tap was on its way, and the place alone would then bring
    /// another one (`shownSecondCamera`). Nil from iPhones before it; Macs before it skip it and go by the place.
    case showCamera(second: Bool, stream: String? = nil)
}

extension SyncCommand {
    /// Where a host with these cameras puts the one `showCamera` asks for: false — its first camera, true — the
    /// second, nil — nowhere. Named, it is that camera wherever it is now, and none once it is gone (not another one in
    /// its place); unnamed (an iPhone from before the name), the place tapped.
    public static func shownSecondCamera(second: Bool, stream: String?, first: String, secondStream: String?) -> Bool? {
        guard let stream else { return second }
        if stream == first { return false }
        if let secondStream, stream == secondStream { return true }
        return nil
    }
}

extension SyncState {
    /// The camera on screen an iPhone takes from this state over its own (`local`), or nil to keep its own: when it
    /// changed on the host, on a new link (also after a drop, whatever was switched here meanwhile), and when the host's
    /// cameras themselves changed — swapped, another one chosen, the second removed — so a place switched to here may
    /// hold another camera now. Otherwise its own stays: a switch here shows at once, and a state the host sent before
    /// it got the switch must not undo it.
    public func shownSecondCamera(after previous: SyncState?, local: Bool, firstOfLink: Bool) -> Bool? {
        guard let shown = showsSecondCamera, shown != local else { return nil }
        let camerasChanged = previous.map { $0.streamName != streamName || $0.secondStreamName != secondStreamName } ?? false
        return firstOfLink || shown != previous?.showsSecondCamera || camerasChanged ? shown : nil
    }
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
    /// Either way: an offer or answer of the direct link (`SyncP2PSignal`). Only to a side that lists
    /// `SyncFeature.p2p`: an older build fails to decode it and closes the link.
    case p2p(SyncP2PSignal)

    /// Messages that only ever travel sealed.
    public var needsSealing: Bool {
        switch self {
        case .welcome, .state, .command, .p2p: return true
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
