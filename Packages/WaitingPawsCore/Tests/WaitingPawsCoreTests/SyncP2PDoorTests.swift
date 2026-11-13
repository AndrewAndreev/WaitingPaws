import XCTest
@testable import WaitingPawsCore

/// The door's knocks: only the paired side opens them, one way only, never twice, and an offer fits one datagram.
final class SyncP2PDoorTests: XCTestCase {
    private let secret = "c2VjcmV0LXRoYXQtYm90aC1zaWRlcy1rZWVwLTMyYnl0ZXM="

    /// About the size of a real offer (`TestLinkSignalledThroughTheDoors`: 997 bytes on loopback).
    private func offer() -> String {
        let candidates = (0..<6).map { "a=candidate:\($0) 1 udp 1694498815 198.51.100.\($0) 1240\($0) typ srflx raddr 0.0.0.0 rport 5\($0)\\r\\n" }
        return #"{"type":"offer","gen":0,"sdp":"v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=fingerprint:sha-256 0B:6C:1A:7F:2E:91:44:D3:56:AB:00:CD:EF:12:34:56:78:9A:BC:DE:F0:11:22:33:44:55:66:77:88:99:AA:BB\r\na=ice-ufrag:ZfQbFhDkWfJbpTlQ\r\na=ice-pwd:aBcDeFgHiJkLmNoPqRsTuVwXyZ012345\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"#
            + candidates.joined() + #"","nat":{"mapping":"dependent","public":"198.51.100.35:12402","answers":["198.51.100.35:12402","198.51.100.35:12403","198.51.100.35:12404"],"servers":["stun.cloudflare.com:3478","stun.l.google.com:19302","stun1.l.google.com:19302"],"iface":"pdp_ip0","took":412},"iface":"pdp_ip0"}"#
    }

    func testOnlyThePairedSideOpensAKnockAndOnlyOneWay() throws {
        let knock = P2PDoorKnock(from: "PHONE-1", signal: SyncP2PSignal(link: "out", payload: offer()))
        let sealed = try P2PDoorSeal.seal(knock, secret: secret, .phoneToMac)
        XCTAssertLessThan(sealed.count, 1400, "fits one datagram (the door takes at most 1400 bytes)")
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("198.51.100"), "the addresses are not readable")

        XCTAssertEqual(try P2PDoorSeal.open(sealed, secret: secret, .phoneToMac), knock)
        XCTAssertThrowsError(try P2PDoorSeal.open(sealed, secret: "another pairing", .phoneToMac))
        XCTAssertThrowsError(try P2PDoorSeal.open(sealed, secret: secret, .macToPhone), "a knock can't pass for an answer")
        var tampered = sealed
        tampered[tampered.count / 2] ^= 1
        XCTAssertThrowsError(try P2PDoorSeal.open(tampered, secret: secret, .phoneToMac))
        XCTAssertThrowsError(try P2PDoorSeal.open(Data("WPd junk".utf8), secret: secret, .phoneToMac))
    }

    func testAKnockIsTakenOnceAndOnlyWhileFresh() throws {
        var guardian = P2PDoorGuard()
        let now = Date()
        let knock = P2PDoorKnock(from: "PHONE-1", signal: SyncP2PSignal(link: "out", payload: "{}"), sent: now)
        XCTAssertTrue(guardian.accept(knock, now: now))
        XCTAssertFalse(guardian.accept(knock, now: now.addingTimeInterval(1)), "the copies sent against loss")
        let old = P2PDoorKnock(from: "PHONE-1", signal: knock.signal, sent: now.addingTimeInterval(-301))
        XCTAssertFalse(guardian.accept(old, now: now), "recorded and played again later")
        let ahead = P2PDoorKnock(from: "PHONE-1", signal: knock.signal, sent: now.addingTimeInterval(301))
        XCTAssertFalse(guardian.accept(ahead, now: now))
        let skewed = P2PDoorKnock(from: "PHONE-1", signal: knock.signal, sent: now.addingTimeInterval(-90))
        XCTAssertTrue(guardian.accept(skewed, now: now), "a clock a minute or so off still works")
    }

    func testTheMacsSignalsMayCarryItsDoor() throws {
        let signal = SyncP2PSignal(link: "out", payload: "{}", door: "203.0.113.10:41984")
        let decoded = try JSONDecoder().decode(SyncP2PSignal.self, from: JSONEncoder().encode(signal))
        XCTAssertEqual(decoded.door, "203.0.113.10:41984")
        // From builds before the door.
        let old = try JSONDecoder().decode(SyncP2PSignal.self, from: Data(#"{"link":"out","payload":"{}"}"#.utf8))
        XCTAssertNil(old.door)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("door"))
    }

    func testTheSprayBandCoversTheCarriersPorts() {
        // A carrier seen on 2026-11-13 (its ports, a documentation address).
        var carrier = P2PCarrierPorts(ip: "198.51.100.35", ports: [], seen: .distantPast)
        for port in [12459, 12453, 12402, 12413] { carrier.add(ip: "198.51.100.35", port: port) }
        XCTAssertEqual(carrier.ports, [12413, 12402, 12453, 12459])
        XCTAssertEqual(carrier.band, (12402 - 64)...(12459 + 64))
        carrier.add(ip: "198.51.100.35", port: 12402)
        XCTAssertEqual(carrier.ports.first, 12402, "seen again: newest, once")
        XCTAssertEqual(carrier.ports.count, 4)

        // Ports far apart: the band stays at most 256 wide, around the newest.
        carrier.add(ip: "198.51.100.35", port: 30000)
        XCTAssertEqual(carrier.band?.count, 256)
        XCTAssertTrue(carrier.band?.contains(30000) == true)

        // A new address starts over; never below 1024.
        carrier.add(ip: "5.6.7.8", port: 1050)
        XCTAssertEqual(carrier.ports, [1050])
        XCTAssertEqual(carrier.band, 1024...(1050 + 64))
        for port in 1...20 { carrier.add(ip: "5.6.7.8", port: 2000 + port) }
        XCTAssertEqual(carrier.ports.count, P2PCarrierPorts.keep)
    }
}
