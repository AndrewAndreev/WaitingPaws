#if os(macOS)
import Foundation
import Network
import Observation
import WaitingPawsCore

/// Mac side of the iPhone link: advertises `_waitingpaws._tcp` over Bonjour, lets an iPhone join after
/// the user allows it once (a token is remembered per device), pushes the session state on every change
/// and applies the iPhone's button presses. The Mac stays the owner of the session and the recording.
@MainActor
@Observable
final class SyncHost {
    struct PairingRequest: Identifiable, Equatable {
        let id: UUID
        let deviceName: String
    }

    struct PairedDevice: Codable, Identifiable, Equatable {
        var id: String { deviceID }
        let deviceID: String
        var name: String
        var token: String
    }

    /// An iPhone waiting for "Разрешить" on this Mac.
    var pairingRequest: PairingRequest?
    /// Names of the iPhones connected right now.
    private(set) var connectedDevices: [String] = []
    private(set) var pairedDevices: [PairedDevice] = []
    private(set) var isRunning = false
    private(set) var lastError: String?

    /// What the iPhone shows; called on every broadcast tick.
    @ObservationIgnored var stateProvider: (() -> SyncState)?
    /// Applies an iPhone's command to the app.
    @ObservationIgnored var commandHandler: ((SyncCommand) -> Void)?
    /// Access to this Mac's go2rtc for the iPhone's camera view.
    @ObservationIgnored var accessProvider: (() -> SyncWelcomeAccess)?

    let hostName = Host.current().localizedName ?? "Mac"

    struct SyncWelcomeAccess {
        var port: Int
        var username: String
        var password: String
    }

    private struct Client {
        let channel: SyncChannel
        var hello: SyncHello?
        var approved = false
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
        let advertise = bonjourFailures < 3
        do {
            let parameters = SyncChannel.parameters()
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
        if allow {
            approve(request.id)
        } else if let client = clients[request.id] {
            client.channel.send(.rejected("На Mac подключение отклонили"))
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
    }

    private func handle(_ message: SyncMessage, from id: UUID) {
        guard var client = clients[id] else { return }
        switch message {
        case .hello(let hello):
            client.hello = hello
            clients[id] = client
            print("[sync] hello from \(hello.deviceName)")
            let known = pairedDevices.first { $0.deviceID == hello.deviceID }
            if let known, known.token == hello.token {
                approve(id)
            } else if autoAccept {
                approve(id)
            } else {
                client.channel.send(.pending)
                pairingRequest = PairingRequest(id: id, deviceName: hello.deviceName)
            }
        case .command(let command):
            guard client.approved else { return }
            print("[sync] command \(command)")
            commandHandler?(command)
            broadcastIfChanged()
        case .pending, .rejected, .welcome, .state:
            break
        }
    }

    private func approve(_ id: UUID) {
        guard var client = clients[id], let hello = client.hello else { return }
        client.approved = true
        clients[id] = client

        var device = pairedDevices.first { $0.deviceID == hello.deviceID }
            ?? PairedDevice(deviceID: hello.deviceID, name: hello.deviceName, token: Self.newToken())
        device.name = hello.deviceName
        pairedDevices.removeAll { $0.deviceID == hello.deviceID }
        pairedDevices.append(device)
        savePairings()

        let access = accessProvider?() ?? SyncWelcomeAccess(port: EmbeddedGo2RTC.apiPort, username: "", password: "")
        client.channel.send(.welcome(SyncWelcome(hostName: hostName, token: device.token, go2rtcPort: access.port,
                                                 username: access.username, password: access.password,
                                                 addresses: Self.ipv4Addresses())))
        if let state = stateProvider?() { client.channel.send(.state(state)) }
        updateConnected()
        print("[sync] \(hello.deviceName) joined")
    }

    private func drop(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.channel.cancel()
        if pairingRequest?.id == id { pairingRequest = nil }
        updateConnected()
    }

    private func updateConnected() {
        connectedDevices = clients.values.filter(\.approved).compactMap { $0.hello?.deviceName }.sorted()
    }

    // MARK: - Broadcast

    /// Sends the state to every approved iPhone when it changed, and refreshes the Bonjour TXT record.
    func broadcastIfChanged() {
        guard let state = stateProvider?() else { return }
        let info = currentInfo(state)
        if info != lastInfo, let listener, listener.service != nil {
            lastInfo = info
            listener.service = NWListener.Service(name: hostName, type: SyncProtocol.serviceType, txtRecord: Self.txtRecord(info))
        }
        guard clients.values.contains(where: \.approved) else { return }
        let data = try? SyncProtocol.encoder().encode(state)
        guard data != lastStateData else { return }
        lastStateData = data
        for client in clients.values where client.approved {
            client.channel.send(.state(state))
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
                            sessionRunning: state?.session != nil, currentExit: exit)
    }

    private static func txtRecord(_ info: SyncHostInfo) -> NWTXTRecord {
        NWTXTRecord(info.txt)
    }

    private func savePairings() {
        if let data = try? JSONEncoder().encode(pairedDevices) {
            UserDefaults.standard.set(data, forKey: Self.pairingsKey)
        }
    }

    private static func newToken() -> String {
        (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined().lowercased()
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
