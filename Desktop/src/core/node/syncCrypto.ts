// Port of Sync/SyncCrypto.swift on node:crypto (Electron main / Node only — the one core file that imports
// a Node module; it is deliberately not re-exported from core/index.ts).
//
// Security of the iPhone ↔ Mac link (protocol v2). Both sides make a fresh Curve25519 key per connection
// and agree on a shared secret, so nothing readable crosses the Wi-Fi:
//
// 1. iPhone → `hello` with its public key; Mac → `challenge` with its own.
// 2. iPhone → `proof`: HMAC of the handshake with the pairing secret it keeps for this Mac (nil when new).
//    The Mac lets a known iPhone in only with a valid proof, so a recorded hello can't be replayed and the
//    secret itself is never sent.
// 3. A new iPhone waits for «Разрешить» on the Mac (`pending`); both sides then derive the same new pairing
//    secret from the handshake (trust on first use, like Bluetooth pairing).
// 4. Everything after that (`welcome` with the go2rtc password, states, commands) travels sealed with
//    ChaChaPoly, a separate key per direction and a counter against replays.
//
// Byte compatibility with CryptoKit:
// - keys: raw 32-byte X25519 (`rawRepresentation`), shared secret = raw X25519 output;
// - transcript = SHA-256("waitingpaws-sync-v2" ‖ phoneKey ‖ macKey ‖ UTF-8 deviceID);
// - proof = HMAC-SHA256(key: UTF-8 pairing secret, "transcript ‖ proof");
// - HKDF-SHA256(ikm: shared secret, salt: transcript, info, 32 bytes) with info "pairing" (the new pairing
//   secret, stored as base64), "phone->mac" / "mac->phone" + UTF-8 pairing secret (the direction keys);
// - sealed frame = `ChaChaPoly.SealedBox.combined`: 12-byte random nonce ‖ ciphertext ‖ 16-byte tag, no AAD;
//   the plaintext is the JSON `{"seq":n,"message":<SyncMessage>}`.

// The web tsconfig (renderer) does not load Node's types and type-checks every file in src/core; there this
// import is `any`. Prefer excluding src/core/node from tsconfig.web.json.
// @ts-ignore -- node:buffer has no types in the renderer program
import { Buffer } from 'node:buffer'
// @ts-ignore -- node:crypto has no types in the renderer program
import * as nodeCrypto from 'node:crypto'
import { DecodingError, ObjectReader, base64Encode, expectInt, utf8Decode, utf8Encode } from '../codable'
import { SyncMessage } from '../syncProtocol'

type NodeKeyObject = ReturnType<typeof nodeCrypto.createPublicKey>

/** DER prefixes of an X25519 SubjectPublicKeyInfo and PKCS #8 private key; the raw 32 bytes follow. */
const spkiPrefix = fromHex('302a300506032b656e032100')
const pkcs8Prefix = fromHex('302e020100300506032b656e04220420')

/** A Curve25519 key-agreement private key (`Curve25519.KeyAgreement.PrivateKey`). */
export class SyncPrivateKey {
  private constructor(
    /** @internal */ readonly keyObject: NodeKeyObject,
    /** The public key, raw 32 bytes (`publicKey.rawRepresentation`), as sent in `hello` / `challenge`. */
    readonly publicKey: Uint8Array,
  ) {}

  static generate(): SyncPrivateKey {
    const { privateKey, publicKey } = nodeCrypto.generateKeyPairSync('x25519')
    return new SyncPrivateKey(privateKey, rawPublicKey(publicKey))
  }

  /** From the raw 32 bytes (`init(rawRepresentation:)`). */
  static fromRaw(raw: Uint8Array): SyncPrivateKey {
    if (raw.length !== 32) throw new RangeError('An X25519 private key is 32 bytes')
    const keyObject = nodeCrypto.createPrivateKey({ key: Buffer.from(concat(pkcs8Prefix, raw)), format: 'der', type: 'pkcs8' })
    return new SyncPrivateKey(keyObject, rawPublicKey(nodeCrypto.createPublicKey(keyObject)))
  }

  /** The raw 32 bytes (`rawRepresentation`). */
  get rawRepresentation(): Uint8Array {
    const der = new Uint8Array(this.keyObject.export({ type: 'pkcs8', format: 'der' }))
    return der.slice(der.length - 32)
  }
}

function rawPublicKey(key: NodeKeyObject): Uint8Array {
  const der = new Uint8Array(key.export({ type: 'spki', format: 'der' }))
  return der.slice(der.length - 32)
}

function importPublicKey(raw: Uint8Array): NodeKeyObject {
  if (raw.length !== 32) throw new SyncCryptoError('incorrectKeySize')
  return nodeCrypto.createPublicKey({ key: Buffer.from(concat(spkiPrefix, raw)), format: 'der', type: 'spki' })
}

export type SyncCryptoErrorKind =
  /** A peer key that is not 32 bytes or not a usable X25519 key. */
  | 'incorrectKeySize'
  /** A sealed frame that does not open with this key (tampered, the other direction, another connection). */
  | 'authenticationFailure'
  /** `SyncCipher.Failure.replayed`: a frame whose counter is not higher than the last one seen. */
  | 'replayed'

export class SyncCryptoError extends Error {
  constructor(
    readonly kind: SyncCryptoErrorKind,
    options?: { cause?: unknown },
  ) {
    super(`SyncCrypto: ${kind}`, options)
    this.name = 'SyncCryptoError'
  }
}

/** One connection's key exchange (`SyncCrypto.Handshake`). */
export class SyncHandshake {
  readonly transcript: Uint8Array
  private readonly shared: Uint8Array

  /** The iPhone's and the Mac's public keys and the iPhone's device id, as sent. */
  constructor(params: {
    privateKey: SyncPrivateKey
    peerKey: Uint8Array
    phoneKey: Uint8Array
    macKey: Uint8Array
    deviceID: string
  }) {
    const peer = importPublicKey(params.peerKey)
    try {
      this.shared = new Uint8Array(nodeCrypto.diffieHellman({ privateKey: params.privateKey.keyObject, publicKey: peer }))
    } catch (error) {
      throw new SyncCryptoError('incorrectKeySize', { cause: error })
    }
    this.transcript = new Uint8Array(
      nodeCrypto
        .createHash('sha256')
        .update(utf8Encode('waitingpaws-sync-v2'))
        .update(params.phoneKey)
        .update(params.macKey)
        .update(utf8Encode(params.deviceID))
        .digest(),
    )
  }

  /** What the iPhone sends to prove it was paired before, bound to this very handshake. */
  proof(pairingSecret: string): Uint8Array {
    return hmac(utf8Encode(pairingSecret), concat(this.transcript, utf8Encode('proof')))
  }

  verify(proof: Uint8Array, pairingSecret: string): boolean {
    const expected = this.proof(pairingSecret)
    return proof.length === expected.length && nodeCrypto.timingSafeEqual(proof, expected)
  }

  /** The pairing secret both sides store after a new iPhone is allowed (never sent over the network). */
  newPairingSecret(): string {
    return base64Encode(this.derive(utf8Encode('pairing')))
  }

  /** Keys for this connection. `pairingSecret` is mixed in when the iPhone proved it knows it. */
  cipher(isMac: boolean, pairingSecret: string | null): SyncCipher {
    const extra = utf8Encode(pairingSecret ?? '')
    const phoneToMac = this.derive(concat(utf8Encode('phone->mac'), extra))
    const macToPhone = this.derive(concat(utf8Encode('mac->phone'), extra))
    return new SyncCipher(isMac ? macToPhone : phoneToMac, isMac ? phoneToMac : macToPhone)
  }

  /** `SharedSecret.hkdfDerivedSymmetricKey(using: SHA256, salt: transcript, sharedInfo:, outputByteCount: 32)`. */
  private derive(info: Uint8Array): Uint8Array {
    return new Uint8Array(nodeCrypto.hkdfSync('sha256', this.shared, this.transcript, info, 32))
  }
}

/**
 * Seals and opens the messages of one connection. Each side counts what it sends; a frame with a counter
 * that is not higher than the last one seen is rejected.
 */
export class SyncCipher {
  private sent = 0
  private received = 0

  constructor(
    private readonly sendKey: Uint8Array,
    private readonly receiveKey: Uint8Array,
  ) {}

  /** The bytes to send as `SyncMessage` `sealed`. */
  seal(message: SyncMessage): Uint8Array {
    this.sent += 1
    const plain = utf8Encode(JSON.stringify({ seq: this.sent, message: SyncMessage.toJSON(message) }))
    const nonce = new Uint8Array(nodeCrypto.randomBytes(12))
    const cipher = nodeCrypto.createCipheriv('chacha20-poly1305', this.sendKey, nonce, { authTagLength: 16 })
    const ciphertext = concat(new Uint8Array(cipher.update(plain)), new Uint8Array(cipher.final()))
    return concat(nonce, ciphertext, new Uint8Array(cipher.getAuthTag()))
  }

  /** Opens a `sealed` frame from the other side. Throws `SyncCryptoError` (`authenticationFailure`, `replayed`). */
  open(data: Uint8Array): SyncMessage {
    if (data.length < 12 + 16) throw new SyncCryptoError('authenticationFailure')
    const nonce = data.subarray(0, 12)
    const ciphertext = data.subarray(12, data.length - 16)
    const tag = data.subarray(data.length - 16)
    let plain: Uint8Array
    try {
      const decipher = nodeCrypto.createDecipheriv('chacha20-poly1305', this.receiveKey, nonce, { authTagLength: 16 })
      decipher.setAuthTag(tag)
      plain = concat(new Uint8Array(decipher.update(ciphertext)), new Uint8Array(decipher.final()))
    } catch (error) {
      throw new SyncCryptoError('authenticationFailure', { cause: error })
    }
    const envelope = new ObjectReader(JSON.parse(utf8Decode(plain)), 'envelope')
    const seq = envelope.required('seq', expectInt)
    if (seq < 0) throw new DecodingError('envelope.seq', 'expected an unsigned integer')
    const message = envelope.required('message', (value, path) => SyncMessage.fromJSON(value, path))
    if (!(seq > this.received)) throw new SyncCryptoError('replayed')
    this.received = seq
    return message
  }
}

/** `SyncCrypto` as in Swift: `SyncCrypto.newKey()`, `new SyncCrypto.Handshake({...})`. */
export const SyncCrypto = {
  newKey(): SyncPrivateKey {
    return SyncPrivateKey.generate()
  },
  Handshake: SyncHandshake,
}

// MARK: - Bytes

function hmac(key: Uint8Array, data: Uint8Array): Uint8Array {
  return new Uint8Array(nodeCrypto.createHmac('sha256', key).update(data).digest())
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0))
  let offset = 0
  for (const part of parts) {
    out.set(part, offset)
    offset += part.length
  }
  return out
}

function fromHex(hex: string): Uint8Array {
  return Uint8Array.from(hex.match(/../g) ?? [], (byte) => parseInt(byte, 16))
}
