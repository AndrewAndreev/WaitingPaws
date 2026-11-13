import Foundation
import Network
import Observation
import WaitingPawsCore
#if canImport(Go2RTC)
import Go2RTC
#endif

/// This device's direct links (an experiment, see `SyncP2P` in the core): on the iPhone its two links to the Mac it is
/// linked with (`lan` over Wi-Fi, `out` bound to cellular — the path it has away from home, checked while still home),
/// on the Mac the answering side of each iPhone's. The Go side (`GoMobile/p2p`) does the WebRTC; this keeps the links,
/// routes their signals over the sync link and keeps their status for the UI. Never in the sync link's way: a link that
/// fails only says so.
///
/// The iPhone's `out` link also forwards two local ports to the Mac's services (`directRoute`): when the home network is
/// gone, `SyncClient` joins the Mac through it and the camera's picture comes the same way.
///
/// With no link up at all — the app relaunched away from home, or its link died there — the iPhone knocks at the Mac's
/// door (`P2PDoorKnock`, `GoMobile/p2p` door.go): its new link's offer goes sealed to the Mac's fixed UDP port and the
/// answer comes back the same way. The Mac keeps the home router open for the iPhone's carrier ports meanwhile.
@MainActor
@Observable
final class P2PLinks {
    struct Key: Hashable {
        let peer: String
        let kind: P2PLinkKind
    }

    /// The links' last status, by peer (device id) and kind.
    private(set) var statuses: [Key: P2PLinkStatus] = [:]
    /// Why a link could not start at all ("no cellular data"), by key.
    private(set) var unavailable: [Key: String] = [:]
    /// A link that died with no way to set it up again: away from home there is no sync link to carry a new offer,
    /// and nothing else can (no server).
    private(set) var needsServer: Set<Key> = []
    /// Mac: what the router said (nil before it was asked).
    private(set) var router: P2PRouterResult?
    private(set) var isProbingRouter = false
    /// iPhone: the last time the app came back from the background, how long it was away and which links still answered
    /// after it (the background test).
    private(set) var lastResume: Resume?
    /// iPhone: the host the links were last started to (its id), also after the sync link dropped.
    private(set) var lastPeer: String?
    /// The kind's first result on this link (connected or failed), once per link: the iPhone says it in a bubble.
    @ObservationIgnored var onFirstResult: ((Key, P2PLinkStatus) -> Void)?
    /// Sends a signal to the peer over the sync link; false when there is no link to that peer now.
    @ObservationIgnored var sendSignal: ((_ peer: String, SyncP2PSignal) -> Bool)?
    /// iPhone: whether the Mac can be reached through the `out` link, or the home network looks gone, changed
    /// (also Wi-Fi going or coming): `SyncClient` picks its way again.
    @ObservationIgnored var onRouteChange: (() -> Void)?
    /// Mac: the services an iPhone may reach over its links' streams ("sync", "go2rtc") → "address:port".
    @ObservationIgnored var servicesProvider: (() -> [String: String])?

    /// The door: the Mac's on `doorPort` while it lets iPhones in, the iPhone's (on cellular) while it knocks.
    private(set) var doorStatus: P2PDoorStatus?
    /// iPhone: the Mac it knocked at last, until a link to it is up.
    private(set) var knocking: String?
    /// The pairing secret kept for a peer (Mac: an iPhone's, iPhone: its Mac's): knocks are sealed with it.
    @ObservationIgnored var pairingSecret: ((_ peer: String) -> String?)?
    /// Mac: the paired iPhones (whose keys may open a knock); one is joined over sync now; the door is wanted
    /// (iPhones are let in).
    @ObservationIgnored var pairedPeers: (() -> [String])?
    @ObservationIgnored var isPeerLinked: ((String) -> Bool)?
    @ObservationIgnored var doorWanted: (() -> Bool)?
    /// iPhone: the Mac it rejoins on its own, whether Bonjour sees that Mac, whether sync is up over the home network.
    @ObservationIgnored var knockTarget: (() -> String?)?
    @ObservationIgnored var seesOnLAN: ((String) -> Bool)?
    @ObservationIgnored var isLinkedOverLAN: (() -> Bool)?

    /// iPhone: the local ports (on 127.0.0.1) that the `out` link forwards to the Mac's sync listener and go2rtc.
    struct DirectRoute: Equatable {
        let sync: Int
        let go2rtc: Int
    }

    struct Resume: Equatable {
        let at: Date
        let away: TimeInterval
        /// nil while it is still being found out (a few seconds after the return).
        var survived: [P2PLinkKind: Bool]?
    }

    static let stunServers = ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"]

    @ObservationIgnored private var links: [Key: Handle] = [:]
    @ObservationIgnored private var reported: Set<Key> = []
    @ObservationIgnored private var lastLogged: [Key: String] = [:]
    @ObservationIgnored private var backgroundSince: Date?
    @ObservationIgnored let network = P2PNetwork()
    @ObservationIgnored private var lastRoute: String?

    @ObservationIgnored private var door: DoorHandle?
    @ObservationIgnored private var doorGuard = P2PDoorGuard()
    /// Mac: where an iPhone's knock came from: that link's answer goes back there.
    @ObservationIgnored private var doorReturn: [String: (address: String, at: Date)] = [:]
    /// Mac: the carrier's addresses each iPhone's `out` link came from, when each was last linked, what is sprayed.
    @ObservationIgnored private var carriers: [String: P2PCarrierPorts] = P2PLinks.loadCarriers()
    @ObservationIgnored private var lastLinked: [String: Date] = [:]
    @ObservationIgnored private var sprayingFor: String?
    /// iPhone: each Mac's door from the internet, the links whose signals go through the door, the next knock's time.
    @ObservationIgnored private var doors: [String: String] = UserDefaults.standard.dictionary(forKey: P2PLinks.doorsKey) as? [String: String] ?? [:]
    @ObservationIgnored private var viaDoor: Set<Key> = []
    @ObservationIgnored private var nextKnock = Date.distantPast
    @ObservationIgnored private var knockFailures = 0
    @ObservationIgnored private let launchedAt = Date()

    static let homeSilence: TimeInterval = 10
    /// The Mac's door: a fixed UDP port, so the router's mapping of it (its address from the internet) stays. A port
    /// forward to it on the router would let every knock in.
    static let doorPort = 41984
    /// Mac: how long after an iPhone was last linked the router is kept open for it, and how often.
    static let sprayFor: TimeInterval = 30 * 60
    static let sprayEvery: Double = 8
    /// iPhone: a link silent this long counts as dead for knocking (a shorter blip may still pass by itself).
    static let knockAfterSilence: TimeInterval = 20
    static let knockTries = 8
    private static let doorsKey = "p2p.doors"
    private static let carriersKey = "p2p.carriers"

    init() {
        network.onChange = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.routeMayHaveChanged() } }
        }
        #if os(iOS)
        // A link going silent sends no status: the way to the Mac is looked at again every 2 s, and whether to knock.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.routeMayHaveChanged()
                self.considerKnock()
            }
        }
        #else
        // The door follows the sync host and the LAN interface; the router is kept open for an iPhone that is gone.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            while true {
                guard let self else { return }
                self.updateDoor()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        #endif
    }

    var isAvailable: Bool {
        #if canImport(Go2RTC)
        return true
        #else
        return false
        #endif
    }

    func status(_ peer: String, _ kind: P2PLinkKind) -> P2PLinkStatus? { statuses[Key(peer: peer, kind: kind)] }

    func unavailableReason(_ peer: String, _ kind: P2PLinkKind) -> String? { unavailable[Key(peer: peer, kind: kind)] }

    func needsServer(_ peer: String, _ kind: P2PLinkKind) -> Bool { needsServer.contains(Key(peer: peer, kind: kind)) }

    /// Some link that may still carry pings (the background grace is asked for it).
    var hasAliveLinks: Bool { statuses.values.contains(where: \.isAlive) }

    /// iPhone: the ports to reach `peer` through the `out` link, while that link answers.
    func directRoute(to peer: String) -> DirectRoute? {
        let key = Key(peer: peer, kind: .out)
        guard let handle = links[key], let ports = handle.ports, let status = statuses[key],
              status.outcome() == .direct(stale: false) else { return nil }
        return ports
    }

    /// iPhone: the home network can't reach `peer` now: no Wi-Fi, or the Wi-Fi link that worked has not answered for
    /// `homeSilence` (leaving home with Wi-Fi still on but too weak). A shorter hiccup keeps everything at home.
    func homeNetworkLooksGone(to peer: String) -> Bool {
        #if os(iOS)
        if network.lanInterface == nil { return true }
        guard let lan = statuses[Key(peer: peer, kind: .lan)], lan.everConnected else { return false }
        switch lan.outcome() {
        case .lost: return true
        case .direct(stale: true): return (lan.silence() ?? 0) > Self.homeSilence
        case .direct(stale: false), .checking, .failed: return false
        }
        #else
        return false
        #endif
    }

    /// iPhone: the Mac's door from the internet, as its last signal said.
    func doorAddress(_ peer: String) -> String? { doors[peer] }

    /// The iPhone's sync link and picture go over the `out` link to `peer` now.
    func carriesStreams(to peer: String) -> Bool {
        statuses[Key(peer: peer, kind: .out)]?.carriesStreams == true
    }

    /// Tells `onRouteChange` when what `SyncClient` decides by has changed.
    private func routeMayHaveChanged() {
        guard let peer = lastPeer else { return }
        let route = "\(directRoute(to: peer) != nil) \(homeNetworkLooksGone(to: peer))"
        guard route != lastRoute else { return }
        lastRoute = route
        onRouteChange?()
    }

    /// The peers with any status, for the Mac's list.
    func hasAny(_ peer: String) -> Bool {
        P2PLinkKind.allCases.contains { statuses[Key(peer: peer, kind: $0)] != nil }
    }

    // MARK: - iPhone: offering side

    /// Linked to `peer` over sync (that host understands p2p): starts each link that doesn't answer now — never made,
    /// failed, or silent (Wi-Fi was off, the app was away): the sync link can carry a new offer again.
    func startLinks(to peer: String) {
        if let lastPeer, lastPeer != peer { closeLinks(peer: lastPeer) } // another Mac now
        lastPeer = peer
        // Just back from the background: whether the links come back by themselves is being watched
        // (`didBecomeActive`), which then sets up the dead ones.
        let watching = lastResume != nil && lastResume?.survived == nil
        for kind in P2PLinkKind.allCases {
            let key = Key(peer: peer, kind: kind)
            if links[key] != nil, let status = statuses[key] {
                if watching && status.everConnected { continue }
                // The sync link this call came over may be riding it: a silent one comes back or fails by itself.
                if status.carriesStreams && status.isAlive { continue }
                switch status.outcome() {
                case .checking, .direct(stale: false): continue
                case .direct(stale: true), .failed, .lost: break
                }
            }
            start(key)
        }
    }

    /// «Проверить ещё раз»: a link that still answers sets up a new session over its own channel (no sync link needed:
    /// away from home too); one that doesn't starts anew over the sync link, if there is one.
    func recheck(_ peer: String, syncLinked: Bool) {
        for kind in P2PLinkKind.allCases {
            let key = Key(peer: peer, kind: kind)
            if let handle = links[key], statuses[key]?.state == "connected" {
                handle.restart()
            } else if syncLinked {
                start(key)
            } else if links[key] != nil || statuses[key] != nil {
                needsServer.insert(key)
            }
        }
    }

    private func start(_ key: Key, viaDoor knock: Bool = false) {
        close(key, keepStatus: false)
        unavailable[key] = nil
        needsServer.remove(key)
        viaDoor.remove(key)
        if knock { viaDoor.insert(key) }
        guard isAvailable else { unavailable[key] = String(localized: "Not in this build"); return }
        var options = Options(role: "offer", label: key.kind.rawValue, stun: Self.stunServers)
        switch key.kind {
        case .lan:
            options.interface = network.lanInterface ?? ""
            options.interfaces = ["en"]
        case .out:
            #if os(iOS)
            guard let cellular = network.cellularInterface else {
                unavailable[key] = network.cellularProblem ?? String(localized: "No cellular data")
                print("[p2p] out: not checked, \(unavailable[key] ?? "")")
                return
            }
            options.interface = cellular
            options.noPrivateHost = true
            #else
            return
            #endif
        }
        open(key, options: options, offer: true, forward: key.kind == .out)
    }

    // MARK: - Mac: answering side

    /// An offer or answer from `peer` over the sync link (or through the door: `throughDoor`).
    func handle(_ signal: SyncP2PSignal, from peer: String, throughDoor: Bool = false) {
        guard let kind = P2PLinkKind(rawValue: signal.link) else { return }
        let key = Key(peer: peer, kind: kind)
        #if os(iOS)
        if let address = signal.door, doors[peer] != address {
            doors[peer] = address
            UserDefaults.standard.set(doors, forKey: Self.doorsKey)
            print("[p2p] door: the Mac's is \(address)")
        }
        #else
        // The answer goes back the way the offer came.
        if !throughDoor { doorReturn[peer] = nil }
        #endif
        #if os(macOS)
        // An offer over the sync link is a new link, unless it is a restart of the live one whose channel was down
        // (gen > 0): that one sets its new session up next to the current one.
        if let head = try? JSONDecoder().decode(SignalHead.self, from: Data(signal.payload.utf8)), head.type == "offer",
           !(head.gen > 0 && links[key] != nil && statuses[key].map { $0.isAlive || $0.outcome() == .checking } == true) {
            var options = Options(role: "answer", label: kind.rawValue, stun: Self.stunServers)
            options.interface = network.lanInterface ?? ""
            options.interfaces = ["en", "bridge"]
            options.noPrivateHost = kind == .out
            options.services = servicesProvider?()
            open(key, options: options, offer: false)
            if router == nil { probeRouter() }
        }
        #endif
        guard let handle = links[key] else { return }
        handle.take(signal.payload)
    }

    /// Asks the router whether it could map a port (read-only), in the background.
    func probeRouter() {
        #if canImport(Go2RTC) && os(macOS)
        guard !isProbingRouter else { return }
        isProbingRouter = true
        Task.detached {
            let json = MobileP2PProbeRouter()
            let result = try? JSONDecoder().decode(P2PRouterResult.self, from: Data(json.utf8))
            await MainActor.run {
                self.router = result
                self.isProbingRouter = false
                print("[p2p] router: \(json)")
            }
        }
        #endif
    }

    // MARK: - Both

    func closeLinks(peer: String) {
        for kind in P2PLinkKind.allCases { close(Key(peer: peer, kind: kind), keepStatus: false) }
    }

    func closeAll() {
        for key in Array(links.keys) { close(key, keepStatus: true) }
    }

    private func close(_ key: Key, keepStatus: Bool) {
        links.removeValue(forKey: key)?.close()
        reported.remove(key)
        if !keepStatus {
            statuses[key] = nil
            needsServer.remove(key)
        }
        routeMayHaveChanged()
    }

    private func open(_ key: Key, options: Options, offer: Bool, forward: Bool = false) {
        close(key, keepStatus: false)
        #if canImport(Go2RTC)
        let handle = Handle(key: key, owner: self)
        do {
            try handle.open(options)
            links[key] = handle
            if forward { handle.forward() }
            if offer { try handle.start() }
            print("[p2p] \(key.kind.rawValue): \(offer ? "offering" : "answering")"
                  + (options.interface.isEmpty ? "" : " on \(options.interface)"))
        } catch {
            print("[p2p] \(key.kind.rawValue): \(error.localizedDescription)")
            var status = P2PLinkStatus(label: key.kind.rawValue, state: "failed")
            status.error = error.localizedDescription
            statuses[key] = status
        }
        #endif
    }

    fileprivate func received(_ status: P2PLinkStatus, from handle: Handle) {
        guard links[handle.key] === handle else { return } // a link replaced meanwhile
        let key = handle.key
        let wasCarrying = statuses[key]?.carriesStreams == true
        statuses[key] = status
        if status.isAlive { needsServer.remove(key) }
        log(key, status)
        if key.kind == .out, status.outcome() == .direct(stale: false) {
            #if os(macOS)
            noteCarrier(key.peer, status.remote)
            #else
            if viaDoor.contains(key), knocking != nil {
                print("[p2p] out: up again through the Mac's door")
                knocking = nil
                knockFailures = 0
                nextKnock = .distantPast
            }
            #endif
        }
        if status.carriesStreams != wasCarrying {
            print("[p2p] \(key.kind.rawValue): " + (status.carriesStreams
                ? "carries the sync link and the picture"
                : "carries nothing now (\(Int((status.bytesIn ?? 0) / 1000)) KB in, \(Int((status.bytesOut ?? 0) / 1000)) KB out so far)"))
        }
        routeMayHaveChanged()
        if !reported.contains(key) {
            switch status.outcome() {
            // Works once a ping came back (its round trip goes into the bubble).
            case .direct where status.answered, .failed:
                reported.insert(key)
                onFirstResult?(key, status)
            case .direct, .checking, .lost:
                break
            }
        }
    }

    fileprivate func signal(_ payload: String, from handle: Handle) {
        guard links[handle.key] === handle else { return }
        let key = handle.key
        var signal = SyncP2PSignal(link: key.kind.rawValue, payload: payload)
        #if os(macOS)
        // Every signal tells the iPhone where the door is (it may knock there later, with no other way to the Mac).
        signal.door = doorStatus?.external
        if let back = doorReturn[key.peer], Date().timeIntervalSince(back.at) < 60 {
            sendThroughDoor(signal, to: back.address, peer: key.peer, .macToPhone)
            return
        }
        #else
        if viaDoor.contains(key), let address = doors[key.peer] {
            print("[p2p] \(key.kind.rawValue): knocking at the Mac's door \(address)")
            sendThroughDoor(signal, to: address, peer: key.peer, .phoneToMac)
            return
        }
        #endif
        let sent = sendSignal?(handle.key.peer, signal) ?? false
        if !sent {
            print("[p2p] \(handle.key.kind.rawValue): no link to the peer for the signal")
            needsServer.insert(handle.key)
        }
    }

    /// One line per change of what matters (not per pong).
    private func log(_ key: Key, _ status: P2PLinkStatus) {
        var line = status.state
        if let pair = status.pairText { line += ", \(pair)" }
        if status.restarts ?? 0 > 0 { line += ", restart \(status.gen ?? 0) took over" }
        if let error = status.error { line += ", \(error)" }
        guard lastLogged[key] != line else { return }
        lastLogged[key] = line
        var detail = line
        if let rtt = status.rtt, rtt > 0 { detail += String(format: ", %.0f ms", rtt) }
        if let nat = status.nat, status.state == "connecting" {
            detail += ", NAT \(nat.mapping) via \(nat.answeredServers.joined(separator: " "))"
        }
        if let local = status.local, let remote = status.remote, status.state == "connected" {
            detail += " (\(local.address ?? "?"):\(local.port ?? 0) ↔ \(remote.address ?? "?"):\(remote.port ?? 0))"
        }
        print("[p2p] \(key.kind.rawValue): \(detail)")
    }

    // MARK: - Door

    /// Seals a signal for the peer and sends it from the door to `address`, three times (datagrams get lost; the
    /// other side takes it once).
    private func sendThroughDoor(_ signal: SyncP2PSignal, to address: String, peer: String,
                                 _ direction: P2PDoorSeal.Direction) {
        guard let door, let secret = pairingSecret?(peer), !secret.isEmpty,
              let sealed = try? P2PDoorSeal.seal(P2PDoorKnock(from: SyncIdentity.deviceID, signal: signal),
                                                 secret: secret, direction) else {
            print("[p2p] door: nothing to send \(signal.link) to \(address) with")
            return
        }
        door.send(sealed, to: address, after: [0, 0.7, 2])
    }

    /// A datagram at the door: a knock from a paired iPhone (Mac) or the Mac's answer (iPhone); anything that
    /// doesn't open with a pairing key, or was seen before, is dropped.
    fileprivate func doorReceived(_ payload: Data, from address: String) {
        #if os(macOS)
        for peer in pairedPeers?() ?? [] {
            guard let secret = pairingSecret?(peer), !secret.isEmpty,
                  let knock = try? P2PDoorSeal.open(payload, secret: secret, .phoneToMac) else { continue }
            guard doorGuard.accept(knock) else { return }
            print("[p2p] door: \(peer.prefix(8)) knocked from \(address) (\(knock.signal.link))")
            doorReturn[peer] = (address, Date())
            if let (ip, port) = Self.split(address) { noteCarrier(peer, P2PCandidate(type: "door", address: ip, port: port)) }
            handle(knock.signal, from: peer, throughDoor: true)
            return
        }
        #else
        guard let peer = knockTarget?() ?? lastPeer, let secret = pairingSecret?(peer),
              let knock = try? P2PDoorSeal.open(payload, secret: secret, .macToPhone), doorGuard.accept(knock) else { return }
        print("[p2p] door: the Mac answered from \(address)")
        handle(knock.signal, from: peer, throughDoor: true)
        #endif
    }

    fileprivate func doorChanged(_ status: P2PDoorStatus, from handle: DoorHandle) {
        guard door === handle else { return }
        doorStatus = status
    }

    private func closeDoor() {
        guard let door else { return }
        door.close()
        self.door = nil
        doorStatus = nil
        sprayingFor = nil
    }

    private static func split(_ address: String) -> (String, Int)? {
        guard let colon = address.lastIndex(of: ":"), let port = Int(address[address.index(after: colon)...]) else { return nil }
        return (String(address[..<colon]), port)
    }

    #if os(macOS)
    /// Every few seconds: the door is open while iPhones are let in (again on another LAN interface), and keeps the
    /// router open for the iPhone gone most recently, for `sprayFor` after it was last linked.
    private func updateDoor() {
        guard doorWanted?() == true, isAvailable else { closeDoor(); return }
        let interface = network.lanInterface ?? ""
        if door?.interface != interface {
            closeDoor()
            door = DoorHandle.open(port: Self.doorPort, interface: interface, stun: Self.stunServers, owner: self)
        }
        guard let door else { return }
        let now = Date()
        for peer in carriers.keys where isPeerLinked?(peer) == true || directRouteFresh(peer) { lastLinked[peer] = now }
        let gone = carriers.compactMap { peer, carrier -> (peer: String, carrier: P2PCarrierPorts, at: Date)? in
            let linked = max(lastLinked[peer] ?? .distantPast, carrier.seen)
            guard now.timeIntervalSince(linked) < Self.sprayFor, isPeerLinked?(peer) != true, !directRouteFresh(peer),
                  carrier.band != nil, !carrier.ip.contains(":") else { return nil }
            return (peer, carrier, linked)
        }.max { $0.at < $1.at }
        let band = gone?.carrier.band
        let wanted = gone.flatMap { target in band.map { "\(target.carrier.ip):\($0.lowerBound)-\($0.upperBound)" } }
        guard wanted != sprayingFor else { return }
        sprayingFor = wanted
        if let gone, let band, let wanted {
            print("[p2p] door: keeping the router open for \(wanted) while \(gone.peer.prefix(8)) is away")
            door.spray(ip: gone.carrier.ip, ports: band, every: Self.sprayEvery)
        } else {
            print("[p2p] door: the router is not kept open now")
            door.spray(ip: "", ports: 0...0, every: 0)
        }
    }

    /// The `out` link to this iPhone answers now.
    private func directRouteFresh(_ peer: String) -> Bool {
        statuses[Key(peer: peer, kind: .out)]?.outcome() == .direct(stale: false)
    }

    /// The carrier's address an iPhone's link came from (public IPv4 only), kept for spraying.
    private func noteCarrier(_ peer: String, _ remote: P2PCandidate?) {
        guard let ip = remote?.address, let port = remote?.port, !ip.contains(":"), !P2PAddress.isPrivate(ip) else { return }
        var carrier = carriers[peer] ?? P2PCarrierPorts(ip: ip, ports: [], seen: .distantPast)
        let before = carrier
        carrier.add(ip: ip, port: port)
        carriers[peer] = carrier
        lastLinked[peer] = Date()
        if carrier.ip != before.ip || carrier.ports != before.ports {
            if let data = try? JSONEncoder().encode(carriers) { UserDefaults.standard.set(data, forKey: Self.carriersKey) }
        }
    }
    #endif

    private static func loadCarriers() -> [String: P2PCarrierPorts] {
        guard let data = UserDefaults.standard.data(forKey: carriersKey) else { return [:] }
        return (try? JSONDecoder().decode([String: P2PCarrierPorts].self, from: data)) ?? [:]
    }

    #if os(iOS)
    /// Every 2 s in the foreground: with no link to the Mac it rejoins on its own — not over the home network, not
    /// seen there, its `out` link gone, failed or silent for `knockAfterSilence` — a new `out` link is offered
    /// through the Mac's door (known from its last signals), at most every 15 s doubling to 2 min while it fails.
    private func considerKnock() {
        guard isAvailable, backgroundSince == nil, Date().timeIntervalSince(launchedAt) > 5 else { return }
        if isLinkedOverLAN?() == true {
            if door != nil { print("[p2p] door: home again, closed") }
            closeDoor()
            knocking = nil
            knockFailures = 0
            nextKnock = .distantPast
            return
        }
        guard let peer = knockTarget?(), seesOnLAN?(peer) != true, let address = doors[peer],
              pairingSecret?(peer)?.isEmpty == false, let cellular = network.cellularInterface else { return }
        let key = Key(peer: peer, kind: .out)
        if links[key] != nil, let status = statuses[key] {
            switch status.outcome() {
            case .checking, .direct(stale: false): return
            case .direct(stale: true): if (status.silence() ?? 0) < Self.knockAfterSilence { return }
            case .lost, .failed: break
            }
        }
        // A Mac that is off or asleep never answers: after `knockTries` the iPhone waits until the app is opened again.
        guard Date() >= nextKnock, knockFailures < Self.knockTries else { return }
        if door?.interface != cellular {
            closeDoor()
            door = DoorHandle.open(port: 0, interface: cellular, stun: [], owner: self)
        }
        guard door != nil else { return }
        lastPeer = peer
        knocking = peer
        print("[p2p] out: no link to the Mac and no home network: a new one through its door \(address)"
              + (knockFailures > 0 ? " (try \(knockFailures + 1))" : ""))
        start(key, viaDoor: true)
        nextKnock = Date().addingTimeInterval(min(120, 15 * pow(2, Double(knockFailures))))
        knockFailures += 1
    }
    #endif

    // MARK: - Background (iPhone)

    func didEnterBackground() {
        backgroundSince = Date()
    }

    /// Back in the foreground: after a few seconds, which links answered since the return. `syncLinked`: the sync
    /// link to that peer is up over the home network, so a dead link can be set up anew; otherwise it waits for one
    /// (`needsServer`). A sync link through the direct link doesn't count: it can't carry the offer of its own link.
    func didBecomeActive(peer: String?, syncLinked: @escaping () -> Bool) {
        guard let since = backgroundSince else { return }
        backgroundSince = nil
        knockFailures = 0
        nextKnock = .distantPast
        let back = Date()
        let away = back.timeIntervalSince(since)
        guard away > 2, let peer else { return }
        let alive = P2PLinkKind.allCases.filter { statuses[Key(peer: peer, kind: $0)]?.everConnected == true }
        guard !alive.isEmpty else { return }
        lastResume = Resume(at: back, away: away, survived: nil)
        print(String(format: "[p2p] back after %.0f s in the background", away))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.lastResume?.at == back else { return }
            var survived: [P2PLinkKind: Bool] = [:]
            for kind in alive {
                let key = Key(peer: peer, kind: kind)
                let pong = (self.statuses[key]?.lastPong ?? 0) / 1000
                survived[kind] = pong > back.timeIntervalSince1970
                print("[p2p] \(kind.rawValue): \(survived[kind] == true ? "survived" : "did not survive") \(Int(away)) s in the background")
                guard survived[kind] == false else { continue }
                // Not answering yet is not dead: the link keeps checking for FailedTimeout and comes back by itself
                // once the network does. One the sync link or the picture rides on stays: a new one's offer would
                // have to travel over it, and away from home there is no other way (2026-11-13: a 5 s cellular blip,
                // then this replaced the live link and the iPhone lost the Mac for good).
                if let status = self.statuses[key], status.isAlive, status.carriesStreams {
                    print("[p2p] \(kind.rawValue): kept, the sync link and the picture go over it")
                    continue
                }
                if syncLinked() { self.start(key) } else { self.needsServer.insert(key) }
            }
            self.lastResume?.survived = survived
        }
    }

    #if DEBUG
    /// `--demo-p2p[=failed|away]`: statuses as if the links had been made (UI checks, no network).
    func demo(peer: String, variant: String) {
        lastPeer = peer
        var lan = P2PLinkStatus(label: "lan", state: "connected")
        lan.local = P2PCandidate(type: "host", address: "192.168.100.231", port: 53_211)
        lan.remote = P2PCandidate(type: "host", address: "192.168.100.40", port: 61_002)
        lan.rtt = 4.2
        lan.rttMin = 2.9
        lan.connectedAt = Date().timeIntervalSince1970 * 1000 - 60_000
        lan.lastPong = Date().timeIntervalSince1970 * 1000 + 86_400_000 // stays fresh for a screenshot
        lan.nat = P2PNATResult(mapping: "independent", public: "87.116.135.237:15261")
        lan.peerNat = lan.nat
        var out = lan
        out.label = "out"
        out.local = P2PCandidate(type: "srflx", address: "176.59.20.7", port: 40_112)
        out.remote = P2PCandidate(type: "prflx", address: "87.116.135.237", port: 15_261)
        out.rtt = 48
        out.rttMin = 41
        out.nat = P2PNATResult(mapping: "dependent", public: "176.59.20.7:40112")
        #if os(macOS)
        swap(&out.nat, &out.peerNat)
        out.local = P2PCandidate(type: "srflx", address: "87.116.135.237", port: 15_261)
        out.remote = P2PCandidate(type: "prflx", address: "176.59.20.7", port: 40_112)
        router = P2PRouterResult(gateway: "192.168.100.1", pmp: .init(error: "no answer"), upnp: .init(error: "no answer"))
        #endif
        if variant == "failed" {
            out.state = "failed"
            out.connectedAt = nil
            out.local = nil
            out.remote = nil
            out.error = "no direct path"
        } else if variant == "away" {
            out.state = "failed"
            out.error = "ICE failed"
            needsServer.insert(Key(peer: peer, kind: .out))
            lan.state = "failed"
            lastResume = Resume(at: Date(), away: 95, survived: [.lan: false, .out: false])
        } else if variant == "checking" {
            out.state = "connecting"
            out.connectedAt = nil
            out.local = nil
            out.remote = nil
        }
        statuses[Key(peer: peer, kind: .lan)] = lan
        statuses[Key(peer: peer, kind: .out)] = out
    }
    #endif

    // MARK: - Go

    /// What Swift reads of a signal (`GoMobile/p2p` Signal).
    private struct SignalHead: Decodable {
        var type: String
        var gen: Int
    }

    /// The Go side's options (`GoMobile/p2p` Options).
    struct Options: Encodable {
        var role: String
        var label: String
        var stun: [String]
        var interface = ""
        var interfaces: [String] = []
        var noPrivateHost = false
        var pingInterval: Double = 2
        var connectTimeout: Double = 25
        var failedTimeout: Double = 600
        var services: [String: String]?
    }
}

/// One Go link with its events bridge.
@MainActor
private final class Handle {
    let key: P2PLinks.Key
    weak var owner: P2PLinks?
    /// The ports forwarded to the peer's services (iPhone, `out` link).
    private(set) var ports: P2PLinks.DirectRoute?
    #if canImport(Go2RTC)
    private var link: MobileP2PLink?
    private var bridge: Bridge?
    #endif

    init(key: P2PLinks.Key, owner: P2PLinks) {
        self.key = key
        self.owner = owner
    }

    #if canImport(Go2RTC)
    func open(_ options: P2PLinks.Options) throws {
        let json = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        let bridge = Bridge(handle: self)
        var error: NSError?
        guard let link = MobileNewP2PLink(json, bridge, &error) else {
            throw error ?? CocoaError(.featureUnsupported)
        }
        self.link = link
        self.bridge = bridge
    }

    func start() throws { try link?.start() }

    /// Local ports for the Mac's sync listener and go2rtc, carried over this link (before `start`: they only answer
    /// once it is up).
    func forward() {
        guard let link else { return }
        let sync = link.forward("sync"), go2rtc = link.forward("go2rtc")
        if sync > 0, go2rtc > 0 { ports = P2PLinks.DirectRoute(sync: sync, go2rtc: go2rtc) }
    }

    func take(_ payload: String) {
        let link = self.link
        let kind = key.kind.rawValue
        // Setting a description waits on pion's own loop: not on the main thread.
        Task.detached {
            do { try link?.handleSignal(payload) } catch { print("[p2p] \(kind): \(error.localizedDescription)") }
        }
    }

    func restart() {
        let link = self.link
        Task.detached { try? link?.restart() }
    }

    func close() {
        let link = self.link
        self.link = nil
        bridge = nil
        Task.detached { link?.close() }
    }
    #else
    func close() {}
    func restart() {}
    func take(_ payload: String) {}
    #endif

    /// The newest status taken: one sent earlier but arriving later is dropped.
    private var lastSeq: UInt64 = 0

    fileprivate func received(state json: String) {
        guard let status = P2PLinkStatus.decode(json) else { return }
        if let seq = status.seq {
            guard seq > lastSeq else { return }
            lastSeq = seq
        }
        owner?.received(status, from: self)
    }

    fileprivate func received(signal payload: String) {
        owner?.signal(payload, from: self)
    }
}

#if canImport(Go2RTC)
/// The Go side's callbacks (on its goroutines), taken to the main actor.
private final class Bridge: NSObject, MobileP2PEventsProtocol {
    private weak var handle: Handle?

    init(handle: Handle) {
        self.handle = handle
    }

    // The main queue keeps them in order (a status must not overtake a newer one).
    func signal(_ message: String?) {
        guard let message else { return }
        DispatchQueue.main.async { [weak handle] in MainActor.assumeIsolated { handle?.received(signal: message) } }
    }

    func state(_ status: String?) {
        guard let status else { return }
        DispatchQueue.main.async { [weak handle] in MainActor.assumeIsolated { handle?.received(state: status) } }
    }
}
#endif

/// The Go door (`GoMobile/p2p` door.go) with its events bridge.
@MainActor
private final class DoorHandle {
    let interface: String
    weak var owner: P2PLinks?
    #if canImport(Go2RTC)
    private var door: MobileP2PDoor?
    private var bridge: DoorBridge?
    #endif

    private init(interface: String, owner: P2PLinks) {
        self.interface = interface
        self.owner = owner
    }

    /// Opens a door on `port` (0: any; taken if free, else any) bound to `interface`; nil when it can't.
    static func open(port: Int, interface: String, stun: [String], owner: P2PLinks) -> DoorHandle? {
        #if canImport(Go2RTC)
        struct Options: Encodable {
            var port: Int
            var interface: String
            var stun: [String]
            var keepAlive: Double
        }
        let handle = DoorHandle(interface: interface, owner: owner)
        let options = Options(port: port, interface: interface, stun: stun, keepAlive: stun.isEmpty ? -1 : 25)
        guard let json = try? JSONEncoder().encode(options) else { return nil }
        let bridge = DoorBridge(handle: handle)
        var error: NSError?
        guard let door = MobileNewP2PDoor(String(decoding: json, as: UTF8.self), bridge, &error) else {
            print("[p2p] door: \(error?.localizedDescription ?? "not opened")")
            return nil
        }
        handle.door = door
        handle.bridge = bridge
        if let status = P2PDoorStatus.decode(door.status()) {
            print("[p2p] door open on \(status.local)" + (interface.isEmpty ? "" : " (\(interface))"))
            owner.doorChanged(status, from: handle)
        }
        return handle
        #else
        return nil
        #endif
    }

    func send(_ data: Data, to address: String, after delays: [Double]) {
        #if canImport(Go2RTC)
        let door = self.door
        Task.detached {
            var waited = 0.0
            for delay in delays {
                if delay > waited { try? await Task.sleep(for: .seconds(delay - waited)) }
                waited = delay
                do { try door?.send(address, payload: data) } catch { print("[p2p] door: \(error.localizedDescription)") }
            }
        }
        #endif
    }

    func spray(ip: String, ports: ClosedRange<Int>, every: Double) {
        #if canImport(Go2RTC)
        do { try door?.spray(ip, from: ports.lowerBound, to: ports.upperBound, every: every) } catch {
            print("[p2p] door: \(error.localizedDescription)")
        }
        #endif
    }

    func close() {
        #if canImport(Go2RTC)
        let door = self.door
        self.door = nil
        bridge = nil
        Task.detached { door?.close() }
        #endif
    }

    fileprivate func received(_ payload: Data, from address: String) { owner?.doorReceived(payload, from: address) }

    fileprivate func received(state json: String) {
        guard let status = P2PDoorStatus.decode(json) else { return }
        owner?.doorChanged(status, from: self)
    }
}

#if canImport(Go2RTC)
private final class DoorBridge: NSObject, MobileP2PDoorEventsProtocol {
    private weak var handle: DoorHandle?

    init(handle: DoorHandle) {
        self.handle = handle
    }

    func datagram(_ from: String?, payload: Data?) {
        guard let from, let payload else { return }
        DispatchQueue.main.async { [weak handle] in MainActor.assumeIsolated { handle?.received(payload, from: from) } }
    }

    func state(_ status: String?) {
        guard let status else { return }
        DispatchQueue.main.async { [weak handle] in MainActor.assumeIsolated { handle?.received(state: status) } }
    }
}
#endif

/// Which interfaces the links bind to, from Network.framework: the iPhone's Wi-Fi and cellular ones (cellular can be
/// used while Wi-Fi is up, unless cellular data is off or not allowed for the app), the Mac's LAN one (Ethernet or
/// Wi-Fi; never a VPN tunnel, so the home router's NAT is the one tested).
final class P2PNetwork: @unchecked Sendable {
    private let queue = DispatchQueue(label: "p2p.network")
    private let lock = NSLock()
    private var monitors: [NWPathMonitor] = []
    private var _lan: String?
    private var _cellular: String?
    private var _cellularProblem: String?
    private var _onChange: (() -> Void)?
    /// Called (on its own queue) when an interface comes or goes.
    var onChange: (() -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }

    var lanInterface: String? { lock.withLock { _lan } }
    var cellularInterface: String? { lock.withLock { _cellular } }
    var cellularProblem: String? { lock.withLock { _cellularProblem } }

    init() {
        #if os(iOS)
        watch(NWPathMonitor(requiredInterfaceType: .wifi)) { path, network in
            network._lan = path.status == .satisfied ? path.availableInterfaces.first { $0.type == .wifi }?.name : nil
        }
        watch(NWPathMonitor(requiredInterfaceType: .cellular)) { path, network in
            if path.status == .satisfied, let cellular = path.availableInterfaces.first(where: { $0.type == .cellular }) {
                network._cellular = cellular.name
                network._cellularProblem = nil
            } else {
                network._cellular = nil
                network._cellularProblem = path.unsatisfiedReason == .cellularDenied
                    ? String(localized: "Cellular data is off for Waiting Paws")
                    : String(localized: "No cellular data")
            }
        }
        #else
        watch(NWPathMonitor()) { path, network in
            network._lan = path.availableInterfaces.first { $0.type == .wiredEthernet || $0.type == .wifi }?.name
        }
        #endif
    }

    private func watch(_ monitor: NWPathMonitor, update: @escaping (NWPath, P2PNetwork) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let onChange = self.lock.withLock {
                update(path, self)
                return self._onChange
            }
            onChange?()
        }
        monitor.start(queue: queue)
        monitors.append(monitor)
    }
}
