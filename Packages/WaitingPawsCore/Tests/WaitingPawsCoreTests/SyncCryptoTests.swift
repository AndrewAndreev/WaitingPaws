import XCTest
@testable import WaitingPawsCore

final class SyncCryptoTests: XCTestCase {
    /// Both ends of one connection's key exchange.
    private func handshake(deviceID: String = "phone-1") throws -> (phone: SyncCrypto.Handshake, mac: SyncCrypto.Handshake) {
        let phoneKey = SyncCrypto.newKey(), macKey = SyncCrypto.newKey()
        let phonePublic = phoneKey.publicKey.rawRepresentation, macPublic = macKey.publicKey.rawRepresentation
        let phone = try SyncCrypto.Handshake(privateKey: phoneKey, peerKey: macPublic,
                                             phoneKey: phonePublic, macKey: macPublic, deviceID: deviceID)
        let mac = try SyncCrypto.Handshake(privateKey: macKey, peerKey: phonePublic,
                                           phoneKey: phonePublic, macKey: macPublic, deviceID: deviceID)
        return (phone, mac)
    }

    private let state = SyncMessage.state(SyncState(session: nil, recordingSince: nil, cameraReady: true, cameraTitle: "Hall",
                                                    streamName: "hall", lastRecord: nil))

    func testNewPairingDerivesTheSameSecretAndKeys() throws {
        let (phone, mac) = try handshake()
        XCTAssertEqual(phone.transcript, mac.transcript)
        XCTAssertEqual(phone.newPairingSecret(), mac.newPairingSecret())

        var macCipher = mac.cipher(isMac: true, pairingSecret: nil)
        var phoneCipher = phone.cipher(isMac: false, pairingSecret: nil)
        XCTAssertEqual(try phoneCipher.open(try macCipher.seal(state)), state)
        let command = SyncMessage.command(.startRecording)
        XCTAssertEqual(try macCipher.open(try phoneCipher.seal(command)), command)
    }

    func testProofOnlyWithTheRightSecretAndOnlyForThisConnection() throws {
        let (phone, mac) = try handshake()
        let proof = phone.proof(pairingSecret: "secret")
        XCTAssertTrue(mac.verify(proof: proof, pairingSecret: "secret"))
        XCTAssertFalse(mac.verify(proof: proof, pairingSecret: "another"))
        // A proof recorded on the Wi-Fi is useless on the next connection (new keys, new transcript).
        let (_, nextMac) = try handshake()
        XCTAssertFalse(nextMac.verify(proof: proof, pairingSecret: "secret"))
    }

    func testPairedKeysDifferFromUnpairedOnes() throws {
        let (phone, mac) = try handshake()
        var macCipher = mac.cipher(isMac: true, pairingSecret: "secret")
        var phoneUnpaired = phone.cipher(isMac: false, pairingSecret: nil)
        XCTAssertThrowsError(try phoneUnpaired.open(try macCipher.seal(state)))
    }

    func testReplayedTamperedAndReflectedFramesAreRejected() throws {
        let (phone, mac) = try handshake()
        var macCipher = mac.cipher(isMac: true, pairingSecret: nil)
        var phoneCipher = phone.cipher(isMac: false, pairingSecret: nil)
        let frame = try macCipher.seal(state)
        XCTAssertNoThrow(try phoneCipher.open(frame))
        XCTAssertThrowsError(try phoneCipher.open(frame), "the same frame twice")
        var tampered = try macCipher.seal(state)
        tampered[tampered.count / 2] ^= 0x01
        XCTAssertThrowsError(try phoneCipher.open(tampered))
        // The Mac's own frame sent back to it: the other direction has another key.
        XCTAssertThrowsError(try macCipher.open(try macCipher.seal(state)))
    }

    func testSealedFrameTravelsAsASyncMessage() throws {
        let (phone, mac) = try handshake()
        var macCipher = mac.cipher(isMac: true, pairingSecret: nil)
        var phoneCipher = phone.cipher(isMac: false, pairingSecret: nil)
        let wire = try SyncMessage.sealed(try macCipher.seal(state)).encoded()
        XCTAssertFalse(String(decoding: wire, as: UTF8.self).contains("Hall"), "nothing readable on the wire")
        guard case .sealed(let data) = try SyncMessage.decode(wire) else { return XCTFail("not sealed") }
        XCTAssertEqual(try phoneCipher.open(data), state)
    }
}
