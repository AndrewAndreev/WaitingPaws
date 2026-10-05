// Port of SyncCryptoTests.swift.
import { describe, expect, it } from 'vitest'
import { SyncMessage, SyncState } from '@core/index'
import { SyncCrypto, SyncCryptoError, SyncHandshake, SyncPrivateKey } from '@core/node/syncCrypto'
import * as nodeCrypto from 'node:crypto'

/** Both ends of one connection's key exchange. */
function handshake(deviceID = 'phone-1'): { phone: SyncHandshake; mac: SyncHandshake } {
  const phoneKey = SyncCrypto.newKey()
  const macKey = SyncCrypto.newKey()
  const phonePublic = phoneKey.publicKey
  const macPublic = macKey.publicKey
  const phone = new SyncCrypto.Handshake({
    privateKey: phoneKey,
    peerKey: macPublic,
    phoneKey: phonePublic,
    macKey: macPublic,
    deviceID,
  })
  const mac = new SyncCrypto.Handshake({
    privateKey: macKey,
    peerKey: phonePublic,
    phoneKey: phonePublic,
    macKey: macPublic,
    deviceID,
  })
  return { phone, mac }
}

const state: SyncMessage = {
  kind: 'state',
  state: SyncState.make({
    session: null,
    recordingSince: null,
    cameraReady: true,
    cameraTitle: 'Hall',
    streamName: 'hall',
    lastRecord: null,
  }),
}

describe('SyncCrypto', () => {
  it('new pairing derives the same secret and keys', () => {
    const { phone, mac } = handshake()
    expect(phone.transcript).toEqual(mac.transcript)
    expect(phone.newPairingSecret()).toBe(mac.newPairingSecret())

    const macCipher = mac.cipher(true, null)
    const phoneCipher = phone.cipher(false, null)
    expect(phoneCipher.open(macCipher.seal(state))).toEqual(state)
    const command: SyncMessage = { kind: 'command', command: { kind: 'startRecording' } }
    expect(macCipher.open(phoneCipher.seal(command))).toEqual(command)
  })

  it('proof only with the right secret and only for this connection', () => {
    const { phone, mac } = handshake()
    const proof = phone.proof('secret')
    expect(mac.verify(proof, 'secret')).toBe(true)
    expect(mac.verify(proof, 'another')).toBe(false)
    // A proof recorded on the Wi-Fi is useless on the next connection (new keys, new transcript).
    const { mac: nextMac } = handshake()
    expect(nextMac.verify(proof, 'secret')).toBe(false)
  })

  it('paired keys differ from unpaired ones', () => {
    const { phone, mac } = handshake()
    const macCipher = mac.cipher(true, 'secret')
    const phoneUnpaired = phone.cipher(false, null)
    expect(() => phoneUnpaired.open(macCipher.seal(state))).toThrow()
  })

  it('replayed, tampered and reflected frames are rejected', () => {
    const { phone, mac } = handshake()
    const macCipher = mac.cipher(true, null)
    const phoneCipher = phone.cipher(false, null)
    const frame = macCipher.seal(state)
    expect(() => phoneCipher.open(frame)).not.toThrow()
    expect(() => phoneCipher.open(frame), 'the same frame twice').toThrow(SyncCryptoError)
    const tampered = macCipher.seal(state)
    tampered[Math.floor(tampered.length / 2)] ^= 0x01
    expect(() => phoneCipher.open(tampered)).toThrow()
    // The Mac's own frame sent back to it: the other direction has another key.
    expect(() => macCipher.open(macCipher.seal(state))).toThrow()
  })

  it('a sealed frame travels as a SyncMessage', () => {
    const { phone, mac } = handshake()
    const macCipher = mac.cipher(true, null)
    const phoneCipher = phone.cipher(false, null)
    const wire = SyncMessage.encode({ kind: 'sealed', data: macCipher.seal(state) })
    expect(wire, 'nothing readable on the wire').not.toContain('Hall')
    const decoded = SyncMessage.decode(wire)
    if (decoded.kind !== 'sealed') throw new Error('not sealed')
    expect(phoneCipher.open(decoded.data)).toEqual(state)
  })
})

// Not in the Swift suite: the constructions CryptoKit uses, recomputed from the primitives.
describe('SyncCrypto byte layout', () => {
  const phoneRaw = Uint8Array.from({ length: 32 }, (_, i) => i + 1)
  const macRaw = Uint8Array.from({ length: 32 }, (_, i) => 200 - i)

  it('keeps raw keys and derives as CryptoKit does', () => {
    const phoneKey = SyncPrivateKey.fromRaw(phoneRaw)
    const macKey = SyncPrivateKey.fromRaw(macRaw)
    expect(phoneKey.rawRepresentation).toEqual(phoneRaw)
    expect(phoneKey.publicKey).toHaveLength(32)

    const phone = new SyncHandshake({
      privateKey: phoneKey,
      peerKey: macKey.publicKey,
      phoneKey: phoneKey.publicKey,
      macKey: macKey.publicKey,
      deviceID: 'Устройство',
    })
    const transcript = nodeCrypto
      .createHash('sha256')
      .update('waitingpaws-sync-v2')
      .update(phoneKey.publicKey)
      .update(macKey.publicKey)
      .update('Устройство', 'utf8')
      .digest()
    expect(Buffer.from(phone.transcript)).toEqual(transcript)

    const shared = nodeCrypto.diffieHellman({
      privateKey: nodeCrypto.createPrivateKey({
        key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), phoneRaw]),
        format: 'der',
        type: 'pkcs8',
      }),
      publicKey: nodeCrypto.createPublicKey({
        key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), macKey.publicKey]),
        format: 'der',
        type: 'spki',
      }),
    })
    const pairing = Buffer.from(nodeCrypto.hkdfSync('sha256', shared, transcript, 'pairing', 32)).toString('base64')
    expect(phone.newPairingSecret()).toBe(pairing)

    const proof = nodeCrypto
      .createHmac('sha256', 'secret')
      .update(Buffer.concat([transcript, Buffer.from('proof')]))
      .digest()
    expect(Buffer.from(phone.proof('secret'))).toEqual(proof)

    // Sealed box: nonce (12) | ciphertext | tag (16), key = HKDF(info: "phone->mac" + pairing secret).
    const sendKey = Buffer.from(nodeCrypto.hkdfSync('sha256', shared, transcript, 'phone->macsecret', 32))
    const sealed = phone.cipher(false, 'secret').seal({ kind: 'pending' })
    const decipher = nodeCrypto.createDecipheriv('chacha20-poly1305', sendKey, sealed.subarray(0, 12), {
      authTagLength: 16,
    })
    decipher.setAuthTag(sealed.subarray(sealed.length - 16))
    const plain = Buffer.concat([decipher.update(sealed.subarray(12, sealed.length - 16)), decipher.final()])
    expect(JSON.parse(plain.toString('utf8'))).toEqual({ seq: 1, message: { pending: {} } })
  })

  it('refuses a peer key of the wrong size', () => {
    expect(
      () =>
        new SyncHandshake({
          privateKey: SyncCrypto.newKey(),
          peerKey: new Uint8Array(31),
          phoneKey: new Uint8Array(31),
          macKey: new Uint8Array(32),
          deviceID: 'x',
        }),
    ).toThrow(SyncCryptoError)
  })
})
