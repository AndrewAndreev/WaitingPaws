#if os(iOS)
import Foundation
import Network
import Observation
import WaitingPawsCore

/// iPhone side of the link: finds computers running Waiting Paws on the local network (Macs; Windows PCs once
/// the port exists), joins the one the user picks (its user allows it once), then exposes its go2rtc for the
/// camera view and mirrors its session. Hosts are told apart by their id (`SyncDevice`), so two Macs with the
/// same name, or a renamed one, keep their own pairing.
@MainActor
@Observable
final class SyncClient {
    struct DiscoveredHost: Identifiable, Equatable {
        var id: String { device.id }
        let endpoint: NWEndpoint
        let info: SyncHostInfo
        var device: SyncDevice { info.device }
        var isCompatible: Bool { info.version == SyncProtocol.version }
    }

    /// A host this iPhone has joined (its pairing secret is in the keychain): listed with «Забыть» also when away.
    struct PairedHost: Codable, Identifiable, Equatable {
        let id: String
        var name: String
        var platform: String?
        var model: String
        var lastConnected: Date

        var device: SyncDevice {
            SyncDevice(id: id, name: name, kind: platform.map { SyncPlatform(rawValue: $0) } ?? .mac, model: model)
        }
    }

    enum Status: Equatable {
        case idle
        case connecting(SyncDevice)
        /// The host shows "Разрешить / Отклонить".
        case waitingApproval(SyncDevice)
        case connected(SyncDevice)
        case failed(String)
    }

    /// Everything advertising Waiting Paws nearby, by name.
    private(set) var hosts: [DiscoveredHost] = []
    private(set) var pairedHosts: [PairedHost] = []
    private(set) var status: Status = .idle
    private(set) var state: SyncState?
    /// How far this iPhone's clock is from the host's (from the states' `sentAt`); new for every link (kept while
    /// `reconnecting` to the same host).
    @ObservationIgnored private(set) var clock = SyncClock()
    /// The host's go2rtc (LAN address + Basic auth) once connected; through the direct link a local port that the
    /// link forwards to it.
    private(set) var server: Go2RTCServer?

    /// How this iPhone reaches the host: over the home network, or through the direct link (`P2PLinks`) when the home
    /// network is gone — the sync link and the camera's picture both go over it then.
    enum Route: String {
        case lan
        case direct
    }

    private(set) var route: Route = .lan
    /// The direct link's local ports to the host with this id, while that link answers (`P2PLinks.directRoute`).
    @ObservationIgnored var directRoute: (String) -> P2PLinks.DirectRoute? = { _ in nil }
    /// The home network can't reach the host with this id now: no Wi-Fi, or the Wi-Fi direct link went silent.
    @ObservationIgnored var homeNetworkGone: (String) -> Bool = { _ in false }
    /// Wi-Fi is up (the home network is worth trying again when the host shows up on it).
    @ObservationIgnored var hasWiFi: () -> Bool = { true }
    /// Joined the same host the other way than before (the bubble says so).
    @ObservationIgnored var onRouteChanged: ((Route) -> Void)?
    /// The way and the forwarded ports of the connection being made (`route` once it is joined).
    @ObservationIgnored private var connectingRoute: Route = .lan
    @ObservationIgnored private var connectingPorts: P2PLinks.DirectRoute?
    /// The home network failed, or was left for the direct link: not tried again before this.
    @ObservationIgnored private var lanBackoffUntil = Date.distantPast
    /// While joined through the direct link: looks for the home network again now and then (Bonjour may not report a
    /// host that never went from its list).
    @ObservationIgnored private var routeCheck: Task<Void, Never>?
    /// The host whose link dropped mid-training (Wi-Fi blip, its app restarting) while this iPhone joins it again on
    /// its own: its last `state` and `server` stay meanwhile, so the training stays on screen (`onState` is not called).
    /// Given up after `reconnectGrace`, by «Отключить синхронизацию» or when the host turns this iPhone away.
    private(set) var reconnecting: SyncDevice?
    /// Counts the links made (also one restored after a drop; not a welcome sent again on the same link): the next
    /// state is the first of a new link.
    @ObservationIgnored private(set) var links = 0
    @ObservationIgnored private var reconnectTimeout: Task<Void, Never>?
    private static let reconnectGrace: Duration = .seconds(120)

    /// Called with every state from the host, and with nil when the link is gone (not while `reconnecting`).
    @ObservationIgnored var onState: ((SyncState?) -> Void)?
    /// Joined a host (also again after a drop) that understands the direct link (`SyncFeature.p2p`): its id.
    @ObservationIgnored var onP2PHost: ((String) -> Void)?
    /// A direct link's signal from the host (its id).
    @ObservationIgnored var onP2PSignal: ((SyncP2PSignal, String) -> Void)?
    /// The user stopped syncing with this host, or forgot it (its id): its direct links go too.
    @ObservationIgnored var onStopped: ((String) -> Void)?
    /// What the host joined understands beyond protocol v2 (its welcome's `features`).
    @ObservationIgnored private var hostFeatures: [String] = []
    /// This iPhone's name for the hosts (Settings, or the model).
    @ObservationIgnored var nameProvider: () -> String = { SyncIdentity.systemName }

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var channel: SyncChannel?
    /// This connection's key exchange (see `SyncCrypto`).
    @ObservationIgnored private var privateKey = SyncCrypto.newKey()
    @ObservationIgnored private var handshake: SyncCrypto.Handshake?
    /// No valid pairing secret on this connection: the host asked for «Разрешить», a new secret comes with welcome.
    @ObservationIgnored private var freshPairing = false
    /// The user picked the host for this connection. Only then may a host that doesn't recognise this iPhone ask for
    /// «Разрешить»: joining on our own never pairs anew (the host is found by the public id in its Bonjour record).
    @ObservationIgnored private var startedByUser = false
    /// Where the secret offered on this connection came from (an older key is moved under the host's id once it works).
    @ObservationIgnored private var offeredSecretKey: String?
    /// Reconnect to this host whenever it shows up, also after a relaunch of either app (set after a successful
    /// connection, cleared by «Отключить синхронизацию» and by a rejection).
    @ObservationIgnored private var autoReconnectID: String? = UserDefaults.standard.string(forKey: SyncClient.autoConnectKey) {
        didSet { UserDefaults.standard.set(autoReconnectID, forKey: Self.autoConnectKey) }
    }
    /// Builds before host ids remembered the Mac by name; used until that Mac is joined again.
    @ObservationIgnored private var legacyAutoReconnectName: String? = UserDefaults.standard.string(forKey: SyncClient.legacyAutoConnectKey) {
        didSet { UserDefaults.standard.set(legacyAutoReconnectName, forKey: Self.legacyAutoConnectKey) }
    }
    private static let autoConnectKey = "sync.autoConnectHost"
    private static let legacyAutoConnectKey = "sync.autoConnectMac"
    private static let pairedHostsKey = "sync.pairedHosts"
    /// Whether joining a host on our own is fine right now: not while this iPhone runs its own training or recording.
    @ObservationIgnored var canAutoConnect: () -> Bool = { true }
    @ObservationIgnored private var loggedHosts: [String] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.pairedHostsKey),
           let hosts = try? JSONDecoder().decode([PairedHost].self, from: data) {
            pairedHosts = hosts
        }
    }

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    /// Connected, or getting back to the host whose link dropped mid-training (its last state still shows).
    var isLinked: Bool { isConnected || reconnecting != nil }

    var isBusy: Bool {
        switch status {
        case .connecting, .waitingApproval: return true
        default: return false
        }
    }

    /// The host linked, or being linked to.
    var host: SyncDevice? {
        switch status {
        case .connecting(let device), .waitingApproval(let device), .connected(let device): return device
        case .idle, .failed: return nil
        }
    }

    /// Hosts this build can join, the likely choice first: the one this iPhone reconnects to, one with a training
    /// running, one joined before, one with its camera ready.
    var compatibleHosts: [DiscoveredHost] {
        hosts.filter(\.isCompatible).sorted { rank($0) < rank($1) }
    }

    var preferredHost: DiscoveredHost? { compatibleHosts.first }

    private func rank(_ host: DiscoveredHost) -> (Int, Int, Int, Int, String) {
        (isAutoReconnectTarget(host) ? 0 : 1, host.info.sessionRunning ? 0 : 1, isPaired(host.device) ? 0 : 1,
         host.info.cameraReady ? 0 : 1, host.device.name)
    }

    /// A host this iPhone has joined before (a pairing secret is stored for it).
    func isPaired(_ host: SyncDevice) -> Bool {
        pairedHosts.contains { $0.id == host.id } || secret(for: host) != nil
    }

    func isNearby(_ hostID: String) -> Bool {
        hosts.contains { $0.id == hostID }
    }

    private func isAutoReconnectTarget(_ host: DiscoveredHost) -> Bool {
        if let autoReconnectID { return host.id == autoReconnectID }
        return legacyAutoReconnectName != nil && host.device.name == legacyAutoReconnectName
    }

    // MARK: - Discovery

    func startBrowsing() {
        guard browser == nil else { return }
        #if DEBUG
        // `--sync-host 127.0.0.1:11986`: connect straight to a Mac (no Bonjour), for checks in the simulator.
        if let index = CommandLine.arguments.firstIndex(of: "--sync-host"), index + 1 < CommandLine.arguments.count {
            let parts = CommandLine.arguments[index + 1].split(separator: ":")
            if parts.count == 2, let port = NWEndpoint.Port(String(parts[1])) {
                let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(String(parts[0])), port: port)
                connect(to: DiscoveredHost(endpoint: endpoint, info: SyncHostInfo(name: "Mac (debug)")))
            }
        }
        #endif
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: SyncProtocol.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                // E.g. -65569 DefunctConnection after the app was suspended: a failed browser never finds anything
                // again, so start a new one.
                print("[sync] browse failed: \(error), restarting")
                MainActor.assumeIsolated { self?.restartBrowsing() }
            case .waiting(let error):
                print("[sync] browse waiting: \(error)")
            default:
                break
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func restartBrowsing() {
        browser?.cancel()
        browser = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.startBrowsing()
        }
    }

    /// Joins the host this iPhone was linked to, if it is around and nothing here is in the way: over the home
    /// network, or through the direct link when the home network can't reach it.
    func autoConnectIfPossible() {
        guard channel == nil, autoReconnectID != nil || legacyAutoReconnectName != nil, canAutoConnect() else { return }
        if let host = hosts.first(where: isAutoReconnectTarget), lanWorthTrying(host.id) {
            print("[sync] reconnecting to \(host.device.name)")
            connect(to: host, byUser: false)
        } else if let direct = directHost() {
            print("[sync] reconnecting to \(direct.host.device.name) over the direct link")
            connect(to: direct.host, byUser: false, route: .direct, ports: direct.ports)
        }
    }

    /// The direct link or the home network came or went: the joined host is reached the better way now (the training
    /// stays on screen meanwhile), or joined if nothing links to it.
    func reconsiderRoute() {
        if channel == nil {
            autoConnectIfPossible()
            return
        }
        if case .connecting(let device) = status, connectingRoute == .lan, !startedByUser {
            // A rejoin over the home network that hangs with no path to it: through the direct link instead.
            guard homeNetworkGone(device.id), let direct = directHost(), direct.host.id == device.id else { return }
            print("[sync] \(device.name): no home network, joining it over the direct link")
            channel?.cancel()
            channel = nil
            connect(to: direct.host, byUser: false, route: .direct, ports: direct.ports)
            return
        }
        guard case .connected(let device) = status else { return } // mid-handshake: it finishes or fails first
        switch route {
        case .lan:
            guard homeNetworkGone(device.id), let direct = directHost(), direct.host.id == device.id else { return }
            // Left because Wi-Fi went silent while still up (the edge of its range): not straight back to it. Wi-Fi
            // turned off and on again is used as soon as the Mac shows up on it.
            if hasWiFi() { lanBackoffUntil = Date().addingTimeInterval(60) }
            switchRoute(to: direct.host, route: .direct, ports: direct.ports, why: "the home network is gone")
        case .direct:
            guard hasWiFi(), Date() >= lanBackoffUntil, let host = hosts.first(where: { $0.id == device.id }) else { return }
            switchRoute(to: host, route: .lan, ports: nil, why: "back on the home network")
        }
    }

    /// Without the direct link the home network is the only way; with it, only while it may work.
    private func lanWorthTrying(_ hostID: String) -> Bool {
        directRoute(hostID) == nil || (hasWiFi() && !homeNetworkGone(hostID) && Date() >= lanBackoffUntil)
    }

    /// The host to rejoin as reached through the direct link: its forwarded sync port on this iPhone.
    private func directHost() -> (host: DiscoveredHost, ports: P2PLinks.DirectRoute)? {
        guard let id = autoReconnectID, let ports = directRoute(id),
              let paired = pairedHosts.first(where: { $0.id == id }),
              let url = URL(string: "ws://127.0.0.1:\(ports.sync)/") else { return nil }
        let info = SyncHostInfo(name: paired.name, id: paired.id, platform: paired.platform, model: paired.model)
        // A URL, not `.hostPort`: Network.framework's WebSocket client aborts a connection to an IP-address host:port
        // before sending anything ("Software caused connection abort"); with a ws:// URL it goes.
        return (DiscoveredHost(endpoint: .url(url), info: info), ports)
    }

    /// Joins the same host the other way; its state and picture stay on screen until the new link's welcome.
    private func switchRoute(to target: DiscoveredHost, route newRoute: Route, ports: P2PLinks.DirectRoute?, why: String) {
        guard case .connected(let device) = status else { return }
        print("[sync] \(device.name): \(why), joining it \(newRoute == .direct ? "over the direct link" : "over the home network")")
        channel?.cancel()
        channel = nil
        startReconnecting(device, log: false)
        status = .idle
        connect(to: target, byUser: false, route: newRoute, ports: ports)
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        hosts = results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata { txt = record.dictionary }
            return DiscoveredHost(endpoint: result.endpoint, info: SyncHostInfo(name: name, txt: txt))
        }
        .sorted { $0.device.name.localizedStandardCompare($1.device.name) == .orderedAscending }
        let names = hosts.map { host in
            var line = "\(host.device.name) [\(host.device.modelTitle), \(host.id.prefix(13))]"
            if isPaired(host.device) { line += " (paired)" }
            if !host.isCompatible { line += " (v\(host.info.version))" }
            return line
        }
        if names != loggedHosts {
            loggedHosts = names
            print("[sync] hosts nearby: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        }
        autoConnectIfPossible()
        if route == .direct { reconsiderRoute() } // the host showed up on the home network again
        #if DEBUG
        // `--sync-auto-connect`: join the first host found (UI checks in the simulator without taps).
        if channel == nil, status == .idle, CommandLine.arguments.contains("--sync-auto-connect"), let host = preferredHost {
            connect(to: host)
        }
        #endif
    }

    // MARK: - Connection

    /// `byUser`: the user picked this host (see `startedByUser`); false when this iPhone rejoins one on its own.
    /// `route` `.direct`: `host` is the direct link's forwarded sync port, `ports` its forwarded ports.
    func connect(to host: DiscoveredHost, byUser: Bool = true, route: Route = .lan, ports: P2PLinks.DirectRoute? = nil) {
        channel?.cancel()
        connectingRoute = route
        connectingPorts = route == .direct ? ports : nil
        // Switching from another host: its state and camera go away first (the new one greets like a fresh link).
        if isConnected || (reconnecting != nil && reconnecting?.id != host.id) { reset(to: .idle) }
        let channel = SyncChannel(connection: NWConnection(to: host.endpoint, using: SyncWebSocket.parameters()))
        self.channel = channel
        privateKey = SyncCrypto.newKey()
        handshake = nil
        freshPairing = false
        offeredSecretKey = nil
        startedByUser = byUser
        status = .connecting(host.device)
        let kind = host.device.kindTitle
        channel.onStateChange = { [weak self, weak channel] state in
            guard let self, let channel, channel === self.channel else { return }
            switch state {
            case .ready:
                channel.send(.hello(SyncHello(deviceID: SyncIdentity.deviceID, deviceName: self.nameProvider(),
                                              publicKey: self.privateKey.publicKey.rawRepresentation,
                                              platform: SyncIdentity.platform.rawValue, model: SyncIdentity.model,
                                              features: [SyncFeature.p2p])))
            case .failed(let error):
                self.lost(String(localized: "No connection to the \(kind): \(error.localizedDescription)"))
            case .waiting(let error) where route == .direct:
                // The direct link's local port can't be waited for like a network that may come back (that is what
                // `.waiting` means): the link went, or the connection broke. Joined again, as after a failure.
                print("[sync] over the direct link: \(error.localizedDescription)")
                self.lost(String(localized: "No connection to the \(kind): \(error.localizedDescription)"))
            case .cancelled:
                if self.isConnected || self.isBusy { self.lost(String(localized: "The \(kind) disconnected")) }
            default:
                break
            }
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel, channel === self.channel else { return }
            self.handle(message, from: host, channel: channel)
        }
        channel.start()
    }

    /// "Отключиться": stop mirroring and don't reconnect on our own.
    func disconnect() {
        if let id = host?.id ?? reconnecting?.id { onStopped?(id) }
        autoReconnectID = nil
        legacyAutoReconnectName = nil
        channel?.cancel()
        channel = nil
        reset(to: .idle)
    }

    /// «Забыть»: drop the pairing secret, so joining this host again needs «Разрешить» there.
    func forget(_ hostID: String) {
        if host?.id == hostID || reconnecting?.id == hostID { disconnect() }
        onStopped?(hostID)
        KeychainStore.set("", for: Self.secretKey(hostID))
        if let name = pairedHosts.first(where: { $0.id == hostID })?.name { KeychainStore.set("", for: Self.legacySecretKey(name)) }
        pairedHosts.removeAll { $0.id == hostID }
        savePairedHosts()
        if autoReconnectID == hostID { autoReconnectID = nil }
        print("[sync] forgot host \(hostID.prefix(13))")
    }

    func send(_ command: SyncCommand) {
        #if DEBUG
        if demoMac != nil { return demoMacReceive(command) }
        #endif
        channel?.send(.command(command))
    }

    /// A direct link's signal to the host `hostID`, if it is the one joined now and understands it.
    func sendP2P(_ signal: SyncP2PSignal, to hostID: String) -> Bool {
        guard case .connected(let device) = status, device.id == hostID, hostFeatures.contains(SyncFeature.p2p),
              let channel else { return false }
        channel.send(.p2p(signal))
        return true
    }

    private func handle(_ message: SyncMessage, from host: DiscoveredHost, channel: SyncChannel) {
        switch message {
        case .challenge(let hostKey):
            guard handshake == nil else { return }
            let phoneKey = privateKey.publicKey.rawRepresentation
            guard let handshake = try? SyncCrypto.Handshake(privateKey: privateKey, peerKey: hostKey, phoneKey: phoneKey,
                                                            macKey: hostKey, deviceID: SyncIdentity.deviceID) else {
                lost(String(localized: "No connection to the \(host.device.kindTitle)"))
                return
            }
            self.handshake = handshake
            let stored = storedSecret(for: host.device)
            offeredSecretKey = stored?.key
            freshPairing = stored == nil
            channel.cipher = handshake.cipher(isMac: false, pairingSecret: stored?.secret)
            channel.send(.proof(stored.map { handshake.proof(pairingSecret: $0.secret) }))
        case .pending:
            // Only an answer to our proof, before the welcome, means anything.
            guard let handshake, !isConnected else {
                print("[sync] \(host.device.name) sent pending out of turn, ignored")
                return
            }
            guard startedByUser else {
                // Joining on our own: a host that doesn't recognise this iPhone (forgotten there — or another device
                // posing under its id) gets no new pairing. The stored secret stays; picking the host in the list
                // pairs anew, with «Разрешить» there.
                print("[sync] \(host.device.name) did not recognise this iPhone, not pairing again on our own")
                autoReconnectID = nil
                legacyAutoReconnectName = nil
                self.channel?.cancel()
                self.channel = nil
                reset(to: .failed(String(localized: "“\(host.device.name)” no longer recognizes this iPhone. To connect again, choose it in the list.")))
                return
            }
            // The host did not recognise us (new iPhone, or forgotten there): keys without the old secret.
            if !freshPairing {
                freshPairing = true
                channel.cipher = handshake.cipher(isMac: false, pairingSecret: nil)
            }
            status = .waitingApproval(host.device)
        case .rejected(let reason):
            autoReconnectID = nil
            legacyAutoReconnectName = nil
            self.channel?.cancel()
            self.channel = nil
            reset(to: .failed(reason))
        case .welcome(let welcome):
            // A host found by name only (an older build, or `--sync-host`) gets its id from the sealed welcome.
            let id = host.device.id.hasPrefix("name:") ? welcome.hostID ?? host.device.id : host.device.id
            let device = SyncDevice(id: id, name: welcome.hostName,
                                    kind: welcome.platform.map { SyncPlatform(rawValue: $0) } ?? host.device.kind,
                                    model: welcome.model ?? host.device.model)
            if freshPairing, let handshake {
                KeychainStore.set(handshake.newPairingSecret(), for: Self.secretKey(id))
                freshPairing = false
                offeredSecretKey = Self.secretKey(id)
            } else if let old = offeredSecretKey, old != Self.secretKey(id), let secret = KeychainStore.get(old) {
                // The host accepted a secret kept by its name (before ids): it is this host's, keep it by id.
                KeychainStore.set(secret, for: Self.secretKey(id))
                KeychainStore.set("", for: old)
                offeredSecretKey = Self.secretKey(id)
                print("[sync] pairing with \(device.name) moved to its id")
            }
            remember(device)
            var address = channel.remoteIPv4 ?? welcome.addresses.first ?? "127.0.0.1", port = welcome.go2rtcPort
            if connectingRoute == .direct, let ports = connectingPorts {
                // The direct link forwards this port to the Mac's go2rtc (it reaches it as a LAN client would).
                address = "127.0.0.1"
                port = ports.go2rtc
            }
            let previous = route, wasJoined = isConnected || reconnecting?.id == id
            route = connectingRoute
            if wasJoined, previous != route { onRouteChanged?(route) }
            routeCheck?.cancel()
            if route == .direct {
                routeCheck = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(15))
                        guard let self, !Task.isCancelled, self.route == .direct else { return }
                        self.reconsiderRoute()
                    }
                }
            }
            server = URL(string: "http://\(address):\(port)/").map {
                Go2RTCServer(baseURL: $0, username: welcome.username, password: welcome.password)
            }
            autoReconnectID = id
            legacyAutoReconnectName = nil
            if !isConnected { links += 1 }
            // Back after a drop: the host's next state (right behind the welcome) takes over the training on screen.
            reconnecting = nil
            reconnectTimeout?.cancel()
            status = .connected(device)
            hostFeatures = welcome.features ?? []
            print("[sync] joined \(device.name) (\(device.modelTitle)), go2rtc at \(address):\(port)"
                  + (route == .direct ? ", over the direct link" : ""))
            if hostFeatures.contains(SyncFeature.p2p) { onP2PHost?(id) }
        case .state(let state):
            if let sentAt = state.sentAt { clock.sample(hostTime: sentAt, receivedAt: Date()) }
            self.state = state
            onState?(state)
        case .p2p(let signal):
            guard case .connected(let device) = status else { return }
            onP2PSignal?(signal, device.id)
        case .hello, .proof, .sealed, .command:
            break
        }
    }

    private func lost(_ message: String) {
        channel?.cancel()
        channel = nil
        // The home network failed while the direct link works: that is the way for a while.
        if connectingRoute == .lan, let id = host?.id ?? reconnecting?.id, directRoute(id) != nil {
            lanBackoffUntil = Date().addingTimeInterval(30)
        }
        // Mid-training the training stays on screen while joining again; through the direct link the picture too
        // (a new session of the link, a moment without the home network).
        if case .connected(let device) = status, device.id == autoReconnectID,
           state?.session != nil || directRoute(device.id) != nil {
            startReconnecting(device)
        }
        if reconnecting != nil {
            status = .idle
        } else {
            reset(to: autoReconnectID == nil ? .failed(message) : .idle)
        }
        // The host may come back (app relaunched, Wi-Fi blip): `update` reconnects when it is seen again. The retry
        // asks the same as `update` does: a training or recording started here meanwhile is not taken over.
        if autoReconnectID != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.autoConnectIfPossible()
            }
        }
    }

    /// The link dropped mid-training: the training stays on screen (the app disables its buttons) while this iPhone
    /// joins the host again; after `reconnectGrace` it goes, and the host is still joined whenever it shows up.
    private func startReconnecting(_ device: SyncDevice, log: Bool = true) {
        if log { print("[sync] lost \(device.name), reconnecting") }
        reconnecting = device
        reconnectTimeout?.cancel()
        reconnectTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.reconnectGrace)
            guard !Task.isCancelled, let self, self.reconnecting != nil else { return }
            print("[sync] \(device.name) did not come back, its training goes from the screen")
            // An attempt still going on carries on.
            self.reset(to: self.status)
        }
    }

    #if DEBUG
    /// `--demo-mac-link` / `--demo-mac-recording`: look linked to a Mac without any network (UI checks).
    /// `stopAfter`: the Mac then stops the recording.
    func demoLink(recording: Bool, stopAfter: Double? = nil, pendingPlan: TrainingPlan? = nil) {
        status = .connected(SyncDevice(id: "demo-mac", name: "MacBook Pro", kind: .mac, model: "MacBook Pro"))
        var state = SyncState(session: nil, recordingSince: recording ? Date().addingTimeInterval(-83) : nil,
                              cameraReady: true, cameraTitle: "Xiaomi Smart Camera C200", streamName: "", lastRecord: nil,
                              pendingPlan: pendingPlan)
        self.state = state
        onState?(state)
        guard let stopAfter else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(stopAfter))
            state.recordingSince = nil
            self?.state = state
            self?.onState?(state)
        }
    }

    /// `--demo-mac-session`: linked to a Mac that runs `plan` here in memory, without any network. `lag`: every command
    /// reaches it that much later and its state comes back as late (a weak Wi-Fi).
    /// It has a second camera «Комната»; `showsSecondCamera` is the one on its screen.
    @ObservationIgnored private var demoMac: (session: TrainingSession, lag: Double, recordingSince: Date?, showsSecondCamera: Bool)?

    func demoSession(_ plan: TrainingPlan, lag: Double) {
        demoMac = (TrainingSession(plan: plan), lag, nil, false)
        status = .connected(SyncDevice(id: "demo-mac", name: "MacBook Pro", kind: .mac, model: "MacBook Pro"))
        demoMacPublish()
    }

    /// `--demo-mac-switch-camera`: the switcher on the demo Mac.
    func demoMacSwitchCamera() {
        guard demoMac != nil else { return }
        demoMac?.showsSecondCamera.toggle()
        print("[sync] demo: the Mac shows its \(demoMac?.showsSecondCamera == true ? "second" : "first") camera")
        demoMacPublish()
    }

    private func demoMacReceive(_ command: SyncCommand) {
        print("[sync] demo: sent \(command)")
        Task { [weak self] in
            guard let lag = self?.demoMac?.lag else { return }
            try? await Task.sleep(for: .seconds(lag))
            guard let self, let mac = demoMac else { return }
            print("[sync] demo: the Mac got \(command)")
            switch command {
            case .session(.finish, _):
                mac.session.finish()
                demoMac?.recordingSince = nil
            case .session(let command, let time): command.apply(to: mac.session, at: time)
            case .startRecording: demoMac?.recordingSince = mac.recordingSince ?? Date()
            case .stopRecording: demoMac?.recordingSince = nil
            case .showCamera(let second, let stream):
                demoMac?.showsSecondCamera = SyncCommand.shownSecondCamera(second: second, stream: stream, first: "",
                                                                           secondStream: "room") ?? mac.showsSecondCamera
            default: break
            }
            demoMacPublish()
        }
    }

    private func demoMacPublish() {
        guard let mac = demoMac else { return }
        let finished = mac.session.isFinished
        let state = SyncState(session: finished ? nil : mac.session.snapshot, recordingSince: mac.recordingSince,
                              cameraReady: true, cameraTitle: "Xiaomi Smart Camera C200", streamName: "",
                              lastRecord: finished ? mac.session.makeRecord(recordingFileName: nil) : nil, sentAt: Date(),
                              secondStreamName: "room", secondCameraTitle: "Комната", showsSecondCamera: mac.showsSecondCamera)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(mac.lag))
            guard let self, demoMac != nil else { return }
            print("[sync] demo: state from the Mac, \(state.session.map { "\($0.phase)" } ?? "no session")")
            self.state = state
            onState?(state)
        }
    }

    /// `--demo-hosts`: three computers nearby (two Macs, one of them training, and a PC), the first one joined before.
    /// Nothing listens there: joining fails after a moment.
    /// `--demo-host`: only the first of them, never joined before (the single «рядом» card at first launch).
    func demoHosts(single: Bool = false) {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)
        hosts = [
            DiscoveredHost(endpoint: endpoint, info: SyncHostInfo(name: "MacBook Pro — Марк", cameraTitle: "Прихожая",
                                                                 cameraReady: true, id: "demo-mbp", platform: "mac",
                                                                 model: "MacBook Pro")),
            DiscoveredHost(endpoint: endpoint, info: SyncHostInfo(name: "MacBook Air — Анна", cameraTitle: "Xiaomi C200",
                                                                 cameraReady: true, sessionRunning: true, currentExit: 3,
                                                                 id: "demo-mba", platform: "mac", model: "MacBook Air")),
            DiscoveredHost(endpoint: endpoint, info: SyncHostInfo(name: "DESKTOP-7QK", id: "demo-pc", platform: "windows")),
        ]
        pairedHosts = [PairedHost(id: "demo-mbp", name: "MacBook Pro — Марк", platform: "mac", model: "MacBook Pro",
                                  lastConnected: Date().addingTimeInterval(-86_400)),
                       PairedHost(id: "demo-mini", name: "Mac mini", platform: "mac", model: "Mac mini",
                                  lastConnected: Date().addingTimeInterval(-20 * 86_400))]
        if single {
            hosts = Array(hosts.prefix(1))
            pairedHosts = []
        }
    }
    #endif

    private func reset(to status: Status) {
        self.status = status
        route = .lan
        reconnecting = nil
        reconnectTimeout?.cancel()
        state = nil
        clock = SyncClock()
        server = nil
        onState?(nil)
    }

    // MARK: - Pairings

    /// Secrets are kept by host id; builds before ids kept them by the Mac's name ("sync.token.<name>").
    private static func secretKey(_ hostID: String) -> String {
        hostID.hasPrefix("name:") ? legacySecretKey(String(hostID.dropFirst(5))) : "sync.token.id." + hostID
    }

    private static func legacySecretKey(_ name: String) -> String { "sync.token." + name }

    /// The secret to prove an earlier pairing with: by the host's id, else one kept by its name before ids.
    private func storedSecret(for host: SyncDevice) -> (key: String, secret: String)? {
        for key in [Self.secretKey(host.id), Self.legacySecretKey(host.name)] {
            if let secret = KeychainStore.get(key) { return (key, secret) }
        }
        return nil
    }

    private func secret(for host: SyncDevice) -> String? { storedSecret(for: host)?.secret }

    private func remember(_ host: SyncDevice) {
        let paired = PairedHost(id: host.id, name: host.name, platform: host.kind?.rawValue, model: host.model,
                                lastConnected: Date())
        if let index = pairedHosts.firstIndex(where: { $0.id == host.id }) {
            pairedHosts[index] = paired
        } else {
            pairedHosts.append(paired)
        }
        savePairedHosts()
    }

    private func savePairedHosts() {
        // A sync check or a demo in a preview copy must not change the user's list.
        guard !AppModel.isUIPreview else { return }
        if let data = try? JSONEncoder().encode(pairedHosts) { UserDefaults.standard.set(data, forKey: Self.pairedHostsKey) }
    }
}
#endif
