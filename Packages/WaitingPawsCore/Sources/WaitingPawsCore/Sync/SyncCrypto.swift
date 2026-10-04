import CryptoKit
import Foundation

/// Security of the iPhone ↔ Mac link (protocol v2). Both sides make a fresh Curve25519 key per connection
/// and agree on a shared secret, so nothing readable crosses the Wi-Fi:
///
/// 1. iPhone → `hello` with its public key; Mac → `challenge` with its own.
/// 2. iPhone → `proof`: HMAC of the handshake with the pairing secret it keeps for this Mac (nil when new).
///    The Mac lets a known iPhone in only with a valid proof, so a recorded hello can't be replayed and the
///    secret itself is never sent.
/// 3. A new iPhone waits for «Разрешить» on the Mac (`pending`); both sides then derive the same new pairing
///    secret from the handshake (trust on first use, like Bluetooth pairing).
/// 4. Everything after that (`welcome` with the go2rtc password, states, commands) travels sealed with
///    ChaChaPoly, a separate key per direction and a counter against replays.
public enum SyncCrypto {
    public struct Handshake {
        public let transcript: Data
        let shared: SharedSecret

        /// - Parameters: the iPhone's and the Mac's public keys and the iPhone's device id, as sent.
        public init(privateKey: Curve25519.KeyAgreement.PrivateKey, peerKey: Data,
                    phoneKey: Data, macKey: Data, deviceID: String) throws {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey)
            shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
            var hash = SHA256()
            hash.update(data: Data("waitingpaws-sync-v2".utf8))
            hash.update(data: phoneKey)
            hash.update(data: macKey)
            hash.update(data: Data(deviceID.utf8))
            transcript = Data(hash.finalize())
        }

        /// What the iPhone sends to prove it was paired before, bound to this very handshake.
        public func proof(pairingSecret: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: transcript + Data("proof".utf8),
                                                 using: SymmetricKey(data: Data(pairingSecret.utf8))))
        }

        public func verify(proof: Data, pairingSecret: String) -> Bool {
            HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: transcript + Data("proof".utf8),
                                                   using: SymmetricKey(data: Data(pairingSecret.utf8)))
        }

        /// The pairing secret both sides store after a new iPhone is allowed (never sent over the network).
        public func newPairingSecret() -> String {
            let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript,
                                                     sharedInfo: Data("pairing".utf8), outputByteCount: 32)
            return key.withUnsafeBytes { Data($0) }.base64EncodedString()
        }

        /// Keys for this connection. `pairingSecret` is mixed in when the iPhone proved it knows it.
        public func cipher(isMac: Bool, pairingSecret: String?) -> SyncCipher {
            let extra = Data((pairingSecret ?? "").utf8)
            func key(_ label: String) -> SymmetricKey {
                shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript,
                                               sharedInfo: Data(label.utf8) + extra, outputByteCount: 32)
            }
            let phoneToMac = key("phone->mac"), macToPhone = key("mac->phone")
            return SyncCipher(sendKey: isMac ? macToPhone : phoneToMac, receiveKey: isMac ? phoneToMac : macToPhone)
        }
    }

    public static func newKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }
}

/// Seals and opens the messages of one connection. Each side counts what it sends; a frame with a counter
/// that is not higher than the last one seen is rejected.
public struct SyncCipher {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    private struct Envelope: Codable {
        var seq: UInt64
        var message: SyncMessage
    }

    public enum Failure: Error { case replayed }

    public mutating func seal(_ message: SyncMessage) throws -> Data {
        sent += 1
        let plain = try SyncProtocol.encoder().encode(Envelope(seq: sent, message: message))
        return try ChaChaPoly.seal(plain, using: sendKey).combined
    }

    public mutating func open(_ data: Data) throws -> SyncMessage {
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: receiveKey)
        let envelope = try SyncProtocol.decoder().decode(Envelope.self, from: plain)
        guard envelope.seq > received else { throw Failure.replayed }
        received = envelope.seq
        return envelope.message
    }
}
