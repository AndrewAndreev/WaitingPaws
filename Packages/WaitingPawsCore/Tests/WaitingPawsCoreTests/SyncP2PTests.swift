import CryptoKit
import XCTest
@testable import WaitingPawsCore

/// The direct link's part of sync v2: its signals travel sealed and only between builds that list the feature, and the
/// Go side's status reads into what the UI shows.
final class SyncP2PTests: XCTestCase {
    func testSignalTravelsSealedAndNeverInTheClear() throws {
        let phoneKey = SyncCrypto.newKey(), macKey = SyncCrypto.newKey()
        let phonePublic = phoneKey.publicKey.rawRepresentation, macPublic = macKey.publicKey.rawRepresentation
        let phone = try SyncCrypto.Handshake(privateKey: phoneKey, peerKey: macPublic, phoneKey: phonePublic,
                                             macKey: macPublic, deviceID: "D1")
        let mac = try SyncCrypto.Handshake(privateKey: macKey, peerKey: phonePublic, phoneKey: phonePublic,
                                           macKey: macPublic, deviceID: "D1")
        var phoneCipher = phone.cipher(isMac: false, pairingSecret: nil)
        var macCipher = mac.cipher(isMac: true, pairingSecret: nil)

        let signal = SyncMessage.p2p(SyncP2PSignal(link: P2PLinkKind.out.rawValue, payload: #"{"type":"offer","sdp":"v=0"}"#))
        XCTAssertTrue(signal.needsSealing, "SDP names the addresses: sealed like states and commands")
        let wire = try SyncMessage.sealed(try phoneCipher.seal(signal)).encoded()
        XCTAssertFalse(String(decoding: wire, as: UTF8.self).contains("offer"))
        guard case .sealed(let data) = try SyncMessage.decode(wire) else { return XCTFail("not sealed") }
        XCTAssertEqual(try macCipher.open(data), signal)
    }

    func testFeaturesAreOptionalBothWays() throws {
        let hello = SyncHello(deviceID: "D1", deviceName: "iPhone", publicKey: Data([1]), features: [SyncFeature.p2p])
        let decoded = try SyncProtocol.decoder().decode(SyncHello.self, from: SyncProtocol.encoder().encode(hello))
        XCTAssertEqual(decoded.features, ["p2p"])
        // A hello and a welcome from builds before the field: no features, so no p2p messages to them.
        let oldHello = #"{"deviceID":"D1","deviceName":"iPhone","publicKey":"AQ==","protocolVersion":2}"#
        XCTAssertNil(try SyncProtocol.decoder().decode(SyncHello.self, from: Data(oldHello.utf8)).features)
        let oldWelcome = #"{"hostName":"Mac","go2rtcPort":1,"username":"","password":"","addresses":[]}"#
        XCTAssertNil(try SyncProtocol.decoder().decode(SyncWelcome.self, from: Data(oldWelcome.utf8)).features)
    }

    /// What the Go side writes (GoMobile/p2p Status), shortened from a real run.
    private let connected = #"""
    {"label":"out","role":"offer","state":"connected","since":1794521000000,"gen":0,
     "local":{"type":"srflx","protocol":"udp","address":"185.1.2.3","port":40000},
     "remote":{"type":"prflx","protocol":"udp","address":"87.116.135.237","port":15261},
     "rtt":48.2,"rttMin":41.0,"rttAvg":46.5,"pings":10,"pongs":9,"lastPong":1794521010000,"connectedAt":1794521001000,
     "localTypes":{"srflx":2},"remoteTypes":{"srflx":2},
     "nat":{"mapping":"dependent","public":"185.1.2.3:40000","answers":["185.1.2.3:40000","185.1.2.3:40007",""],
            "servers":["stun.cloudflare.com:3478","stun.l.google.com:19302","stun1.l.google.com:19302"],"took":620},
     "peerNat":{"mapping":"independent","public":"87.116.135.237:15261","answers":[],"servers":[],"took":0},
     "peerIface":"en0","restarts":0,"streams":2,"streamsOpened":5,"bytesIn":7340032,"bytesOut":2048}
    """#

    func testStatusFromGo() throws {
        let status = try XCTUnwrap(P2PLinkStatus.decode(connected))
        XCTAssertEqual(status.kind, .out)
        XCTAssertEqual(status.pairText, "srflx ↔ prflx")
        XCTAssertEqual(status.nat?.kind, .dependent)
        XCTAssertEqual(status.nat?.answeredServers, ["stun.cloudflare.com:3478", "stun.l.google.com:19302"])
        XCTAssertEqual(status.peerNat?.kind, .independent)
        XCTAssertEqual(status.peerNat?.publicIP, "87.116.135.237")
        XCTAssertTrue(status.isAlive)
        XCTAssertTrue(status.carriesStreams, "the sync link and the picture go over it")
        XCTAssertEqual(status.bytesIn, 7_340_032)

        let fresh = Date(timeIntervalSince1970: 1_794_521_012)
        XCTAssertEqual(status.outcome(now: fresh), .direct(stale: false))
        XCTAssertEqual(status.outcome(now: fresh.addingTimeInterval(10)), .direct(stale: true), "no pong for 12 s")
        XCTAssertEqual(status.silence(now: fresh) ?? 0, 2, accuracy: 0.01)
    }

    func testOutcomes() {
        var status = P2PLinkStatus(label: "lan", state: "connecting")
        XCTAssertEqual(status.outcome(), .checking)
        status.state = "failed"
        XCTAssertEqual(status.outcome(), .failed, "never connected")
        status.connectedAt = 1
        XCTAssertEqual(status.outcome(), .lost, "worked, then went")
        status.state = "disconnected"
        XCTAssertEqual(status.outcome(), .direct(stale: true))
        XCTAssertNil(P2PLinkStatus.decode("not json"))
    }

    func testZerosFromGoMeanNotYet() throws {
        // What the first build's Go side sent for a link that never connected (0 for "not yet")…
        let zeros = #"{"label":"out","state":"failed","since":1794521000000,"rtt":0,"lastPong":0,"connectedAt":0,"pings":0,"pongs":0,"error":"no direct path","seq":4}"#
        let failed = try XCTUnwrap(P2PLinkStatus.decode(zeros))
        XCTAssertEqual(failed.outcome(), .failed, "never connected: not «lost»")
        XCTAssertFalse(failed.everConnected)
        XCTAssertNil(failed.silence())
        XCTAssertFalse(failed.carriesStreams)
        XCTAssertEqual(failed.seq, 4)
        // …and one that has just connected, before its first pong: working, not «no answer for 56 years».
        let now = Date(timeIntervalSince1970: 1_794_521_003)
        let fresh = #"{"label":"lan","state":"connected","since":1794521002000,"rtt":0,"lastPong":0,"connectedAt":1794521002000,"pongs":0}"#
        let connected = try XCTUnwrap(P2PLinkStatus.decode(fresh))
        XCTAssertEqual(connected.outcome(now: now), .direct(stale: false))
        XCTAssertEqual(connected.silence(now: now) ?? -1, 1, accuracy: 0.01)
        XCTAssertFalse(connected.answered)
        // The current Go side leaves them out.
        let omitted = try XCTUnwrap(P2PLinkStatus.decode(#"{"label":"out","state":"failed","error":"no direct path","seq":2}"#))
        XCTAssertEqual(omitted.outcome(), .failed)
    }

    func testIPv6PairIsSaid() {
        var status = P2PLinkStatus(label: "out", state: "connected")
        status.local = P2PCandidate(type: "host", address: "2a00:1fa0::1", port: 5)
        status.remote = P2PCandidate(type: "host", address: "2a02:2168::9", port: 6)
        XCTAssertEqual(status.pairText, "host ↔ host IPv6")
    }

    func testRouterVerdict() {
        let none = P2PRouterResult(gateway: "192.168.100.1", pmp: .init(error: "no answer"), upnp: .init(error: "no answer"))
        XCTAssertEqual(none.verdict(publicIP: "87.116.135.237"), .unavailable)
        XCTAssertNil(none.method)

        let mappable = P2PRouterResult(gateway: "192.168.1.1", upnp: .init(device: "Keenetic Giga", external: "87.116.135.237"))
        XCTAssertEqual(mappable.verdict(publicIP: "87.116.135.237"), .mappable)
        XCTAssertEqual(mappable.method, "UPnP (Keenetic Giga)")

        let provider = P2PRouterResult(pmp: .init(external: "100.72.10.5"))
        XCTAssertEqual(provider.verdict(publicIP: "87.116.135.237"), .behindAnotherNAT, "the provider's CGNAT address")
        let elsewhere = P2PRouterResult(pmp: .init(external: "5.6.7.8"))
        XCTAssertEqual(elsewhere.verdict(publicIP: "87.116.135.237"), .behindAnotherNAT, "another NAT between router and internet")
        XCTAssertEqual(elsewhere.verdict(publicIP: nil), .mappable, "nothing to compare with")
    }

    func testPrivateAddresses() {
        for ip in ["10.1.2.3", "192.168.100.1", "172.20.0.1", "100.64.0.1", "100.127.255.255", "169.254.1.1", "fe80::1"] {
            XCTAssertTrue(P2PAddress.isPrivate(ip), ip)
        }
        for ip in ["87.116.135.237", "100.128.0.1", "172.32.0.1", "2a00:1fa0::1"] {
            XCTAssertFalse(P2PAddress.isPrivate(ip), ip)
        }
    }
}
