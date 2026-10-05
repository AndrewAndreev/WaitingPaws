// The iPhone link host (src/main/sync): a minimal iPhone written here with the core protocol and crypto (what
// SyncClient.swift does) talks to the real host over a WebSocket on 127.0.0.1. Bonjour is off: nothing here
// listens beyond loopback or sends multicast.
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { connect as connectTCP, type Socket } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { PlannedExit, SyncHello, SyncHostInfo, SyncMessage, TrainingPlan, TrainingSession, setCoreLanguage } from '@core/index'
import { SyncCrypto, type SyncCipher, type SyncHandshake } from '@core/node/syncCrypto'
import { SyncHost, type SyncHostCommand, type SyncHostState, syncHostInfo, syncState } from '../src/main/sync/host'
import { PairedDeviceStore, type SecretBox } from '../src/main/sync/deviceStore'
import { webSocketAccept } from '../src/main/sync/websocket'
import { answerQuery, serviceNames, serviceRecords } from '../src/main/sync/bonjour'
import { RecordType, type ResourceRecord, decodeMessage, encodeMessage, readName } from '../src/main/sync/dnsPacket'
import { onSubnet, welcomeAddresses } from '../src/main/sync/network'
import { parseRegQuery, pcModelName } from '../src/main/sync/identity'

// MARK: - Helpers

async function until(predicate: () => boolean, timeout = 2000): Promise<void> {
  const start = Date.now()
  while (!predicate()) {
    if (Date.now() - start > timeout) throw new Error('timed out waiting')
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

const plan = TrainingPlan.make({
  title: 'Тренировка',
  exits: [PlannedExit.make({ number: 1, duration: 5 }), PlannedExit.make({ number: 2, duration: 30 })],
})

function baseState(): SyncHostState {
  return {
    session: null,
    recordingSince: null,
    cameraReady: true,
    cameraTitle: 'Прихожая',
    streamName: 'hall',
    lastRecord: null,
    pendingPlan: null,
    cameraSource: 'xiaomi://1:2@3?did=4',
    streamRevision: 1,
  }
}

/// A host on 127.0.0.1 with its devices in `directory`, and what it asked of the backend.
class Harness {
  state = baseState()
  commands: SyncHostCommand[] = []
  changes = 0
  forgotten = 0
  password = 'lan-password-1'
  readonly host: SyncHost

  constructor(
    readonly directory: string,
    box?: SecretBox,
    model: string | Promise<string> = 'Dell XPS 15 9510',
  ) {
    this.host = new SyncHost(
      {
        state: () => this.state,
        command: (command) => this.commands.push(command),
        access: () => ({ port: 1984, username: 'waitingpaws', password: this.password }),
        onDeviceForgotten: () => (this.forgotten += 1),
        onChange: () => (this.changes += 1),
      },
      {
        name: 'Test PC',
        listenAddress: '127.0.0.1',
        port: 0,
        bonjour: false,
        devices: new PairedDeviceStore({ file: join(directory, 'sync-devices.json'), box }),
        stateInterval: 40,
        model,
        log: () => undefined,
      },
    )
  }

  async start(): Promise<number> {
    this.host.start()
    await until(() => this.host.port !== null)
    return this.host.port!
  }
}

/// The iPhone side (SyncClient.swift): hello, then answers the challenge with a proof of its secret (or none), switches
/// keys on `pending`, keeps the new secret on `welcome`.
class TestPhone {
  readonly inbox: SyncMessage[] = []
  readonly socket: WebSocket
  secret: string | null
  closed = false
  private readonly privateKey = SyncCrypto.newKey()
  private handshake: SyncHandshake | null = null
  private cipher: SyncCipher | null = null
  private freshPairing = false
  private readonly opened: Promise<void>

  constructor(
    port: number,
    readonly deviceID = 'PHONE-1',
    readonly deviceName = 'Test iPhone',
    secret: string | null = null,
  ) {
    this.secret = secret
    this.socket = new WebSocket(`ws://127.0.0.1:${port}/`)
    this.opened = new Promise((resolve, reject) => {
      this.socket.onopen = () => resolve()
      this.socket.onerror = () => reject(new Error('connection failed'))
    })
    this.opened.catch(() => undefined)
    this.socket.onmessage = (event) => this.receive(String(event.data))
    this.socket.onclose = () => (this.closed = true)
  }

  async ready(): Promise<void> {
    await this.opened
  }

  async join(): Promise<void> {
    await this.opened
    this.send({
      kind: 'hello',
      hello: SyncHello.make({ deviceID: this.deviceID, deviceName: this.deviceName, publicKey: this.privateKey.publicKey, platform: 'iphone', model: 'iPhone 16' }),
    })
  }

  send(message: SyncMessage): void {
    let wire = message
    if (SyncMessage.needsSealing(message)) wire = { kind: 'sealed', data: this.cipher!.seal(message) }
    this.socket.send(SyncMessage.encode(wire))
  }

  /// Sends a frame as is (no sealing).
  sendRaw(text: string): void {
    this.socket.send(text)
  }

  async next<K extends SyncMessage['kind']>(kind: K, timeout = 2000): Promise<Extract<SyncMessage, { kind: K }>> {
    let found: SyncMessage | undefined
    await until(() => {
      const index = this.inbox.findIndex((message) => message.kind === kind)
      if (index >= 0) found = this.inbox.splice(index, 1)[0]
      return found !== undefined
    }, timeout)
    return found as Extract<SyncMessage, { kind: K }>
  }

  count(kind: SyncMessage['kind']): number {
    return this.inbox.filter((message) => message.kind === kind).length
  }

  close(): void {
    this.socket.close()
  }

  private receive(text: string): void {
    let message = SyncMessage.decode(text)
    if (message.kind === 'sealed') message = this.cipher!.open(message.data)
    switch (message.kind) {
      case 'challenge': {
        const phoneKey = this.privateKey.publicKey
        this.handshake = new SyncCrypto.Handshake({ privateKey: this.privateKey, peerKey: message.publicKey, phoneKey, macKey: message.publicKey, deviceID: this.deviceID })
        this.freshPairing = this.secret === null
        this.cipher = this.handshake.cipher(false, this.secret)
        this.send({ kind: 'proof', proof: this.secret === null ? null : this.handshake.proof(this.secret) })
        break
      }
      case 'pending':
        if (this.handshake && !this.freshPairing) {
          this.freshPairing = true
          this.cipher = this.handshake.cipher(false, null)
        }
        break
      case 'welcome':
        if (this.freshPairing && this.handshake) {
          this.secret = this.handshake.newPairingSecret()
          this.freshPairing = false
        }
        break
    }
    this.inbox.push(message)
  }
}

/// Pairs a new phone with the host (approving the request) and waits for its first state.
async function pair(harness: Harness, port: number, deviceID = 'PHONE-1', deviceName = 'Test iPhone'): Promise<TestPhone> {
  const phone = new TestPhone(port, deviceID, deviceName)
  await phone.join()
  await phone.next('pending')
  await until(() => harness.host.view().pairingRequests.some((request) => request.deviceName === deviceName))
  const request = harness.host.view().pairingRequests.find((item) => item.deviceName === deviceName)!
  harness.host.respond(request.id, true)
  await phone.next('welcome')
  await phone.next('state')
  return phone
}

// MARK: - Tests

describe('SyncHost', () => {
  let directory: string
  const hosts: SyncHost[] = []
  const phones: TestPhone[] = []

  const harness = (box?: SecretBox, model?: string | Promise<string>) => {
    const value = new Harness(directory, box, model)
    hosts.push(value.host)
    return value
  }
  const track = (phone: TestPhone) => {
    phones.push(phone)
    return phone
  }

  beforeEach(() => {
    setCoreLanguage('ru')
    directory = mkdtempSync(join(tmpdir(), 'wp-sync-'))
  })

  afterEach(() => {
    for (const phone of phones.splice(0)) phone.close()
    for (const host of hosts.splice(0)) host.stop()
    rmSync(directory, { recursive: true, force: true })
  })

  it('pairs a new iPhone after approval, then sends welcome and state and takes commands', async () => {
    const h = harness()
    const port = await h.start()
    expect(h.host.view()).toEqual({ enabled: true, connectedDevices: [], pairedDevices: [], pairingRequests: [], error: null })

    const phone = track(new TestPhone(port))
    await phone.join()
    await phone.next('challenge')
    await phone.next('pending')
    await until(() => h.host.view().pairingRequests.length === 1)
    const changesBefore = h.changes
    const [request] = h.host.view().pairingRequests
    expect(request).toMatchObject({ deviceName: 'Test iPhone', platform: 'iphone', model: 'iPhone 16' })
    // Nothing sealed reaches a phone that is not allowed yet.
    await sleep(50)
    expect(phone.count('welcome')).toBe(0)

    h.host.respond(request.id, true)
    const welcome = await phone.next('welcome')
    expect(welcome.welcome).toMatchObject({ hostName: 'Test PC', go2rtcPort: 1984, username: 'waitingpaws', password: 'lan-password-1' })
    expect(Array.isArray(welcome.welcome.addresses)).toBe(true)
    // Who this computer is: its stable id (kept with the devices), a PC, its model.
    const hostID = h.host.identity.id
    expect(hostID).toMatch(/^[0-9A-F-]{36}$/)
    expect(welcome.welcome).toMatchObject({ hostID, platform: 'windows', model: 'Dell XPS 15 9510' })
    const state = await phone.next('state')
    expect(state.state).toEqual(syncState(baseState()))
    expect(h.changes).toBeGreaterThan(changesBefore)

    // Both sides keep the same new secret; the host's is in the file, with what the hello said about the phone.
    expect(phone.secret).toMatch(/^[A-Za-z0-9+/]{43}=$/)
    const stored = new PairedDeviceStore({ file: join(directory, 'sync-devices.json') })
    expect(stored.find('PHONE-1')).toMatchObject({ secret: phone.secret, platform: 'iphone', model: 'iPhone 16' })
    expect(stored.hostID).toBe(hostID)
    const view = h.host.view()
    expect(view).toEqual({
      enabled: true,
      connectedDevices: ['Test iPhone'],
      pairedDevices: [{ id: 'PHONE-1', name: 'Test iPhone', platform: 'iphone', model: 'iPhone 16', lastSeen: expect.any(Number), connected: true }],
      pairingRequests: [],
      error: null,
    })
    expect(Math.abs(view.pairedDevices[0].lastSeen! - Date.now())).toBeLessThan(5000)

    // Commands from the phone reach the backend in its terms.
    phone.send({ kind: 'command', command: { kind: 'session', command: 'endExit' } })
    phone.send({ kind: 'command', command: { kind: 'startSession', plan } })
    phone.send({ kind: 'command', command: { kind: 'setPendingPlan', plan: null } })
    phone.send({ kind: 'command', command: { kind: 'startRecording' } })
    await until(() => h.commands.length === 4)
    expect(h.commands[0]).toEqual({ kind: 'session', command: 'endExit' })
    expect(h.commands[1].kind).toBe('startSession')
    expect((h.commands[1] as { plan: TrainingPlan }).plan.exits.map((exit) => exit.duration)).toEqual([5, 30])
    expect(h.commands[2]).toEqual({ kind: 'setPendingPlan', plan: null })
    expect(h.commands[3]).toEqual({ kind: 'startRecording' })
  })

  it('sends the state only when it changed, at most every interval, the last change always', async () => {
    const h = harness()
    const port = await h.start()
    const phone = track(await pair(h, port))
    await sleep(60)
    phone.inbox.length = 0

    // Unchanged: nothing goes out.
    h.host.broadcast()
    await sleep(100)
    expect(phone.count('state')).toBe(0)

    // A session starts on the computer.
    const session = new TrainingSession(plan)
    h.state = { ...baseState(), session: session.snapshot, recordingSince: 1_790_000_000_000 }
    h.host.broadcast()
    const started = await phone.next('state')
    expect(started.state.session?.plan.title).toBe('Тренировка')
    expect(started.state.recordingSince).toBe(1_790_000_000_000)

    // A burst of changes: the first right away, the last after the interval, nothing in between.
    await sleep(60)
    for (let revision = 2; revision <= 10; revision++) {
      h.state = { ...h.state, streamRevision: revision }
      h.host.broadcast()
    }
    await sleep(150)
    const revisions = phone.inbox.filter((message) => message.kind === 'state').map((message) => (message.kind === 'state' ? message.state.streamRevision : null))
    expect(revisions.length).toBeLessThanOrEqual(2)
    expect(revisions[revisions.length - 1]).toBe(10)
  })

  it('lets a paired iPhone back in without asking, also after a restart', async () => {
    const first = harness()
    const port = await first.start()
    const phone = track(await pair(first, port))
    const secret = phone.secret
    const hostID = first.host.identity.id
    phone.close()
    first.host.stop()

    // A new host on the same file: the pairing and the host id survived the "restart".
    const second = harness()
    const port2 = await second.start()
    expect(second.host.view().pairedDevices).toEqual([
      { id: 'PHONE-1', name: 'Test iPhone', platform: 'iphone', model: 'iPhone 16', lastSeen: expect.any(Number), connected: false },
    ])
    const again = track(new TestPhone(port2, 'PHONE-1', 'Test iPhone', secret))
    await again.join()
    const welcome = await again.next('welcome')
    expect(welcome.welcome.password).toBe('lan-password-1')
    expect(welcome.welcome.hostID).toBe(hostID)
    await again.next('state')
    expect(again.count('pending')).toBe(0)
    expect(second.host.view().pairingRequests).toEqual([])
    expect(second.host.view().connectedDevices).toEqual(['Test iPhone'])
    // The secret stays the same.
    expect(again.secret).toBe(secret)
  })

  it('asks again when the proof is wrong, and declining closes the connection', async () => {
    const h = harness()
    const port = await h.start()
    const phone = track(await pair(h, port))
    phone.close()

    const impostor = track(new TestPhone(port, 'PHONE-1', 'Test iPhone', 'not-the-secret'))
    await impostor.join()
    await impostor.next('pending')
    await until(() => h.host.view().pairingRequests.length === 1)
    h.host.respond(h.host.view().pairingRequests[0].id, false)
    const rejected = await impostor.next('rejected')
    expect(rejected.reason).toBe('На компьютере подключение отклонили')
    await until(() => impostor.closed)
    expect(impostor.count('welcome')).toBe(0)
    expect(h.host.view().pairingRequests).toEqual([])
    // The real pairing is untouched.
    expect(h.host.view().pairedDevices.map(({ id, name }) => ({ id, name }))).toEqual([{ id: 'PHONE-1', name: 'Test iPhone' }])
  })

  it('forgets a device: disconnects it, tells the backend, its secret stops working', async () => {
    const h = harness()
    const port = await h.start()
    const phone = track(await pair(h, port))
    const secret = phone.secret
    h.host.forget('PHONE-1')
    await until(() => phone.closed)
    expect(h.forgotten).toBe(1)
    expect(h.host.view().pairedDevices).toEqual([])
    expect(h.host.view().connectedDevices).toEqual([])

    const again = track(new TestPhone(port, 'PHONE-1', 'Test iPhone', secret))
    await again.join()
    await again.next('pending')
    await until(() => h.host.view().pairingRequests.length === 1)
  })

  it('sends the new go2rtc password to connected iPhones', async () => {
    const h = harness()
    const port = await h.start()
    const phone = track(await pair(h, port))
    h.password = 'lan-password-2'
    h.host.refreshAccess()
    const welcome = await phone.next('welcome')
    expect(welcome.welcome.password).toBe('lan-password-2')
  })

  it('sends the PC model once it is known, and remembers it for the next start', async () => {
    let resolveModel: (model: string) => void = () => undefined
    const h = harness(undefined, new Promise<string>((resolve) => (resolveModel = resolve)))
    const port = await h.start()
    const phone = new TestPhone(port)
    track(phone)
    await phone.join()
    await phone.next('pending')
    await until(() => h.host.view().pairingRequests.length === 1)
    h.host.respond(h.host.view().pairingRequests[0].id, true)
    const first = await phone.next('welcome')
    // Not known yet: the field is left out (the iPhone shows «ПК»).
    expect(first.welcome.model).toBeNull()
    expect(first.welcome.platform).toBe('windows')

    resolveModel('HP EliteBook 840 G8 Notebook PC')
    const second = await phone.next('welcome')
    expect(second.welcome.model).toBe('HP EliteBook 840 G8 Notebook PC')
    expect(second.welcome.hostID).toBe(first.welcome.hostID)
    expect(new PairedDeviceStore({ file: join(directory, 'sync-devices.json') }).hostModel).toBe('HP EliteBook 840 G8 Notebook PC')
  })

  it('closes connections that skip the key exchange or send garbage, and keeps working', async () => {
    const h = harness()
    const port = await h.start()

    // A command in the clear before any key exchange.
    const sneaky = track(new TestPhone(port, 'PHONE-X', 'Sneaky'))
    await sneaky.join()
    await sneaky.next('challenge')
    sneaky.sendRaw(SyncMessage.encode({ kind: 'command', command: { kind: 'stopRecording' } }))
    await until(() => sneaky.closed)

    // Not JSON at all.
    const garbage = track(new TestPhone(port, 'PHONE-Y', 'Garbage'))
    await garbage.join()
    garbage.sendRaw('{not json')
    await until(() => garbage.closed)

    // Not even HTTP.
    await new Promise<void>((resolve) => {
      const socket = connectTCP(port, '127.0.0.1', () => socket.write(Buffer.from([0xff, 0x00, 0x13, 0x37, 0x0d, 0x0a, 0x0d, 0x0a])))
      socket.on('error', () => resolve())
      socket.on('close', () => resolve())
    })

    expect(h.commands).toEqual([])
    // A real iPhone still gets in.
    const phone = track(await pair(h, port))
    phone.send({ kind: 'command', command: { kind: 'abandonSession' } })
    await until(() => h.commands.length === 1)
    expect(h.commands).toEqual([{ kind: 'abandonSession' }])
  })

  it('rejects an iPhone with another protocol version', async () => {
    const h = harness()
    const port = await h.start()
    const phone = track(new TestPhone(port))
    await phone.ready()
    phone.send({ kind: 'hello', hello: SyncHello.make({ deviceID: 'OLD', deviceName: 'Old iPhone', publicKey: SyncCrypto.newKey().publicKey, protocolVersion: 1 }) })
    const rejected = await phone.next('rejected')
    expect(rejected.reason).toBe('Обновите Waiting Paws на iPhone и на компьютере')
  })

  it('stop closes the connections and the listener', async () => {
    const h = harness()
    const port = await h.start()
    const phone = track(await pair(h, port))
    h.host.stop()
    await until(() => phone.closed)
    expect(h.host.view().enabled).toBe(false)
    expect(h.host.port).toBeNull()
    await new Promise<void>((resolve, reject) => {
      const socket = connectTCP(port, '127.0.0.1')
      socket.on('connect', () => reject(new Error('still listening')))
      socket.on('error', () => resolve())
    })
  })

  it('speaks WebSocket framing: fragments, pings and masks (as NWProtocolWebSocket may send them)', async () => {
    const h = harness()
    const port = await h.start()
    const socket = await new Promise<Socket>((resolve) => {
      const value = connectTCP(port, '127.0.0.1', () => resolve(value))
    })
    try {
      let received: Buffer = Buffer.alloc(0)
      socket.on('data', (chunk: Buffer) => (received = Buffer.concat([received, chunk])))
      const key = Buffer.from('waitingpaws-key!').toString('base64')
      socket.write(`GET / HTTP/1.1\r\nHost: test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`)
      await until(() => received.includes('\r\n\r\n'))
      const head = received.subarray(0, received.indexOf('\r\n\r\n')).toString()
      expect(head).toMatch(/^HTTP\/1\.1 101/)
      expect(head).toContain(`Sec-WebSocket-Accept: ${webSocketAccept(key)}`)
      received = received.subarray(received.indexOf('\r\n\r\n') + 4)

      const hello = Buffer.from(
        SyncMessage.encode({ kind: 'hello', hello: SyncHello.make({ deviceID: 'RAW', deviceName: 'Raw', publicKey: SyncCrypto.newKey().publicKey }) }),
      )
      const half = Math.floor(hello.length / 2)
      socket.write(clientFrame(0x1, hello.subarray(0, half), false))
      socket.write(clientFrame(0x9, Buffer.from('ping!'), true))
      socket.write(clientFrame(0x0, hello.subarray(half), true))
      const frames: { opcode: number; payload: Buffer }[] = []
      await until(() => {
        frames.push(...readServerFrames(received, (rest) => (received = rest)))
        return frames.some((frame) => frame.opcode === 0x1)
      })
      expect(frames.find((frame) => frame.opcode === 0xa)?.payload.toString()).toBe('ping!')
      const challenge = SyncMessage.decode(frames.find((frame) => frame.opcode === 0x1)!.payload.toString())
      expect(challenge.kind).toBe('challenge')

      // A close frame is answered with a close frame.
      socket.write(clientFrame(0x8, Buffer.from([0x03, 0xe8]), true))
      await until(() => {
        frames.push(...readServerFrames(received, (rest) => (received = rest)))
        return frames.some((frame) => frame.opcode === 0x8)
      })
    } finally {
      socket.destroy()
    }
  })

  it('keeps secrets encrypted at rest when a box is given', async () => {
    const box: SecretBox = {
      encrypt: (text) => 'test:' + Buffer.from(text).reverse().toString('hex'),
      decrypt: (stored) => (stored.startsWith('test:') ? Buffer.from(stored.slice(5), 'hex').reverse().toString() : null),
    }
    const h = harness(box)
    const port = await h.start()
    const phone = track(await pair(h, port))
    const file = readFileSync(join(directory, 'sync-devices.json'), 'utf8')
    expect(file).not.toContain(phone.secret!)
    expect(file).toContain('"secret": "test:')
    expect(new PairedDeviceStore({ file: join(directory, 'sync-devices.json'), box }).find('PHONE-1')?.secret).toBe(phone.secret)

    // Read without the key: the device stays listed (to forget it) but can't prove itself; the file keeps the value.
    const locked = new PairedDeviceStore({ file: join(directory, 'sync-devices.json') })
    expect(locked.find('PHONE-1')).toMatchObject({ name: 'Test iPhone', secret: null })
    locked.save({ deviceID: 'PHONE-2', name: 'Other', secret: 'abc' })
    expect(readFileSync(join(directory, 'sync-devices.json'), 'utf8')).toContain('"secret": "test:')
  })
})

describe('SyncHost helpers', () => {
  it('maps the state and the TXT record like the Mac', () => {
    const session = new TrainingSession(plan, { clock: () => 1_000 })
    expect(SyncHostInfo.txt(syncHostInfo('PC', syncState(baseState())))).toEqual({ v: '2', cam: 'Прихожая', ready: '1', session: '0', os: 'windows' })
    const running = syncState({ ...baseState(), session: session.snapshot })
    expect(SyncHostInfo.txt(syncHostInfo('PC', running))).toEqual({ v: '2', cam: 'Прихожая', ready: '1', session: '1', exit: '1', os: 'windows' })
    session.startExit()
    session.markBehindDoor()
    session.endExit()
    const onBreak = syncState({ ...baseState(), session: session.snapshot })
    expect(syncHostInfo('PC', onBreak).currentExit).toBe(2)

    // With the identity: id, os=windows, model; read back by the iPhone as a PC.
    const identity = { id: 'A1B2', platform: 'windows', model: 'Dell XPS 15 9510' }
    const txt = SyncHostInfo.txt(syncHostInfo('DESKTOP-7Q', syncState(baseState()), identity))
    expect(txt).toEqual({ v: '2', cam: 'Прихожая', ready: '1', session: '0', id: 'A1B2', os: 'windows', model: 'Dell XPS 15 9510' })
    expect(SyncHostInfo.device(SyncHostInfo.fromTXT('DESKTOP-7Q', txt))).toEqual({ id: 'A1B2', name: 'DESKTOP-7Q', kind: 'windows', model: 'Dell XPS 15 9510' })
    // An unknown model is left out of the TXT record.
    expect(SyncHostInfo.txt(syncHostInfo('PC', null, { ...identity, model: '' }))).not.toHaveProperty('model')
  })

  it('names the PC model from the BIOS values, nothing for a self-built PC', () => {
    const output = [
      'HKEY_LOCAL_MACHINE\\HARDWARE\\DESCRIPTION\\System\\BIOS',
      '    BiosMajorRelease    REG_DWORD    0x5',
      '    BaseBoardProduct    REG_SZ    X670E GAMING PLUS WIFI (MS-7E16)',
      '    SystemFamily    REG_SZ    To be filled by O.E.M.',
      '    SystemManufacturer    REG_SZ    Micro-Star International Co., Ltd.',
      '    SystemProductName    REG_SZ    MS-7E16',
      '    SystemVersion    REG_SZ    1.0',
      '',
    ].join('\r\n')
    const parsed = parseRegQuery(output)
    expect(parsed).toMatchObject({ SystemManufacturer: 'Micro-Star International Co., Ltd.', SystemProductName: 'MS-7E16' })
    expect(pcModelName(parsed)).toBe('')

    expect(pcModelName({ SystemManufacturer: 'Dell Inc.', SystemProductName: 'XPS 15 9510' })).toBe('Dell XPS 15 9510')
    expect(pcModelName({ SystemManufacturer: 'HP', SystemProductName: 'HP EliteBook 840 G8 Notebook PC' })).toBe('HP EliteBook 840 G8 Notebook PC')
    expect(pcModelName({ SystemManufacturer: 'LENOVO', SystemProductName: '20XW0026GE', SystemVersion: 'ThinkPad X1 Carbon Gen 9' })).toBe('ThinkPad X1 Carbon Gen 9')
    expect(pcModelName({ SystemManufacturer: 'LENOVO', SystemProductName: '82JW', SystemVersion: 'Legion 5 15ACH6H' })).toBe('Legion 5 15ACH6H')
    expect(pcModelName({ SystemManufacturer: 'Microsoft Corporation', SystemProductName: 'Surface Laptop 4' })).toBe('Surface Laptop 4')
    expect(pcModelName({ SystemManufacturer: 'ASUSTeK COMPUTER INC.', SystemProductName: 'ROG Zephyrus G14 GA401QM' })).toBe('ASUS ROG Zephyrus G14 GA401QM')
    expect(pcModelName({ SystemManufacturer: 'Apple Inc.', SystemProductName: 'MacBookPro16,1' })).toBe('MacBook Pro')
    expect(pcModelName({ SystemManufacturer: 'System manufacturer', SystemProductName: 'System Product Name' })).toBe('')
    expect(pcModelName({ SystemManufacturer: 'To Be Filled By O.E.M.', SystemProductName: 'To Be Filled By O.E.M.' })).toBe('')
    expect(pcModelName({})).toBe('')
  })

  it('lists the address the iPhone came to first', () => {
    const interfaces = [
      { name: 'Wi-Fi', address: '192.168.1.5', netmask: '255.255.255.0' },
      { name: 'vEthernet (WSL)', address: '172.20.0.1', netmask: '255.255.240.0' },
      { name: 'Ethernet 2', address: '169.254.10.1', netmask: '255.255.0.0' },
    ]
    expect(welcomeAddresses('172.20.0.1', interfaces)).toEqual(['172.20.0.1', '192.168.1.5'])
    expect(welcomeAddresses(null, interfaces)).toEqual(['192.168.1.5', '172.20.0.1'])
    expect(onSubnet('192.168.1.77', interfaces[0])).toBe(true)
    expect(onSubnet('192.168.2.77', interfaces[0])).toBe(false)
  })
})

describe('Bonjour responder', () => {
  const names = serviceNames('Andrew’s PC. Home', '_waitingpaws._tcp', 'WaitingPaws-ANDREW-PC')
  const records = serviceRecords(names, 11986, { v: '2', cam: 'Прихожая', ready: '1', session: '0' }, '192.168.1.5')
  const query = (questions: { name: string[]; type: number }[], answers: ResourceRecord[] = []) =>
    decodeMessage(encodeMessage({ flags: 0, questions: questions.map((question) => ({ ...question, unicastResponse: true })), answers }))

  it('answers a browse (PTR) with SRV, TXT and the address of the adapter', () => {
    const reply = answerQuery(query([{ name: ['_WaitingPaws', '_tcp', 'local'], type: RecordType.PTR }]), names, records)!
    // Through the wire format and back.
    const packet = decodeMessage(encodeMessage({ flags: 0x8400, answers: reply.answers, additionals: reply.additionals }))
    expect(packet.flags).toBe(0x8400)
    expect(packet.answers).toHaveLength(1)
    expect(packet.answers[0]).toMatchObject({ name: ['_waitingpaws', '_tcp', 'local'], ttl: 4500, cacheFlush: false })
    expect(packet.answers[0].data).toEqual({ type: 'PTR', target: ['Andrew’s PC. Home', '_waitingpaws', '_tcp', 'local'] })
    const byType = Object.fromEntries(packet.additionals.map((record) => [record.data.type + (record.data.type === 'NSEC' ? record.name[0] : ''), record]))
    expect(byType.SRV.data).toEqual({ type: 'SRV', priority: 0, weight: 0, port: 11986, target: ['WaitingPaws-ANDREW-PC', 'local'] })
    expect(byType.SRV.cacheFlush).toBe(true)
    expect(byType.A.data).toEqual({ type: 'A', address: '192.168.1.5' })
    const txt = byType.TXT.data.type === 'TXT' ? byType.TXT.data.strings.map((item) => item.toString('utf8')) : []
    expect(txt.sort()).toEqual(['cam=Прихожая', 'ready=1', 'session=0', 'v=2'])
    expect(byType['NSECWaitingPaws-ANDREW-PC'].data).toEqual({ type: 'NSEC', next: ['WaitingPaws-ANDREW-PC', 'local'], types: [RecordType.A] })
  })

  it('stays quiet for other services and for a PTR the querier already knows', () => {
    expect(answerQuery(query([{ name: ['_airplay', '_tcp', 'local'], type: RecordType.PTR }]), names, records)).toBeNull()
    const knownPTR = { ...records.ptr, ttl: 4000 }
    expect(answerQuery(query([{ name: names.service, type: RecordType.PTR }], [knownPTR]), names, records)).toBeNull()
  })

  it('answers SRV, TXT, A and says there is no AAAA', () => {
    const reply = answerQuery(
      query([
        { name: names.instance, type: RecordType.SRV },
        { name: names.instance, type: RecordType.TXT },
        { name: names.host, type: RecordType.AAAA },
      ]),
      names,
      records,
    )!
    expect(reply.answers.map((record) => record.data.type)).toEqual(['SRV', 'TXT'])
    expect(reply.additionals.map((record) => record.data.type)).toEqual(['A', 'NSEC'])
  })

  it('reads compressed names', () => {
    // "local" at 12, then "_tcp" + pointer to it.
    const buffer = Buffer.from([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 108, 111, 99, 97, 108, 0, 4, 95, 116, 99, 112, 0xc0, 12])
    expect(readName(buffer, 19)).toEqual([['_tcp', 'local'], 26])
    expect(() => readName(Buffer.from([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xc0, 12]), 12)).toThrow()
  })
})

// MARK: - Raw WebSocket frames

function clientFrame(opcode: number, payload: Buffer, fin: boolean): Buffer {
  const mask = Buffer.from([0x12, 0x34, 0x56, 0x78])
  const masked = Buffer.from(payload.map((byte, index) => byte ^ mask[index & 3]))
  const header = payload.length < 126 ? Buffer.from([(fin ? 0x80 : 0) | opcode, 0x80 | payload.length]) : Buffer.from([(fin ? 0x80 : 0) | opcode, 0x80 | 126, payload.length >> 8, payload.length & 0xff])
  return Buffer.concat([header, mask, masked])
}

function readServerFrames(buffer: Buffer, rest: (remaining: Buffer) => void): { opcode: number; payload: Buffer }[] {
  const frames: { opcode: number; payload: Buffer }[] = []
  let offset = 0
  for (;;) {
    if (buffer.length - offset < 2) break
    let length = buffer[offset + 1] & 0x7f
    let start = offset + 2
    if (length === 126) {
      if (buffer.length - offset < 4) break
      length = buffer.readUInt16BE(offset + 2)
      start = offset + 4
    }
    if (buffer.length < start + length) break
    frames.push({ opcode: buffer[offset] & 0x0f, payload: buffer.subarray(start, start + length) })
    offset = start + length
  }
  rest(buffer.subarray(offset))
  return frames
}
