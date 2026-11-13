import CryptoKit
import Foundation

/// A knock through the door (`GoMobile/p2p` door.go): what reaches the other side while no link to it is up — the
/// iPhone's offer for a new direct link after the app was relaunched or its link died away from home, and the Mac's
/// answer back the same way. Nothing else carries a signal there: no Wi-Fi, no server.
public struct P2PDoorKnock: Codable, Equatable, Sendable {
    /// The sender's device id (`SyncIdentity.deviceID`).
    public var from: String
    /// When it was sealed (seconds since 1970) and a random id: `P2PDoorGuard` drops a copy seen before or an old one.
    public var sent: Double
    public var nonce: String
    public var signal: SyncP2PSignal

    public init(from: String, signal: SyncP2PSignal, sent: Date = Date(), nonce: String = UUID().uuidString) {
        self.from = from
        self.signal = signal
        self.sent = sent.timeIntervalSince1970
        self.nonce = nonce
    }
}

/// Seals a knock with a key made from the pairing secret both sides keep (never sent; one key per direction), so
/// only the paired iPhone can knock and only its Mac can answer. Compressed first: an offer with its candidates is
/// about 1 KB and has to fit one datagram.
public enum P2PDoorSeal {
    public enum Direction: String, Sendable {
        case phoneToMac = "phone->mac"
        case macToPhone = "mac->phone"
    }

    public enum Failure: Error { case version }

    static let version: UInt8 = 1

    static func key(secret: String, _ direction: Direction) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
                               salt: Data("waitingpaws-p2p-door".utf8), info: Data(direction.rawValue.utf8),
                               outputByteCount: 32)
    }

    public static func seal(_ knock: P2PDoorKnock, secret: String, _ direction: Direction) throws -> Data {
        let json = try JSONEncoder().encode(knock)
        let packed = try (json as NSData).compressed(using: .zlib) as Data
        let box = try ChaChaPoly.seal(packed, using: key(secret: secret, direction), authenticating: Data([version]))
        return Data([version]) + box.combined
    }

    /// Throws for anything not sealed with this secret in this direction (decompressed only once it is genuine).
    public static func open(_ data: Data, secret: String, _ direction: Direction) throws -> P2PDoorKnock {
        guard data.first == version else { throw Failure.version }
        let box = try ChaChaPoly.SealedBox(combined: Data(data.dropFirst()))
        let packed = try ChaChaPoly.open(box, using: key(secret: secret, direction), authenticating: Data([version]))
        let json = try (packed as NSData).decompressed(using: .zlib) as Data
        return try JSONDecoder().decode(P2PDoorKnock.self, from: json)
    }
}

/// Drops a knock seen before (the sender sends each a few times: datagrams get lost) or sealed too long ago or too
/// far ahead (a recorded one played again later).
public struct P2PDoorGuard: Sendable {
    public static let window: TimeInterval = 300
    private var seen: [String: Double] = [:]

    public init() {}

    public mutating func accept(_ knock: P2PDoorKnock, now: Date = Date()) -> Bool {
        let time = now.timeIntervalSince1970
        seen = seen.filter { abs(time - $0.value) < Self.window }
        guard abs(time - knock.sent) < Self.window, seen[knock.nonce] == nil else { return false }
        seen[knock.nonce] = knock.sent
        return true
    }
}

/// The carrier's addresses an iPhone's direct link came from, kept by its Mac: where to open the home router for it
/// (`GoMobile/p2p` Door.Spray) while it is gone. Carriers seen so far hand one subscriber's ports out of a narrow
/// range (2026-11-13: one address, ports 12402–12459 over four sessions), so a band around the ones seen covers the
/// next socket's port.
public struct P2PCarrierPorts: Codable, Equatable, Sendable {
    public var ip: String
    /// The latest ports first, at most `keep`.
    public var ports: [Int]
    public var seen: Date

    public static let keep = 8
    /// How far past the ports seen the band reaches, and its widest.
    public static let margin = 64
    public static let widest = 256

    public init(ip: String, ports: [Int], seen: Date) {
        self.ip = ip
        self.ports = ports
        self.seen = seen
    }

    /// The same IPv4 address keeps its ports (newest first, no repeats); a new one starts over.
    public mutating func add(ip newIP: String, port: Int, at time: Date = Date()) {
        if newIP != ip {
            ip = newIP
            ports = []
        }
        ports.removeAll { $0 == port }
        ports.insert(port, at: 0)
        ports = Array(ports.prefix(Self.keep))
        seen = time
    }

    /// The ports to spray: around those seen, `margin` past both ends, at most `widest` (centred on the newest).
    public var band: ClosedRange<Int>? {
        guard let low = ports.min(), let high = ports.max(), let newest = ports.first else { return nil }
        var from = max(1024, low - Self.margin), to = min(65535, high + Self.margin)
        if to - from + 1 > Self.widest {
            from = max(1024, newest - Self.widest / 2)
            to = min(65535, from + Self.widest - 1)
        }
        return from...to
    }
}

/// A door's status (`GoMobile/p2p` DoorStatus).
public struct P2PDoorStatus: Codable, Equatable, Sendable {
    /// The socket's own address, and the one the internet sees (nil until a STUN server answered).
    public var local: String
    public var external: String?
    /// "ip:from-to" while the door keeps the router open for an iPhone that is gone.
    public var spraying: String?
    public var sprayed: Int?
    public var received: Int?
    public var sent: Int?
    public var error: String?
    public var seq: UInt64?

    public init(local: String, external: String? = nil, spraying: String? = nil) {
        self.local = local
        self.external = external
        self.spraying = spraying
    }

    public static func decode(_ json: String) -> P2PDoorStatus? {
        try? JSONDecoder().decode(P2PDoorStatus.self, from: Data(json.utf8))
    }
}
