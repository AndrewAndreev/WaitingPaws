#if os(iOS)
import Foundation
import Network
import Observation
import UIKit
import WaitingPawsCore

/// iPhone side of the link: finds Macs running Waiting Paws on the local network, joins one (the Mac
/// user allows it once), then exposes the Mac's go2rtc for the camera view and mirrors its session.
@MainActor
@Observable
final class SyncClient {
    struct DiscoveredMac: Identifiable, Equatable {
        var id: String { info.name }
        let endpoint: NWEndpoint
        let info: SyncHostInfo
    }

    enum Status: Equatable {
        case idle
        case connecting(String)
        /// The Mac shows "Разрешить / Отклонить".
        case waitingApproval(String)
        case connected(String)
        case failed(String)
    }

    private(set) var macs: [DiscoveredMac] = []
    private(set) var status: Status = .idle
    private(set) var state: SyncState?
    /// The Mac's go2rtc (LAN address + Basic auth) once connected.
    private(set) var server: Go2RTCServer?
    private(set) var hostName: String?

    /// Called with every state from the Mac, and with nil when the link goes away.
    @ObservationIgnored var onState: ((SyncState?) -> Void)?

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var channel: SyncChannel?
    /// This connection's key exchange (see `SyncCrypto`).
    @ObservationIgnored private var privateKey = SyncCrypto.newKey()
    @ObservationIgnored private var handshake: SyncCrypto.Handshake?
    /// No valid pairing secret on this connection: the Mac asked for «Разрешить», a new secret comes with welcome.
    @ObservationIgnored private var freshPairing = false
    /// Reconnect to this Mac whenever it shows up, also after a relaunch of either app (set after a successful
    /// connection, cleared by «Отключить синхронизацию» and by a rejection).
    @ObservationIgnored private var autoReconnectName: String? = UserDefaults.standard.string(forKey: SyncClient.autoConnectKey) {
        didSet { UserDefaults.standard.set(autoReconnectName, forKey: Self.autoConnectKey) }
    }
    private static let autoConnectKey = "sync.autoConnectMac"
    /// Whether joining a Mac on our own is fine right now: not while this iPhone runs its own training or recording.
    @ObservationIgnored var canAutoConnect: () -> Bool = { true }
    @ObservationIgnored private var loggedMacs: [String] = []

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

    /// Macs with a camera ready, the one with a running training first.
    var bestMac: DiscoveredMac? {
        macs.filter { $0.info.version == SyncProtocol.version }
            .sorted { ($0.info.sessionRunning ? 0 : 1, $0.info.cameraReady ? 0 : 1) < ($1.info.sessionRunning ? 0 : 1, $1.info.cameraReady ? 0 : 1) }
            .first
    }

    /// A Mac this iPhone has joined before (a pairing secret is stored for it).
    func isPaired(_ mac: DiscoveredMac) -> Bool {
        KeychainStore.get(Self.tokenKey(mac.info.name)) != nil
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
                connect(to: DiscoveredMac(endpoint: endpoint, info: SyncHostInfo(name: "Mac (debug)")))
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

    /// Joins the Mac this iPhone was linked to, if it is around and nothing here is in the way.
    func autoConnectIfPossible() {
        guard channel == nil, let name = autoReconnectName, canAutoConnect(),
              let mac = macs.first(where: { $0.info.name == name }) else { return }
        print("[sync] reconnecting to \(name)")
        connect(to: mac)
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        macs = results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata { txt = record.dictionary }
            return DiscoveredMac(endpoint: result.endpoint, info: SyncHostInfo(name: name, txt: txt))
        }
        .sorted { $0.info.name < $1.info.name }
        let names = macs.map { mac in
            mac.info.name + (isPaired(mac) ? " (paired)" : "") + (mac.info.version == SyncProtocol.version ? "" : " (v\(mac.info.version))")
        }
        if names != loggedMacs {
            loggedMacs = names
            print("[sync] Macs nearby: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        }
        autoConnectIfPossible()
        #if DEBUG
        // `--sync-auto-connect`: join the first Mac found (UI checks in the simulator without taps).
        if channel == nil, status == .idle, CommandLine.arguments.contains("--sync-auto-connect"), let mac = bestMac {
            connect(to: mac)
        }
        #endif
    }

    // MARK: - Connection

    func connect(to mac: DiscoveredMac) {
        channel?.cancel()
        let channel = SyncChannel(connection: NWConnection(to: mac.endpoint, using: SyncChannel.parameters()))
        self.channel = channel
        privateKey = SyncCrypto.newKey()
        handshake = nil
        freshPairing = false
        status = .connecting(mac.info.name)
        channel.onStateChange = { [weak self, weak channel] state in
            guard let self, let channel, channel === self.channel else { return }
            switch state {
            case .ready:
                channel.send(.hello(SyncHello(deviceID: Self.deviceID, deviceName: UIDevice.current.name,
                                              publicKey: self.privateKey.publicKey.rawRepresentation)))
            case .failed(let error):
                self.lost(String(localized: "Нет связи с Mac: \(error.localizedDescription)"))
            case .cancelled:
                if self.isConnected || self.isBusy { self.lost(String(localized: "Mac отключился")) }
            default:
                break
            }
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel, channel === self.channel else { return }
            self.handle(message, macName: mac.info.name, channel: channel)
        }
        channel.start()
    }

    /// "Отключиться": stop mirroring and don't reconnect on our own.
    func disconnect() {
        autoReconnectName = nil
        channel?.cancel()
        channel = nil
        reset(to: .idle)
    }

    func send(_ command: SyncCommand) {
        channel?.send(.command(command))
    }

    private func handle(_ message: SyncMessage, macName: String, channel: SyncChannel) {
        switch message {
        case .challenge(let macKey):
            guard handshake == nil else { return }
            let phoneKey = privateKey.publicKey.rawRepresentation
            guard let handshake = try? SyncCrypto.Handshake(privateKey: privateKey, peerKey: macKey, phoneKey: phoneKey,
                                                            macKey: macKey, deviceID: Self.deviceID) else {
                lost(String(localized: "Нет связи с Mac"))
                return
            }
            self.handshake = handshake
            let secret = KeychainStore.get(Self.tokenKey(macName))
            freshPairing = secret == nil
            channel.cipher = handshake.cipher(isMac: false, pairingSecret: secret)
            channel.send(.proof(secret.map { handshake.proof(pairingSecret: $0) }))
        case .pending:
            // The Mac did not recognise us (new iPhone, or forgotten there): keys without the old secret.
            if let handshake, !freshPairing {
                freshPairing = true
                channel.cipher = handshake.cipher(isMac: false, pairingSecret: nil)
            }
            status = .waitingApproval(macName)
        case .rejected(let reason):
            autoReconnectName = nil
            self.channel?.cancel()
            self.channel = nil
            reset(to: .failed(reason))
        case .welcome(let welcome):
            if freshPairing, let handshake {
                KeychainStore.set(handshake.newPairingSecret(), for: Self.tokenKey(macName))
                freshPairing = false
            }
            let address = channel.remoteIPv4 ?? welcome.addresses.first ?? "127.0.0.1"
            server = URL(string: "http://\(address):\(welcome.go2rtcPort)/").map {
                Go2RTCServer(baseURL: $0, username: welcome.username, password: welcome.password)
            }
            hostName = welcome.hostName
            autoReconnectName = macName
            status = .connected(welcome.hostName)
            print("[sync] joined \(welcome.hostName), go2rtc at \(address):\(welcome.go2rtcPort)")
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
        reset(to: autoReconnectName == nil ? .failed(message) : .idle)
        // The Mac may come back (app relaunched, Wi-Fi blip): `update` reconnects when it is seen again.
        if let name = autoReconnectName, let mac = macs.first(where: { $0.info.name == name }) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.channel == nil, self.autoReconnectName == name else { return }
                self.connect(to: mac)
            }
        }
    }

    #if DEBUG
    /// `--demo-mac-link` / `--demo-mac-recording`: look linked to a Mac without any network (UI checks).
    /// `stopAfter`: the Mac then stops the recording.
    func demoLink(recording: Bool, stopAfter: Double? = nil, pendingPlan: TrainingPlan? = nil) {
        hostName = "MacBook Pro"
        status = .connected("MacBook Pro")
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
    #endif

    private func reset(to status: Status) {
        self.status = status
        state = nil
        server = nil
        hostName = nil
        onState?(nil)
    }

    // MARK: - Identity

    private static func tokenKey(_ macName: String) -> String { "sync.token." + macName }

    private static var deviceID: String {
        let key = "sync.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}
#endif
