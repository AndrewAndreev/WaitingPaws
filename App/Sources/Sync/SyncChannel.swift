import Foundation
import Network
import WaitingPawsCore

/// One JSON `SyncMessage` per WebSocket text frame over an `NWConnection` (used on both ends).
/// Everything runs on the main queue: the traffic is a few small messages a second.
@MainActor
final class SyncChannel {
    let connection: NWConnection
    var onMessage: ((SyncMessage) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?

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
        guard let data = try? message.encoded() else { return }
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

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    do {
                        self.onMessage?(try SyncMessage.decode(data))
                    } catch {
                        print("[sync] bad message: \(error)")
                    }
                }
                if error == nil { self.receive() }
            }
        }
    }
}
