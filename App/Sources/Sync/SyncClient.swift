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
    /// The host's go2rtc (LAN address + Basic auth) once connected.
    private(set) var server: Go2RTCServer?

    /// Called with every state from the host, and with nil when the link goes away.
    @ObservationIgnored var onState: ((SyncState?) -> Void)?
    /// This iPhone's name for the hosts (Settings, or the model).
    @ObservationIgnored var nameProvider: () -> String = { SyncIdentity.systemName }

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var channel: SyncChannel?
    /// This connection's key exchange (see `SyncCrypto`).
    @ObservationIgnored private var privateKey = SyncCrypto.newKey()
    @ObservationIgnored private var handshake: SyncCrypto.Handshake?
    /// No valid pairing secret on this connection: the host asked for «Разрешить», a new secret comes with welcome.
    @ObservationIgnored private var freshPairing = false
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

    /// Joins the host this iPhone was linked to, if it is around and nothing here is in the way.
    func autoConnectIfPossible() {
        guard channel == nil, autoReconnectID != nil || legacyAutoReconnectName != nil, canAutoConnect(),
              let host = hosts.first(where: isAutoReconnectTarget) else { return }
        print("[sync] reconnecting to \(host.device.name)")
        connect(to: host)
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
        #if DEBUG
        // `--sync-auto-connect`: join the first host found (UI checks in the simulator without taps).
        if channel == nil, status == .idle, CommandLine.arguments.contains("--sync-auto-connect"), let host = preferredHost {
            connect(to: host)
        }
        #endif
    }

    // MARK: - Connection

    func connect(to host: DiscoveredHost) {
        channel?.cancel()
        // Switching from another host: its state and camera go away first (the new one greets like a fresh link).
        if isConnected { reset(to: .idle) }
        let channel = SyncChannel(connection: NWConnection(to: host.endpoint, using: SyncChannel.parameters()))
        self.channel = channel
        privateKey = SyncCrypto.newKey()
        handshake = nil
        freshPairing = false
        offeredSecretKey = nil
        status = .connecting(host.device)
        let kind = host.device.kindTitle
        channel.onStateChange = { [weak self, weak channel] state in
            guard let self, let channel, channel === self.channel else { return }
            switch state {
            case .ready:
                channel.send(.hello(SyncHello(deviceID: SyncIdentity.deviceID, deviceName: self.nameProvider(),
                                              publicKey: self.privateKey.publicKey.rawRepresentation,
                                              platform: SyncIdentity.platform.rawValue, model: SyncIdentity.model)))
            case .failed(let error):
                self.lost(String(localized: "Нет связи с \(kind): \(error.localizedDescription)"))
            case .cancelled:
                if self.isConnected || self.isBusy { self.lost(String(localized: "\(kind) отключился")) }
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
        autoReconnectID = nil
        legacyAutoReconnectName = nil
        channel?.cancel()
        channel = nil
        reset(to: .idle)
    }

    /// «Забыть»: drop the pairing secret, so joining this host again needs «Разрешить» there.
    func forget(_ hostID: String) {
        if host?.id == hostID { disconnect() }
        KeychainStore.set("", for: Self.secretKey(hostID))
        if let name = pairedHosts.first(where: { $0.id == hostID })?.name { KeychainStore.set("", for: Self.legacySecretKey(name)) }
        pairedHosts.removeAll { $0.id == hostID }
        savePairedHosts()
        if autoReconnectID == hostID { autoReconnectID = nil }
        print("[sync] forgot host \(hostID.prefix(13))")
    }

    func send(_ command: SyncCommand) {
        channel?.send(.command(command))
    }

    private func handle(_ message: SyncMessage, from host: DiscoveredHost, channel: SyncChannel) {
        switch message {
        case .challenge(let hostKey):
            guard handshake == nil else { return }
            let phoneKey = privateKey.publicKey.rawRepresentation
            guard let handshake = try? SyncCrypto.Handshake(privateKey: privateKey, peerKey: hostKey, phoneKey: phoneKey,
                                                            macKey: hostKey, deviceID: SyncIdentity.deviceID) else {
                lost(String(localized: "Нет связи с \(host.device.kindTitle)"))
                return
            }
            self.handshake = handshake
            let stored = storedSecret(for: host.device)
            offeredSecretKey = stored?.key
            freshPairing = stored == nil
            channel.cipher = handshake.cipher(isMac: false, pairingSecret: stored?.secret)
            channel.send(.proof(stored.map { handshake.proof(pairingSecret: $0.secret) }))
        case .pending:
            // The host did not recognise us (new iPhone, or forgotten there): keys without the old secret.
            if let handshake, !freshPairing {
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
            let address = channel.remoteIPv4 ?? welcome.addresses.first ?? "127.0.0.1"
            server = URL(string: "http://\(address):\(welcome.go2rtcPort)/").map {
                Go2RTCServer(baseURL: $0, username: welcome.username, password: welcome.password)
            }
            autoReconnectID = id
            legacyAutoReconnectName = nil
            status = .connected(device)
            print("[sync] joined \(device.name) (\(device.modelTitle)), go2rtc at \(address):\(welcome.go2rtcPort)")
        case .state(let state):
            self.state = state
            onState?(state)
        case .hello, .proof, .sealed, .command:
            break
        }
    }

    private func lost(_ message: String) {
        channel?.cancel()
        channel = nil
        reset(to: autoReconnectID == nil ? .failed(message) : .idle)
        // The host may come back (app relaunched, Wi-Fi blip): `update` reconnects when it is seen again.
        if let id = autoReconnectID, let host = hosts.first(where: { $0.id == id }) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.channel == nil, self.autoReconnectID == id else { return }
                self.connect(to: host)
            }
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

    /// `--demo-hosts`: three computers nearby (two Macs, one of them training, and a PC), the first one joined before.
    /// Nothing listens there: joining fails after a moment.
    /// `--demo-host`: only the first of them, never joined before (the single «рядом» card at first launch).
    func demoHosts(single: Bool = false) {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)
        hosts = [
            DiscoveredHost(endpoint: endpoint, info: SyncHostInfo(name: "MacBook Pro — Андрей", cameraTitle: "Прихожая",
                                                                 cameraReady: true, id: "demo-mbp", platform: "mac",
                                                                 model: "MacBook Pro")),
            DiscoveredHost(endpoint: endpoint, info: SyncHostInfo(name: "MacBook Air — Татьяна", cameraTitle: "Xiaomi C200",
                                                                 cameraReady: true, sessionRunning: true, currentExit: 3,
                                                                 id: "demo-mba", platform: "mac", model: "MacBook Air")),
            DiscoveredHost(endpoint: endpoint, info: SyncHostInfo(name: "DESKTOP-7QK", id: "demo-pc", platform: "windows")),
        ]
        pairedHosts = [PairedHost(id: "demo-mbp", name: "MacBook Pro — Андрей", platform: "mac", model: "MacBook Pro",
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
        state = nil
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
