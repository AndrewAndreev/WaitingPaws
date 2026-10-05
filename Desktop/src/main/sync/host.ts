import { randomUUID } from 'node:crypto'
import { type IncomingMessage, type Server, createServer } from 'node:http'
import type { Socket } from 'node:net'
import { hostname } from 'node:os'
import type { Duplex } from 'node:stream'
import type { TrainingPlan } from '@core/models'
import type { TrainingRecord } from '@core/sessionLog'
import type { TrainingSessionSnapshot } from '@core/trainingSession'
import { tr } from '@core/localization'
import { type SyncCommand, SyncHello, SyncHostInfo, SyncMessage, SyncProtocol, type SyncState, type SyncWelcome } from '@core/syncProtocol'
import { SyncDevice } from '@core/syncDevice'
import { SyncCrypto, type SyncHandshake } from '@core/node/syncCrypto'
import { write as appLog } from '../log'
import { BonjourAdvertiser, truncateLabel } from './bonjour'
import { SyncChannel } from './channel'
import { PairedDeviceStore, defaultDeviceStore } from './deviceStore'
import { hostPlatform, readPCModel } from './identity'
import { welcomeAddresses } from './network'
import { acceptWebSocket } from './websocket'

/// Lets an iPhone on the same network find this computer, watch its camera and drive its training (the Mac app's
/// `SyncHost`, same protocol, so the iPhone app takes this computer for a Mac):
/// - Bonjour `_waitingpaws._tcp` named after the computer, with the TXT record of `SyncHostInfo` (bonjour.ts);
/// - a WebSocket listener (one JSON `SyncMessage` per text frame, websocket.ts / channel.ts);
/// - hello → challenge → proof; a known iPhone with a valid proof joins right away, a new one waits for «Разрешить»
///   here (`view().pairingRequests`, answered with `respond`), and both sides derive the new pairing secret;
/// - after that everything is sealed (`SyncCipher`): `welcome` with the go2rtc access, states, commands;
/// - paired iPhones are kept in `sync-devices.json` (deviceStore.ts), bound to their ids, with kind, model and when
///   they were last seen;
/// - this computer tells who it is (TXT `id`/`os`/`model`, sealed in `welcome`): a stable host id kept in the same
///   file, kind "windows" and the PC model when the BIOS has a real one (identity.ts).
/// On Windows the first listen on the network makes the firewall ask whether Waiting Paws may accept connections
/// (private networks are enough).

export interface SyncHostState {
  session: TrainingSessionSnapshot | null
  recordingSince: number | null
  cameraReady: boolean
  cameraTitle: string
  streamName: string
  lastRecord: TrainingRecord | null
  pendingPlan: TrainingPlan | null
  cameraSource: string | null
  streamRevision: number
}

/// A command from a linked iPhone, in the backend's terms.
export type SyncHostCommand =
  | { kind: 'session'; command: 'startExit' | 'markBehindDoor' | 'endExit' | 'resetExit' | 'finish' }
  | { kind: 'startSession'; plan: TrainingPlan }
  | { kind: 'setPendingPlan'; plan: TrainingPlan | null }
  | { kind: 'abandonSession' }
  | { kind: 'startRecording' }
  | { kind: 'stopRecording' }

export interface SyncHostDependencies {
  state: () => SyncHostState
  command: (command: SyncHostCommand) => void
  /// Port and Basic-auth credentials of go2rtc for the iPhone (sent encrypted in `welcome`).
  access: () => { port: number; username: string; password: string }
  /// A paired iPhone was forgotten: the backend changes the LAN password.
  onDeviceForgotten: () => void
  /// Devices, pairing requests or errors changed: the UI state must be sent again.
  onChange: () => void
}

export interface SyncHostView {
  enabled: boolean
  /// Names of the iPhones connected right now (one per device), sorted.
  connectedDevices: string[]
  pairedDevices: {
    id: string
    name: string
    /// From the device's last hello: `SyncPlatform` raw value ("iphone", "ipad"); missing for pairings made before.
    platform?: string
    /// "iPhone 16"; missing when unknown (show `SyncDevice.modelTitle`, i.e. the kind).
    model?: string
    /// When it last joined, epoch ms.
    lastSeen?: number
    /// Connected right now.
    connected?: boolean
  }[]
  pairingRequests: { id: string; deviceName: string; platform?: string; model?: string }[]
  error: string | null
}

export interface SyncHostOptions {
  /// Bonjour instance name and `welcome.hostName` (the Mac's computer name). Default: `os.hostname()`. The iPhone
  /// remembers the pairing under this name, so it should stay the same.
  name?: string
  /// Address to listen on. Default: all interfaces (the iPhone comes over Wi-Fi); tests use '127.0.0.1'.
  listenAddress?: string
  /// TCP port tried first, then any free one when it's taken; 0: any free port. Default 11986.
  port?: number
  /// Advertise over Bonjour (Multicast DNS). Default true; off in tests.
  bonjour?: boolean
  /// Paired devices. Default: `sync-devices.json` in Electron's userData, secrets through safeStorage.
  devices?: PairedDeviceStore
  /// Allow every iPhone without asking (the Mac's debug `--sync-auto-accept`; automated checks only).
  autoAccept?: boolean
  /// Minimum time between two state messages, ms (default 250; the last change always goes out).
  stateInterval?: number
  /// How long a connection may take to finish the key exchange, ms (default 20 s; a pending approval waits).
  handshakeTimeout?: number
  /// This computer's id for the link. Default: made once and kept in the device store.
  hostID?: string
  /// This PC's model ("Dell XPS 15 9510", "" when unknown). Default: read from the BIOS registry values in the
  /// background (the last one found is used until then).
  model?: string | Promise<string>
  log?: (line: string) => void
}

export const defaultSyncPort = 11986

/// Pairing requests shown at once; more are turned away until these are answered.
const maxPairingRequests = 4
/// A device that stopped reading (suspended app on a half-dead connection) is dropped past this much unsent data.
const maxBufferedBytes = 4 * 1024 * 1024

interface Client {
  id: string
  channel: SyncChannel
  hello: SyncHello | null
  handshake: SyncHandshake | null
  approved: boolean
  /// Set when the iPhone proved an earlier pairing; null for a new one (its secret comes on approval).
  pairingSecret: string | null
  /// The last state sent (encoded), so only changes go out.
  lastState: string | null
  deadline: NodeJS.Timeout | null
}

interface PairingRequest {
  id: string
  hello: SyncHello
}

export class SyncHost {
  /// The name the iPhone sees (Bonjour instance, `welcome.hostName`).
  readonly name: string

  private wanted = false
  private server: Server | null = null
  private listeningPort: number | null = null
  private generation = 0
  private retryTimer: NodeJS.Timeout | null = null
  private advertiser: BonjourAdvertiser | null = null
  private store: PairedDeviceStore | null
  private storeLoading = false
  private clients = new Map<string, Client>()
  private requests: PairingRequest[] = []
  private listenError: string | null = null
  private bonjourError: string | null = null
  private broadcastTimer: NodeJS.Timeout | null = null
  private broadcastPending = false
  /// This PC's model as last known ("" when unknown).
  private model = ''
  private modelRequested = false
  private readonly log: (line: string) => void

  constructor(
    private readonly deps: SyncHostDependencies,
    private readonly options: SyncHostOptions = {},
  ) {
    this.name = truncateLabel(options.name ?? computerName())
    this.log = options.log ?? appLog
    this.store = options.devices ?? null
    if (typeof options.model === 'string') this.model = options.model
  }

  /// The TCP port while listening.
  get port(): number | null {
    return this.listeningPort
  }

  /// This computer as the iPhones see it (TXT `id`/`os`/`model`, `welcome.hostID`/`platform`/`model`).
  get identity(): { id: string; platform: string; model: string } {
    return { id: this.options.hostID ?? this.store?.hostID ?? '', platform: hostPlatform, model: this.model }
  }

  // MARK: - Lifecycle

  start(): void {
    if (this.wanted) return
    this.wanted = true
    this.deps.onChange()
    if (this.store) this.storeReady()
    else this.loadStore()
  }

  private storeReady(): void {
    if (typeof this.options.model !== 'string' && this.store?.hostModel) this.model = this.store.hostModel
    this.listen()
    this.refreshModel()
  }

  /// Reads the PC model once (off the main thread); a new one goes into the TXT record and to connected iPhones.
  private refreshModel(): void {
    if (this.modelRequested || typeof this.options.model === 'string') return
    this.modelRequested = true
    Promise.resolve(this.options.model ?? readPCModel())
      .catch(() => '')
      .then((model) => {
        if (this.store) this.store.hostModel = model
        if (model === this.model) return
        this.model = model
        this.log(`[sync] this PC: ${model || 'model unknown'}`)
        const state = this.currentState()
        if (state) this.advertiser?.updateTXT(SyncHostInfo.txt(this.hostInfo(state)))
        this.refreshAccess()
      })
  }

  /// Closes every connection and the listener, says goodbye over Bonjour.
  stop(): void {
    this.wanted = false
    this.generation += 1
    if (this.retryTimer) clearTimeout(this.retryTimer)
    if (this.broadcastTimer) clearTimeout(this.broadcastTimer)
    this.retryTimer = this.broadcastTimer = null
    this.broadcastPending = false
    for (const id of [...this.clients.keys()]) this.drop(id, false)
    this.requests = []
    const server = this.server
    this.server = null
    this.listeningPort = null
    if (server) {
      server.close()
      server.closeAllConnections()
    }
    this.advertiser?.stop()
    this.advertiser = null
    this.listenError = null
    this.bonjourError = null
    this.deps.onChange()
  }

  private loadStore(): void {
    if (this.storeLoading) return
    this.storeLoading = true
    defaultDeviceStore(this.log)
      .catch((error: unknown) => {
        this.log(`[sync] paired devices unavailable: ${(error as Error).message}`)
        return new PairedDeviceStore({ file: null, log: this.log })
      })
      .then((store) => {
        this.store = store
        this.storeLoading = false
        this.deps.onChange()
        if (this.wanted) this.storeReady()
      })
  }

  private listen(port = this.options.port ?? defaultSyncPort): void {
    if (!this.wanted || this.server) return
    const generation = ++this.generation
    let listening = false
    const server = createServer((_request, response) => {
      response.writeHead(426, { 'Content-Type': 'text/plain', Connection: 'close' })
      response.end('Waiting Paws: WebSocket only\n')
    })
    server.headersTimeout = 10_000
    server.requestTimeout = 15_000
    server.maxConnections = 32
    server.on('upgrade', (request: IncomingMessage, socket: Duplex, head: Buffer) => {
      try {
        this.accept(request, socket, head)
      } catch (error) {
        this.log(`[sync] accepting a connection failed: ${(error as Error).message}`)
        socket.destroy()
      }
    })
    server.on('clientError', (_error, socket) => socket.destroy())
    server.on('error', (error: NodeJS.ErrnoException) => {
      if (generation !== this.generation) return
      server.close()
      this.server = null
      this.listeningPort = null
      this.advertiser?.stop()
      this.advertiser = null
      if (!listening && port !== 0 && (error.code === 'EADDRINUSE' || error.code === 'EACCES')) {
        this.log(`[sync] port ${port} is taken (${error.code}): using any free port`)
        this.listen(0)
        return
      }
      this.log(`[sync] cannot listen: ${error.message}`)
      this.listenError = tr(`Не удалось открыть порт для iPhone: ${error.message}`, `Can't open a port for the iPhone: ${error.message}`)
      this.deps.onChange()
      this.retryTimer = setTimeout(() => {
        this.retryTimer = null
        this.listen()
      }, 3000)
    })
    server.listen({ port, host: this.options.listenAddress }, () => {
      listening = true
      if (generation !== this.generation) return
      const address = server.address()
      this.listeningPort = typeof address === 'object' && address ? address.port : port
      this.listenError = null
      this.log(`[sync] listening on ${this.options.listenAddress ?? 'all interfaces'} port ${this.listeningPort}`)
      this.advertise(this.listeningPort)
      this.deps.onChange()
    })
    this.server = server
  }

  private advertise(port: number): void {
    if (this.options.bonjour === false) return
    const advertiser = new BonjourAdvertiser({
      instance: this.name,
      serviceType: SyncProtocol.serviceType,
      port,
      txt: SyncHostInfo.txt(this.hostInfo(this.currentState())),
      log: this.log,
      onError: (message) => {
        const text = message === null ? null : tr(`Bonjour не работает: ${message}`, `Bonjour is not working: ${message}`)
        if (text === this.bonjourError) return
        this.bonjourError = text
        this.deps.onChange()
      },
    })
    this.advertiser = advertiser
    advertiser.start()
  }

  // MARK: - Pairing

  respond(requestId: string, allow: boolean): void {
    const request = this.requests.find((item) => item.id === requestId)
    if (!request) return
    this.requests = this.requests.filter((item) => item !== request)
    if (allow) {
      this.approve(request.id)
    } else {
      this.log(`[sync] ${request.hello.deviceName} was declined`)
      this.clients.get(request.id)?.channel.send({
        kind: 'rejected',
        reason: tr('На компьютере подключение отклонили', 'The connection was declined on the computer'),
      })
      setTimeout(() => this.drop(request.id), 300)
    }
    this.deps.onChange()
  }

  forget(deviceId: string): void {
    this.store?.remove(deviceId)
    for (const client of [...this.clients.values()]) if (client.hello?.deviceID === deviceId) this.drop(client.id)
    this.log(`[sync] forgot device ${deviceId}`)
    this.deps.onDeviceForgotten()
    this.deps.onChange()
  }

  /// Sends the current go2rtc access again to every connected iPhone (after the password changed).
  refreshAccess(): void {
    for (const client of this.clients.values()) if (client.approved) client.channel.send({ kind: 'welcome', welcome: this.welcome(client) })
  }

  view(): SyncHostView {
    // One entry per device (by id), sorted by name as Finder sorts ("iPhone 9" before "iPhone 10").
    const connected = new Map<string, string>()
    for (const client of this.clients.values()) {
      if (client.approved && client.hello && !connected.has(client.hello.deviceID)) connected.set(client.hello.deviceID, client.hello.deviceName)
    }
    return {
      enabled: this.wanted,
      connectedDevices: [...connected.values()].sort((a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' })),
      pairedDevices: (this.store?.devices ?? []).map((device) => ({
        id: device.deviceID,
        name: device.name,
        ...(device.platform !== null ? { platform: device.platform } : {}),
        ...(device.model ? { model: device.model } : {}),
        ...(device.lastSeen !== null ? { lastSeen: device.lastSeen } : {}),
        connected: connected.has(device.deviceID),
      })),
      pairingRequests: this.requests.map(({ id, hello }) => {
        const device = SyncHello.device(hello)
        return {
          id,
          deviceName: hello.deviceName,
          platform: device.kind ?? hello.platform ?? undefined,
          ...(device.model ? { model: device.model } : {}),
        }
      }),
      error: this.listenError ?? this.bonjourError,
    }
  }

  // MARK: - Connections

  private accept(request: IncomingMessage, socket: Duplex, head: Buffer): void {
    if (!this.wanted) {
      socket.destroy()
      return
    }
    const connection = acceptWebSocket(request, socket)
    if (!connection) return
    const tcp = socket as Socket
    try {
      tcp.setNoDelay(true)
      // An iPhone that left the network is noticed in ~20 s (Windows sends 10 probes a second apart).
      tcp.setKeepAlive(true, 10_000)
    } catch {
      // Not a TCP socket (tests may pass anything).
    }
    const id = randomUUID()
    const channel = new SyncChannel(connection, this.log)
    const client: Client = { id, channel, hello: null, handshake: null, approved: false, pairingSecret: null, lastState: null, deadline: null }
    this.clients.set(id, client)
    channel.onMessage = (message) => this.handle(message, id)
    channel.onClose = () => this.drop(id)
    // A connection that never finishes the key exchange (or a port scan) does not hang around.
    client.deadline = setTimeout(() => {
      client.deadline = null
      if (this.clients.get(id) !== client || client.approved || this.requests.some((item) => item.id === id)) return
      this.drop(id)
    }, this.options.handshakeTimeout ?? 20_000)
    connection.start(head)
  }

  private handle(message: SyncMessage, id: string): void {
    const client = this.clients.get(id)
    if (!client) return
    switch (message.kind) {
      case 'hello': {
        if (client.hello) return
        const hello = message.hello
        if (hello.protocolVersion !== SyncProtocol.version) {
          client.channel.send({
            kind: 'rejected',
            reason: tr('Обновите Waiting Paws на iPhone и на компьютере', 'Update Waiting Paws on the iPhone and on the computer'),
          })
          return
        }
        const key = SyncCrypto.newKey()
        let handshake: SyncHandshake
        try {
          handshake = new SyncCrypto.Handshake({
            privateKey: key,
            peerKey: hello.publicKey,
            phoneKey: hello.publicKey,
            macKey: key.publicKey,
            deviceID: hello.deviceID,
          })
        } catch {
          this.drop(id)
          return
        }
        client.hello = hello
        client.handshake = handshake
        this.log(`[sync] hello from ${hello.deviceName} (${SyncDevice.modelTitle(SyncHello.device(hello))}, ${hello.deviceID.slice(0, 8)})`)
        client.channel.send({ kind: 'challenge', publicKey: key.publicKey })
        return
      }
      case 'proof': {
        const { hello, handshake } = client
        if (!hello || !handshake || client.approved || client.channel.cipher) return
        const known = this.store?.find(hello.deviceID) ?? null
        if (message.proof && known?.secret && handshake.verify(message.proof, known.secret)) {
          client.pairingSecret = known.secret
          client.channel.cipher = handshake.cipher(true, known.secret)
          this.approve(id)
        } else {
          client.channel.cipher = handshake.cipher(true, null)
          // Tells the iPhone to switch to the keys without its old secret (a new pairing follows).
          client.channel.send({ kind: 'pending' })
          if (this.options.autoAccept) this.approve(id)
          else this.askApproval(client, hello)
        }
        return
      }
      case 'command': {
        if (!client.approved) return
        const command = hostCommand(message.command)
        this.log(`[sync] command ${command.kind === 'session' ? `session ${command.command}` : command.kind}`)
        try {
          this.deps.command(command)
        } catch (error) {
          this.log(`[sync] command failed: ${(error as Error).stack ?? error}`)
        }
        this.broadcast()
        return
      }
      default:
        return
    }
  }

  private askApproval(client: Client, hello: SyncHello): void {
    // The same iPhone asking again (it reconnected): the new request replaces the old one.
    for (const request of this.requests.filter((item) => item.hello.deviceID === hello.deviceID)) this.drop(request.id)
    if (this.requests.length >= maxPairingRequests) {
      client.channel.send({
        kind: 'rejected',
        reason: tr('Сначала ответьте на другие запросы на компьютере', 'Answer the other requests on the computer first'),
      })
      setTimeout(() => this.drop(client.id), 300)
      return
    }
    this.requests.push({ id: client.id, hello })
    this.log(`[sync] ${hello.deviceName} asks to join`)
    this.deps.onChange()
  }

  private approve(id: string): void {
    const client = this.clients.get(id)
    if (!client?.hello || !client.handshake) return
    const hello = client.hello
    client.approved = true
    if (client.deadline) clearTimeout(client.deadline)
    client.deadline = null
    this.requests = this.requests.filter((item) => item.id !== id)

    // A new iPhone: both sides derive the same secret from this handshake; it never crosses the network.
    const secret = client.pairingSecret ?? client.handshake.newPairingSecret()
    const device = SyncHello.device(hello)
    this.store?.save({
      deviceID: hello.deviceID,
      name: hello.deviceName,
      secret,
      platform: device.kind ?? hello.platform,
      model: hello.model,
      lastSeen: Date.now(),
    })
    // An older connection of the same iPhone (it reconnected while the old one hung on) goes away.
    for (const other of [...this.clients.values()]) if (other !== client && other.hello?.deviceID === hello.deviceID) this.drop(other.id)

    client.channel.send({ kind: 'welcome', welcome: this.welcome(client) })
    const state = this.currentState()
    if (state) {
      client.lastState = SyncMessage.encode({ kind: 'state', state })
      client.channel.send({ kind: 'state', state })
    }
    this.log(`[sync] ${hello.deviceName} (${SyncDevice.modelTitle(device)}) joined`)
    this.deps.onChange()
  }

  private drop(id: string, notify = true): void {
    const client = this.clients.get(id)
    if (!client) return
    this.clients.delete(id)
    if (client.deadline) clearTimeout(client.deadline)
    client.channel.onMessage = null
    client.channel.onClose = null
    client.channel.cancel()
    const requested = this.requests.some((item) => item.id === id)
    if (requested) this.requests = this.requests.filter((item) => item.id !== id)
    if (client.approved) this.log(`[sync] ${client.hello?.deviceName ?? 'iPhone'} left`)
    if (notify && (client.approved || requested)) this.deps.onChange()
  }

  // MARK: - Broadcast

  /// The state changed: sends it to the connected iPhones when it differs from what they have — right away, then at
  /// most every `stateInterval` (the last change always goes out). Also refreshes the Bonjour TXT record.
  broadcast(): void {
    if (!this.wanted) return
    if (this.broadcastTimer) {
      this.broadcastPending = true
      return
    }
    this.sendState()
    this.broadcastTimer = setTimeout(() => {
      this.broadcastTimer = null
      if (!this.broadcastPending) return
      this.broadcastPending = false
      this.broadcast()
    }, this.options.stateInterval ?? 250)
  }

  private sendState(): void {
    const state = this.currentState()
    if (!state) return
    this.advertiser?.updateTXT(SyncHostInfo.txt(this.hostInfo(state)))
    let encoded: string | null = null
    for (const client of [...this.clients.values()]) {
      if (!client.approved) continue
      encoded ??= SyncMessage.encode({ kind: 'state', state })
      if (client.lastState === encoded) continue
      if (client.channel.connection.bufferedAmount > maxBufferedBytes) {
        this.log(`[sync] ${client.hello?.deviceName ?? 'iPhone'} stopped reading: disconnecting`)
        this.drop(client.id)
        continue
      }
      client.lastState = encoded
      client.channel.send({ kind: 'state', state })
    }
  }

  private currentState(): SyncState | null {
    try {
      return syncState(this.deps.state())
    } catch (error) {
      this.log(`[sync] state unavailable: ${(error as Error).message}`)
      return null
    }
  }

  private hostInfo(state: SyncState | null): SyncHostInfo {
    return syncHostInfo(this.name, state, this.identity)
  }

  private welcome(client: Client): SyncWelcome {
    let access = { port: 1984, username: '', password: '' }
    try {
      access = this.deps.access()
    } catch (error) {
      this.log(`[sync] go2rtc access unavailable: ${(error as Error).message}`)
    }
    const identity = this.identity
    return {
      hostName: this.name,
      go2rtcPort: access.port,
      username: access.username,
      password: access.password,
      addresses: welcomeAddresses(client.channel.localIPv4),
      hostID: identity.id || null,
      platform: identity.platform,
      model: identity.model || null,
    }
  }
}

/// The backend's state in protocol terms (dates are epoch ms on both sides).
export function syncState(state: SyncHostState): SyncState {
  return {
    session: state.session ?? null,
    recordingSince: state.recordingSince ?? null,
    cameraReady: state.cameraReady,
    cameraTitle: state.cameraTitle ?? '',
    streamName: state.streamName ?? '',
    lastRecord: state.lastRecord ?? null,
    pendingPlan: state.pendingPlan ?? null,
    cameraSource: state.cameraSource ?? null,
    streamRevision: state.streamRevision ?? null,
  }
}

/// What the Bonjour TXT record says about this computer (the Mac's `currentInfo`): camera, whether a training runs
/// and its current exit (the next one during a break).
export function syncHostInfo(
  name: string,
  state: SyncState | null,
  identity: { id: string; platform: string; model: string } = { id: '', platform: hostPlatform, model: '' },
): SyncHostInfo {
  const session = state?.session ?? null
  let exit: number | null = null
  if (session) {
    const phase = session.phase
    const index =
      phase.kind === 'ready' || phase.kind === 'leaving' || phase.kind === 'away' ? phase.exitIndex
      : phase.kind === 'breakTime' ? phase.nextExitIndex
      : null
    exit = index === null ? null : (session.plan.exits[index]?.number ?? null)
  }
  return SyncHostInfo.make({
    name,
    cameraTitle: state?.cameraTitle ?? '',
    cameraReady: state?.cameraReady ?? false,
    sessionRunning: session !== null,
    currentExit: exit,
    id: identity.id || null,
    platform: identity.platform,
    model: identity.model,
  })
}

/// A protocol command in the backend's terms.
export function hostCommand(command: SyncCommand): SyncHostCommand {
  switch (command.kind) {
    case 'session':
      return { kind: 'session', command: command.command }
    case 'startSession':
      return { kind: 'startSession', plan: command.plan }
    case 'setPendingPlan':
      return { kind: 'setPendingPlan', plan: command.plan }
    case 'abandonSession':
    case 'startRecording':
    case 'stopRecording':
      return { kind: command.kind }
  }
}

function computerName(): string {
  try {
    return hostname() || 'Windows'
  } catch {
    return 'Windows'
  }
}
