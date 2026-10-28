import XCTest
import Network
@testable import WaitingPawsCore

/// The host's listener on loopback: a browser's handshake is turned away, the iPhone's goes through.
final class SyncWebSocketTests: XCTestCase {
    /// What the listener saw (filled on Network's queues).
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _refused: [String] = []
        private var _received: [String] = []
        private var _accepted: [NWConnection] = []
        var refused: [String] { lock.withLock { _refused } }
        var received: [String] { lock.withLock { _received } }
        var accepted: [NWConnection] { lock.withLock { _accepted } }
        func refused(_ origin: String) { lock.withLock { _refused.append(origin) } }
        func received(_ text: String) { lock.withLock { _received.append(text) } }
        func accepted(_ connection: NWConnection) { lock.withLock { _accepted.append(connection) } }
    }

    private let queue = DispatchQueue(label: "SyncWebSocketTests")
    private let log = Log()
    private var listener: NWListener!

    override func setUp() async throws {
        let log = log, queue = queue
        listener = try NWListener(using: SyncWebSocket.listenerParameters(onRefused: { log.refused($0) }), on: .any)
        listener.newConnectionHandler = { connection in
            log.accepted(connection)
            connection.start(queue: queue)
            connection.receiveMessage { data, _, _, _ in
                if let data { log.received(String(decoding: data, as: UTF8.self)) }
            }
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        await fulfillment(of: [ready], timeout: 5)
    }

    override func tearDown() {
        log.accepted.forEach { $0.cancel() }
        listener.cancel()
    }

    private var port: NWEndpoint.Port { listener.port! }

    /// The status line the listener answers a raw handshake with.
    private func answer(origin: String?) async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        defer { connection.cancel() }
        var request = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
            + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        if let origin { request += "\(origin)\r\n" }
        request += "\r\n"
        connection.start(queue: queue)
        connection.send(content: Data(request.utf8), completion: .idempotent)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
    }

    func testABrowsersHandshakeIsTurnedAway() async throws {
        let refusedStatus = try await answer(origin: "Origin: https://example.com")
        XCTAssertTrue(refusedStatus.hasPrefix("HTTP/1.1 4"), refusedStatus)
        let lowerCase = try await answer(origin: "origin: null")
        XCTAssertTrue(lowerCase.hasPrefix("HTTP/1.1 4"), lowerCase)
        let plain = try await answer(origin: nil)
        XCTAssertEqual(plain, "HTTP/1.1 101 Switching Protocols")
        XCTAssertEqual(log.refused, ["https://example.com", "null"])
    }

    /// The iPhone's side: `SyncWebSocket.parameters()` sends no `Origin`, its first message arrives.
    func testTheAppsOwnClientGetsThrough() async throws {
        let client = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port.rawValue)/")!), using: SyncWebSocket.parameters())
        defer { client.cancel() }
        let ready = expectation(description: "connected")
        client.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        client.start(queue: queue)
        await fulfillment(of: [ready], timeout: 5)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let sent = expectation(description: "sent")
        client.send(content: Data("hello".utf8), contentContext: .init(identifier: "message", metadata: [metadata]),
                    isComplete: true, completion: .contentProcessed { _ in sent.fulfill() })
        await fulfillment(of: [sent], timeout: 5)
        for _ in 0..<50 where log.received.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(log.received, ["hello"])
        XCTAssertTrue(log.refused.isEmpty)
    }
}
