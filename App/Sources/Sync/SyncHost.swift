#if os(macOS)
import Foundation
import Network
import Observation
import WaitingPawsCore

/// Mac side of the iPhone link: advertises `_waitingpaws._tcp` over Bonjour, lets an iPhone join after
/// the user allows it once (a pairing secret is remembered per device, see `SyncCrypto`), pushes the session
/// state on every change and applies the iPhone's button presses. The Mac stays the owner of the session
/// and the recording. Everything after the key exchange is encrypted. Devices are told apart by their id
/// (`SyncHello.deviceID`), never by name: iOS calls every iPhone just "iPhone".
@MainActor
@Observable
final class SyncHost {
    struct PairingRequest: Identifiable, Equatable {
        let id: UUID
        let device: SyncDevice
        /// A device paired before that could not prove it: forgotten on the iPhone — or another device using its id,
        /// name and model. The prompt warns and leans to «Отклонить».
        var wasPaired = false
    }

    struct PairedDevice: Codable, Identifiable, Equatable {
        var id: String { deviceID }
        let deviceID: String
        var name: String
        /// The pairing secret (named `token` since protocol v1, whose tokens keep working as secrets).
        var token: String
        /// From the device's last hello (nil for pairings made before these were sent).
        var platform: String?
        var model: String?
        var lastSeen: Date?

        var device: SyncDevice {
            SyncDevice(id: deviceID, name: name, kind: platform.map { SyncPlatform(rawValue: $0) } ?? .iphone,
                       model: model ?? "")
        }
    }

    /// An iPhone waiting for "Разрешить" on this Mac.
    var pairingRequest: PairingRequest?
    /// The iPhones connected right now (one entry per device), sorted by name.
    private(set) var connectedDevices: [SyncDevice] = []
    private(set) var pairedDevices: [PairedDevice] = []
    private(set) var isRunning = false
    private(set) var lastError: String?

    /// What the iPhone shows; called on every broadcast tick.
    @ObservationIgnored var stateProvider: (() -> SyncState)?
    /// Applies an iPhone's command to the app.
    @ObservationIgnored var commandHandler: ((SyncCommand) -> Void)?
    /// Access to this Mac's go2rtc for the iPhone's camera view.
    @ObservationIgnored var accessProvider: (() -> SyncWelcomeAccess)?
    /// An iPhone asks to join (show «Разрешить / Отклонить» wherever the user is — not tied to one window).
    @ObservationIgnored var onPairingRequest: ((PairingRequest) -> Void)?
    /// That iPhone went away before an answer (close the prompt).
    @ObservationIgnored var onPairingCancelled: ((PairingRequest) -> Void)?
    /// An iPhone was forgotten: the go2rtc password it knew must change (then `refreshAccess()`).
    @ObservationIgnored var onDeviceForgotten: (() -> Void)?
    /// This Mac's name for the iPhones (Settings, or the computer name), read on every tick: a new one is advertised
    /// and sent to the connected iPhones once it settles (`hostName`).
    @ObservationIgnored var nameProvider: () -> String = { SyncIdentity.systemName }

    /// The name advertised and sent to the iPhones. A new one from Settings is taken once it stops changing for a
    /// moment: typing it would otherwise re-register the Bonjour service on every key.
    private(set) var hostName: String = SyncIdentity.systemName
    @ObservationIgnored private var nameCandidate: (name: String, since: Date)?

    private func settleName() {
        let name = nameProvider()
        guard name != hostName else { nameCandidate = nil; return }
        if nameCandidate?.name != name { nameCandidate = (name, Date()) }
        if let candidate = nameCandidate, Date().timeIntervalSince(candidate.since) >= 1.5 || lastInfo == nil {
            hostName = name
            nameCandidate = nil
        }
    }

    func isConnected(_ device: PairedDevice) -> Bool {
        connectedDevices.contains { $0.id == device.deviceID }
    }

    struct SyncWelcomeAccess {
        var port: Int
        var username: String
        var password: String
    }

    private struct Client {
        let channel: SyncChannel
        var hello: SyncHello?
        var approved = false
        var handshake: SyncCrypto.Handshake?
        /// Set when the iPhone proved an earlier pairing; nil for a new one (its secret comes on approval).
        var pairingSecret: String?
    }

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var clients: [UUID: Client] = [:]
    @ObservationIgnored private var lastStateData: Data?
    @ObservationIgnored private var lastInfo: SyncHostInfo?
    @ObservationIgnored private var broadcastTask: Task<Void, Never>?

    private static let pairingsKey = "sync.pairedDevices"
    /// Debug: approve every iPhone without asking (`--sync-auto-accept`, for automated checks).
    private let autoAccept: Bool = {
        #if DEBUG
        return CommandLine.arguments.contains("--sync-auto-accept")
        #else
        return false
        #endif
    }()

    init() {
        // App defaults rather than the keychain (no access prompts after rebuilds of the Mac app).
        if let data = UserDefaults.standard.data(forKey: Self.pairingsKey),
           let devices = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            pairedDevices = devices
        }
        #if DEBUG
        // `--demo-iphone`: a connected iPhone in the toolbar and Settings (nothing listens).
        if CommandLine.arguments.contains("--demo-iphone") {
            connectedDevices = [SyncDevice(id: "demo-iphone", name: "iPhone Тани", kind: .iphone, model: "iPhone 16")]
            if !pairedDevices.contains(where: { $0.deviceID == "demo-iphone" }) {
                pairedDevices = [PairedDevice(deviceID: "demo-iphone", name: "iPhone Тани", token: "", platform: "iphone",
                                              model: "iPhone 16", lastSeen: Date()),
                                 PairedDevice(deviceID: "demo-iphone-2", name: "iPhone 15 Pro", token: "", platform: "iphone",
                                              model: "iPhone 15 Pro", lastSeen: Date().addingTimeInterval(-3 * 86_400))]
            }
        }
        #endif
    }

    // MARK: - Lifecycle

    @ObservationIgnored private var bonjourFailures = 0
    @ObservationIgnored private var wanted = false

    func start() {
        wanted = true
        startListener()
        guard broadcastTask == nil else { return }
        broadcastTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                self?.broadcastIfChanged()
            }
        }
    }

    /// Bonjour can fail (local network access not allowed yet, mDNS hiccup): the listener is then
    /// restarted, and after a few failures it keeps accepting direct connections without advertising.
    private func startListener() {
        guard listener == nil, wanted else { return }
        settleName()
        let advertise = bonjourFailures < 3 && !AppModel.isSyncTest
        do {
            // A web page that finds the port is turned away before the key exchange (see `SyncWebSocket`).
            let parameters = SyncWebSocket.listenerParameters { origin in
                print("[sync] refused a connection from a web page (Origin: \(origin))")
            }
            let listener: NWListener
            #if DEBUG
            if let index = CommandLine.arguments.firstIndex(of: "--sync-port"), index + 1 < CommandLine.arguments.count,
               let port = NWEndpoint.Port(CommandLine.arguments[index + 1]) {
                parameters.allowLocalEndpointReuse = true
                listener = try NWListener(using: parameters, on: port)
            } else {
                listener = try NWListener(using: parameters)
            }
            #else
            listener = try NWListener(using: parameters)
            #endif
            let info = currentInfo()
            lastInfo = info
            if advertise {
                listener.service = NWListener.Service(name: hostName, type: SyncProtocol.serviceType, txtRecord: Self.txtRecord(info))
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        print("[sync] advertising \(SyncProtocol.serviceType) on port \(listener.port?.rawValue ?? 0)")
                    case .failed(let error):
                        guard let self else { return }
                        self.isRunning = false
                        self.lastError = error.localizedDescription
                        print("[sync] listener failed: \(error)")
                        self.listener?.cancel()
                        self.listener = nil
                        if advertise { self.bonjourFailures += 1 }
                        Task { [weak self] in
                            try? await Task.sleep(for: .seconds(3))
                            self?.startListener()
                        }
                    case .cancelled:
                        self?.isRunning = false
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
            print("[sync] cannot listen: \(error)")
        }
    }

    func stop() {
        wanted = false
        broadcastTask?.cancel()
        broadcastTask = nil
        clients.values.forEach { $0.channel.cancel() }
        clients.removeAll()
        listener?.cancel()
        listener = nil
        pairingRequest = nil
        updateConnected()
    }

    // MARK: - Pairing

    func answerPairing(allow: Bool) {
        guard let request = pairingRequest else { return }
        pairingRequest = nil
        if request.wasPaired { print("[sync] \(request.device.name), unconfirmed, \(allow ? "allowed" : "declined")") }
        if allow {
            approve(request.id)
        } else if let client = clients[request.id] {
            client.channel.send(.rejected(String(localized: "На Mac подключение отклонили")))
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.drop(request.id)
            }
        }
    }

    func forget(_ device: PairedDevice) {
        pairedDevices.removeAll { $0.deviceID == device.deviceID }
        savePairings()
        for (id, client) in clients where client.hello?.deviceID == device.deviceID { drop(id) }
        onDeviceForgotten?()
    }

    /// Sends the current go2rtc access again to every connected iPhone (after the password changed).
    func refreshAccess() {
        for client in clients.values where client.approved { client.channel.send(.welcome(welcome())) }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let channel = SyncChannel(connection: connection)
        clients[id] = Client(channel: channel)
        channel.onMessage = { [weak self] message in self?.handle(message, from: id) }
        channel.onStateChange = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(id)
            default: break
            }
        }
        channel.start()
        // A connection that never finishes the key exchange (or a port scan) does not hang around.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, let client = self.clients[id], !client.approved, self.pairingRequest?.id != id else { return }
            self.drop(id)
        }
    }

    private func handle(_ message: SyncMessage, from id: UUID) {
        guard var client = clients[id] else { return }
        switch message {
        case .hello(let hello):
            guard client.hello == nil else { return }
            guard hello.protocolVersion == SyncProtocol.version else {
                client.channel.send(.rejected(String(localized: "Обновите Waiting Paws на iPhone и на Mac")))
                return
            }
            let key = SyncCrypto.newKey()
            let macPublic = key.publicKey.rawRepresentation
            guard let handshake = try? SyncCrypto.Handshake(privateKey: key, peerKey: hello.publicKey,
                                                            phoneKey: hello.publicKey, macKey: macPublic,
                                                            deviceID: hello.deviceID) else {
                drop(id)
                return
            }
            client.hello = hello
            client.handshake = handshake
            clients[id] = client
            print("[sync] hello from \(hello.deviceName) (\(hello.device.modelTitle), \(hello.deviceID.prefix(8)))")
            client.channel.send(.challenge(macPublic))
        case .proof(let proof):
            guard let hello = client.hello, let handshake = client.handshake, !client.approved,
                  client.channel.cipher == nil else { return }
            let known = pairedDevices.first { $0.deviceID == hello.deviceID }
            if let proof, let known, handshake.verify(proof: proof, pairingSecret: known.token) {
                client.pairingSecret = known.token
                client.channel.cipher = handshake.cipher(isMac: true, pairingSecret: known.token)
                clients[id] = client
                approve(id)
            } else {
                // One request on screen at a time: another device's waits for no answer and must not replace the one
                // the user may be about to allow. The same device asking again (it reconnected) replaces its own.
                if let current = pairingRequest, current.id != id {
                    guard current.device.id == hello.deviceID else {
                        print("[sync] \(hello.deviceName) turned away: another request is waiting for an answer")
                        client.channel.send(.rejected(String(localized: "Сначала ответьте на другой запрос на Mac")))
                        Task { [weak self] in
                            try? await Task.sleep(for: .milliseconds(300))
                            self?.drop(id)
                        }
                        return
                    }
                    drop(current.id)
                }
                client.channel.cipher = handshake.cipher(isMac: true, pairingSecret: nil)
                clients[id] = client
                // Tells the iPhone to switch to the keys without its old secret (a new pairing follows).
                client.channel.send(.pending)
                if autoAccept {
                    approve(id)
                } else {
                    if known != nil {
                        print("[sync] \(hello.deviceName) was paired before but did not prove it (\(proof == nil ? "no" : "wrong") proof)")
                    }
                    let request = PairingRequest(id: id, device: hello.device, wasPaired: known != nil)
                    pairingRequest = request
                    onPairingRequest?(request)
                }
            }
        case .command(let command):
            guard client.approved else { return }
            print("[sync] command \(command)")
            commandHandler?(command)
            broadcastIfChanged()
        case .challenge, .pending, .rejected, .sealed, .welcome, .state:
            break
        }
    }

    private func approve(_ id: UUID) {
        guard var client = clients[id], let hello = client.hello, let handshake = client.handshake else { return }
        client.approved = true
        clients[id] = client

        // A new iPhone: both sides derive the same secret from this handshake; it never crosses the network.
        let secret = client.pairingSecret ?? handshake.newPairingSecret()
        let device = PairedDevice(deviceID: hello.deviceID, name: hello.deviceName, token: secret,
                                  platform: hello.device.kind?.rawValue ?? hello.platform, model: hello.model, lastSeen: Date())
        if let index = pairedDevices.firstIndex(where: { $0.deviceID == hello.deviceID }) {
            pairedDevices[index] = device
        } else {
            pairedDevices.append(device)
        }
        savePairings()
        // The same iPhone came back before its old connection timed out (Wi-Fi drop): that one is gone.
        for (other, old) in clients where other != id && old.hello?.deviceID == hello.deviceID { drop(other) }

        client.channel.send(.welcome(welcome()))
        if var state = stateProvider?() {
            state.sentAt = Date()
            client.channel.send(.state(state))
        }
        updateConnected()
        print("[sync] \(hello.deviceName) (\(hello.device.modelTitle)) joined")
    }

    private func drop(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.channel.cancel()
        if let request = pairingRequest, request.id == id {
            pairingRequest = nil
            onPairingCancelled?(request)
        }
        updateConnected()
    }

    private func updateConnected() {
        var seen = Set<String>()
        connectedDevices = clients.values.filter(\.approved).compactMap { $0.hello?.device }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Broadcast

    /// Sends the state to every approved iPhone when it changed, and refreshes the Bonjour TXT record.
    func broadcastIfChanged() {
        guard let state = stateProvider?() else { return }
        settleName()
        let info = currentInfo(state)
        if info != lastInfo {
            let renamed = lastInfo.map { $0.name != info.name } ?? false
            lastInfo = info
            if let listener, listener.service != nil {
                listener.service = NWListener.Service(name: info.name, type: SyncProtocol.serviceType, txtRecord: Self.txtRecord(info))
            }
            // The welcome carries the name the iPhones show.
            if renamed { refreshAccess() }
        }
        guard clients.values.contains(where: \.approved) else { return }
        let data = try? SyncProtocol.encoder().encode(state)
        guard data != lastStateData else { return }
        lastStateData = data
        var stamped = state
        stamped.sentAt = Date()
        for client in clients.values where client.approved {
            client.channel.send(.state(stamped))
        }
    }

    private func currentInfo(_ state: SyncState? = nil) -> SyncHostInfo {
        let state = state ?? stateProvider?()
        var exit: Int?
        if let snapshot = state?.session {
            switch snapshot.phase {
            case .ready(let i), .leaving(let i, _), .away(let i, _, _): exit = snapshot.plan.exits[i].number
            case .breakTime(_, _, _, let next): exit = next.map { snapshot.plan.exits[$0].number }
            case .finished: exit = nil
            }
        }
        return SyncHostInfo(name: hostName, cameraTitle: state?.cameraTitle ?? "", cameraReady: state?.cameraReady ?? false,
                            sessionRunning: state?.session != nil, currentExit: exit, id: SyncIdentity.deviceID,
                            platform: SyncIdentity.platform.rawValue, model: SyncIdentity.model)
    }

    private static func txtRecord(_ info: SyncHostInfo) -> NWTXTRecord {
        NWTXTRecord(info.txt)
    }

    private func savePairings() {
        if let data = try? JSONEncoder().encode(pairedDevices) {
            // A sync check or a demo in a preview copy must not change the user's iPhones.
            if !AppModel.isUIPreview { UserDefaults.standard.set(data, forKey: Self.pairingsKey) }
        }
    }

    private func welcome() -> SyncWelcome {
        let access = accessProvider?() ?? SyncWelcomeAccess(port: EmbeddedGo2RTC.apiPort, username: "", password: "")
        return SyncWelcome(hostName: hostName, go2rtcPort: access.port, username: access.username,
                           password: access.password, addresses: Self.ipv4Addresses(), hostID: SyncIdentity.deviceID,
                           platform: SyncIdentity.platform.rawValue, model: SyncIdentity.model)
    }

    /// LAN IPv4 addresses of this Mac (Wi-Fi / Ethernet), for the iPhone's go2rtc URL.
    static func ipv4Addresses() -> [String] {
        var result: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}
#endif
