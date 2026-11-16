import Foundation
import Network
import WaitingPawsCore

/// One JSON `SyncMessage` per WebSocket text frame over an `NWConnection` (used on both ends; `SyncWebSocket` makes
/// the parameters).
/// Everything runs on the main queue: the traffic is a few small messages a second.
/// Once the key exchange set `cipher`, welcome / state / command messages go sealed; they are never sent or
/// accepted in the clear, and a frame that does not open closes the connection.
@MainActor
final class SyncChannel {
    let connection: NWConnection
    var onMessage: ((SyncMessage) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?
    var cipher: SyncCipher?

    /// A WebSocket ping every `pingEvery`; with no pong (or message) for `deadAfter` the connection is closed, so a link
    /// that died without a word (Wi‑Fi off, the Mac quit, the direct link gone) is noticed in seconds — TCP itself took
    /// 30–45 s (2026-11-16). Both ends answer pings by themselves (`SyncWebSocket`: autoReplyPing), older builds too.
    static let pingEvery: Duration = .seconds(3)
    static let deadAfter: TimeInterval = 9
    private var heardAt = Date()
    private var pingedAt: Date?
    private var pingTask: Task<Void, Never>?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .ready = state { self?.heardAt = Date() }
                self?.onStateChange?(state)
            }
        }
        connection.start(queue: .main)
        receive()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingEvery)
                guard let self, !Task.isCancelled else { return }
                self.keepAlive()
            }
        }
    }

    private func keepAlive() {
        guard case .ready = connection.state else { return }
        let now = Date()
        // Back from being suspended (an iPhone in the background): no ping went out meanwhile, so silence says nothing
        // yet; the next round decides.
        if let pingedAt, now.timeIntervalSince(pingedAt) > Self.deadAfter { heardAt = now }
        if now.timeIntervalSince(heardAt) > Self.deadAfter {
            print("[sync] no answer for \(Int(Self.deadAfter)) s, closing the connection")
            pingTask?.cancel()
            connection.cancel()
            return
        }
        pingedAt = now
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(.main) { [weak self] error in
            guard error == nil else { return }
            MainActor.assumeIsolated { self?.heardAt = Date() }
        }
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection.send(content: Data(), contentContext: context, isComplete: true, completion: .idempotent)
    }

    func send(_ message: SyncMessage) {
        var wire = message
        if message.needsSealing {
            guard var cipher, let sealed = try? cipher.seal(message) else {
                print("[sync] not sent: no key yet")
                return
            }
            self.cipher = cipher
            wire = .sealed(sealed)
        }
        guard let data = try? wire.encoded() else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error { print("[sync] send failed: \(error)") }
        })
    }

    func cancel() {
        pingTask?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    /// The other side's address, e.g. "192.168.1.20" (IPv4 only; nil for IPv6 or unknown).
    var remoteIPv4: String? {
        guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint,
              case .ipv4(let address) = host else { return nil }
        let text = "\(address)"
        return text.split(separator: "%").first.map(String.init)
    }

    private func deliver(_ message: SyncMessage) throws {
        switch message {
        case .sealed(let data):
            guard var cipher else { throw CocoaError(.coderReadCorrupt) }
            let inner = try cipher.open(data)
            self.cipher = cipher
            guard inner.needsSealing else { return }
            onMessage?(inner)
        case let message where message.needsSealing:
            // Never in the clear: someone on the network is trying to skip the key exchange.
            throw CocoaError(.coderReadCorrupt)
        default:
            onMessage?(message)
        }
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.heardAt = Date()
                    do {
                        try self.deliver(SyncMessage.decode(data))
                    } catch {
                        print("[sync] bad message, closing: \(error)")
                        self.connection.cancel()
                        return
                    }
                }
                // The other end closed (or the read failed): the connection stays «ready» by itself, with nothing more
                // ever coming — over the direct link that kept the iPhone «linked» to a Mac that had quit for a minute
                // and more (2026-11-16). Cancelled, so its owner hears `.cancelled` and reconnects.
                if let error {
                    print("[sync] connection ended: \(error.localizedDescription)")
                    self.connection.cancel()
                } else if (data?.isEmpty ?? true), context?.isFinal == true {
                    print("[sync] the other side closed the connection")
                    self.connection.cancel()
                } else {
                    self.receive()
                }
            }
        }
    }
}
