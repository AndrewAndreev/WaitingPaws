import Foundation

/// The direct (peer-to-peer) link between an iPhone and its Mac — an experiment, next to the sync link and never in its
/// way. A WebRTC data channel with ICE over public STUN only (no TURN, no server of ours; Go side: `GoMobile/p2p`). It
/// carries pings, to learn whether this household's NAT and carrier allow a direct path at all.
///
/// The iPhone makes two links while it is linked at home: `lan` (Wi-Fi as it is) and `out` (every socket bound to the
/// cellular interface: the path the phone has away from home, checked before it leaves). Their offers and answers
/// travel sealed over the sync link (`SyncMessage.p2p`), only between builds that both list `SyncFeature.p2p`.
public enum SyncFeature {
    /// `SyncHello.features` / `SyncWelcome.features`: the side understands `SyncMessage.p2p` (older ones would close
    /// the link on an unknown message).
    public static let p2p = "p2p"
}

/// One signal of a direct link, passed through untouched: the Go side writes and reads `payload`.
public struct SyncP2PSignal: Codable, Equatable {
    /// `P2PLinkKind` raw value.
    public var link: String
    public var payload: String

    public init(link: String, payload: String) {
        self.link = link
        self.payload = payload
    }
}

/// Which of the two links.
public enum P2PLinkKind: String, CaseIterable, Codable, Sendable {
    /// Over the home Wi-Fi (host candidates on the LAN).
    case lan
    /// The iPhone bound to its cellular interface: carrier's NAT ↔ the home router's NAT, as away from home.
    case out
}

/// One end of the selected candidate pair.
public struct P2PCandidate: Codable, Equatable, Sendable {
    /// host, srflx, prflx, relay.
    public var type: String
    public var `protocol`: String?
    public var address: String?
    public var port: Int?

    public init(type: String, address: String? = nil, port: Int? = nil) {
        self.type = type
        self.address = address
        self.port = port
        self.protocol = "udp"
    }

    public var isIPv6: Bool { address?.contains(":") ?? false }
}

/// How a side's NAT maps one socket toward several STUN servers (`GoMobile/p2p` NATResult).
public struct P2PNATResult: Codable, Equatable, Sendable {
    /// independent, dependent, none, unknown, blocked.
    public var mapping: String
    public var `public`: String?
    public var answers: [String]?
    public var servers: [String]?
    public var iface: String?
    public var error: String?
    public var took: Int?

    public init(mapping: String, public: String? = nil) {
        self.mapping = mapping
        self.public = `public`
    }

    public enum Mapping: String, Sendable {
        /// The same public port for every server (a cone NAT): hole punching usually works.
        case independent
        /// A new port per server (a symmetric NAT, common with carriers' CGNAT): direct only if the other side is lenient.
        case dependent
        /// A public address of its own.
        case none
        /// Fewer than two servers answered.
        case unknown
        /// No server answered: UDP to STUN is closed (or there's no network on that interface).
        case blocked
    }

    public var kind: Mapping { Mapping(rawValue: mapping) ?? .unknown }

    /// The public IP without the port ("93.1.2.3", "2a00::1").
    public var publicIP: String? {
        guard let address = `public` else { return nil }
        if address.hasPrefix("["), let end = address.firstIndex(of: "]") {
            return String(address[address.index(after: address.startIndex)..<end])
        }
        return address.split(separator: ":").first.map(String.init)
    }

    /// Which servers answered, by name: "Cloudflare, Google" (for the log and details).
    public var answeredServers: [String] {
        guard let servers, let answers else { return [] }
        return zip(servers, answers).filter { !$0.1.isEmpty }.map { $0.0 }
    }
}

/// The home router, asked for its external address (`GoMobile/p2p` RouterResult): could it give the Mac a stable
/// address from the internet (a port mapping) for an iPhone away from home to come back to without a server?
public struct P2PRouterResult: Codable, Equatable, Sendable {
    public struct PMP: Codable, Equatable, Sendable {
        public var external: String?
        public var error: String?

        public init(external: String? = nil, error: String? = nil) {
            self.external = external
            self.error = error
        }
    }

    public struct UPnP: Codable, Equatable, Sendable {
        public var device: String?
        public var service: String?
        public var external: String?
        public var error: String?

        public init(device: String? = nil, service: String? = nil, external: String? = nil, error: String? = nil) {
            self.device = device
            self.service = service
            self.external = external
            self.error = error
        }
    }

    public var gateway: String?
    public var pmp: PMP?
    public var upnp: UPnP?
    public var error: String?
    public var took: Int?

    public init(gateway: String? = nil, pmp: PMP? = nil, upnp: UPnP? = nil) {
        self.gateway = gateway
        self.pmp = pmp
        self.upnp = upnp
    }

    /// What the router says its external address is (NAT-PMP first), nil when it answers neither.
    public var external: String? { pmp?.external ?? upnp?.external }

    public enum Verdict: Equatable, Sendable {
        /// The router can map a port, and its external address is the one the internet sees: a stable home endpoint
        /// is possible (if the address itself doesn't change).
        case mappable
        /// It can map, but its external address is not the public one (the provider's NAT on top): useless from outside.
        case behindAnotherNAT
        /// Neither NAT-PMP nor UPnP answered.
        case unavailable
    }

    /// Compared with the public address STUN saw (`publicIP`).
    public func verdict(publicIP: String?) -> Verdict {
        guard let external else { return .unavailable }
        if P2PAddress.isPrivate(external) { return .behindAnotherNAT }
        if let publicIP, publicIP != external { return .behindAnotherNAT }
        return .mappable
    }

    /// "NAT-PMP", "UPnP (Keenetic Giga)".
    public var method: String? {
        if pmp?.external != nil { return "NAT-PMP" }
        guard upnp?.external != nil else { return nil }
        let device = upnp?.device?.trimmingCharacters(in: .whitespaces) ?? ""
        return device.isEmpty ? "UPnP" : "UPnP (\(device))"
    }
}

public enum P2PAddress {
    /// 10/8, 172.16/12, 192.168/16, the carriers' 100.64/10, link-local.
    public static func isPrivate(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return ip.lowercased().hasPrefix("fe80") || ip.lowercased().hasPrefix("fd") }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (169, 254), (127, _): return true
        case (172, 16...31), (100, 64...127): return true
        default: return false
        }
    }
}

/// A direct link's status, as the Go side reports it (`GoMobile/p2p` Status), with what the UI needs from it.
public struct P2PLinkStatus: Codable, Equatable, Sendable {
    public var label: String
    public var role: String?
    /// new, gathering, connecting, connected, disconnected, failed, closed.
    public var state: String
    /// When the state began (Unix ms).
    public var since: Double?
    public var gen: Int?
    public var local: P2PCandidate?
    public var remote: P2PCandidate?
    public var rtt: Double?
    public var rttMin: Double?
    public var rttAvg: Double?
    public var pings: Int?
    public var pongs: Int?
    public var lastPong: Double?
    public var connectedAt: Double?
    public var localTypes: [String: Int]?
    public var remoteTypes: [String: Int]?
    public var nat: P2PNATResult?
    public var peerNat: P2PNATResult?
    public var peerIface: String?
    public var restarts: Int?
    public var restarting: Bool?
    public var signalPath: String?
    public var error: String?
    /// Grows with every status the Go side sends (an older one arriving late is dropped).
    public var seq: UInt64?

    public init(label: String, state: String) {
        self.label = label
        self.state = state
    }

    public static func decode(_ json: String) -> P2PLinkStatus? {
        try? JSONDecoder().decode(P2PLinkStatus.self, from: Data(json.utf8))
    }

    public var kind: P2PLinkKind? { P2PLinkKind(rawValue: label) }

    /// What the UI says about the link.
    public enum Outcome: Equatable, Sendable {
        case checking
        /// Connected; `stale`: no pong for a while (the path is down, ICE still waiting for it).
        case direct(stale: Bool)
        /// Never connected, or dropped for good.
        case failed
        /// Connected once, now gone (closed, or failed after working).
        case lost
    }

    /// `now` decides staleness: no pong for `staleAfter` seconds while "connected" or "disconnected".
    public func outcome(now: Date = Date(), staleAfter: TimeInterval = 6) -> Outcome {
        switch state {
        case "new", "gathering", "connecting":
            return .checking
        case "connected", "disconnected":
            // Before the first pong the link counts from when it connected.
            let last = (Self.set(lastPong) ?? Self.set(connectedAt) ?? Self.set(since) ?? now.timeIntervalSince1970 * 1000) / 1000
            let stale = state == "disconnected" || now.timeIntervalSince1970 - last > staleAfter
            return .direct(stale: stale)
        default:
            return everConnected ? .lost : .failed
        }
    }

    /// A time the Go side has set (builds before `omitempty` sent 0 for "not yet").
    private static func set(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// Whether this link can still carry pings (connected, or ICE waiting for a path that may come back).
    public var isAlive: Bool { state == "connected" || state == "disconnected" }

    public var everConnected: Bool { Self.set(connectedAt) != nil }

    /// Answered at least one ping.
    public var answered: Bool { (pongs ?? 0) > 0 }

    /// "srflx ↔ prflx" (this side's candidate first).
    public var pairText: String? {
        guard let local, let remote else { return nil }
        let v6 = local.isIPv6 || remote.isIPv6 ? " IPv6" : ""
        return "\(local.type) ↔ \(remote.type)\(v6)"
    }

    /// Seconds since the last pong (nil before the first).
    public func silence(now: Date = Date()) -> TimeInterval? {
        guard let last = Self.set(lastPong) ?? Self.set(connectedAt) else { return nil }
        return now.timeIntervalSince1970 - last / 1000
    }
}
