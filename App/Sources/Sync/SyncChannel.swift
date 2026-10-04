import Foundation
import Network
import WaitingPawsCore

/// One JSON `SyncMessage` per WebSocket text frame over an `NWConnection` (used on both ends).
/// Everything runs on the main queue: the traffic is a few small messages a second.
/// Once the key exchange set `cipher`, welcome / state / command messages go sealed; they are never sent or
/// accepted in the clear, and a frame that does not open closes the connection.
@MainActor
final class SyncChannel {
    let connection: NWConnection
    var onMessage: ((SyncMessage) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?
    var cipher: SyncCipher?

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// TCP + WebSocket framing, for the listener (Mac) and for outgoing connections (iPhone).
    nonisolated static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.onStateChange?(state) }
        }
        connection.start(queue: .main)
        receive()
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
        connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    do {
                        try self.deliver(SyncMessage.decode(data))
                    } catch {
                        print("[sync] bad message, closing: \(error)")
                        self.connection.cancel()
                        return
                    }
                }
                if error == nil { self.receive() }
            }
        }
    }
}
