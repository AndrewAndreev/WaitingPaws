import Foundation
import Network

/// The link's transport (see `SyncProtocol`): TCP + WebSocket framing, for the iPhone's outgoing connections and for
/// the host's listener (Mac).
public enum SyncWebSocket {
    /// For connecting to a host. `NWProtocolWebSocket` sends no `Origin` header.
    public static func parameters() -> NWParameters {
        make(webSocket())
    }

    /// For the host's listener: a handshake carrying `Origin` is turned away (HTTP 400) and reported to `onRefused`
    /// with that origin. Browsers always send the page's origin, the iPhone never does: a web page, on this computer
    /// or elsewhere on the network, must not reach the pairing prompt (Windows does the same).
    public static func listenerParameters(onRefused: @escaping @Sendable (_ origin: String) -> Void) -> NWParameters {
        let options = webSocket()
        options.setClientRequestHandler(.global(qos: .userInitiated)) { _, headers in
            if let origin = headers.first(where: { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }) {
                onRefused(origin.value)
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        return make(options)
    }

    private static func webSocket() -> NWProtocolWebSocket.Options {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        return options
    }

    private static func make(_ webSocket: NWProtocolWebSocket.Options) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }
}
