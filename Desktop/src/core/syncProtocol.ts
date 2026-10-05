// Port of Sync/SyncProtocol.swift.
//
// iPhone ↔ Mac link. The Mac owns the session, the camera (embedded go2rtc) and the recording; an iPhone
// on the same network finds it over Bonjour, asks to join (the Mac user allows it once), then shows the
// Mac's camera and a mirror of its session and sends button presses back. Several Macs and iPhones can share
// a network (and Windows PCs as hosts): each side tells who it is (`SyncDevice`: id, name, kind, model), and
// pairings are bound to the ids. The identity fields are optional, so builds before them still understand
// every message.
//
// Transport: WebSocket over TCP, one JSON `SyncMessage` per text frame. From the key exchange on, the
// frames are encrypted (`SyncCipher`, src/core/node/syncCrypto.ts).
//
// The JSON is what Swift's synthesized `Codable` writes with `.millisecondsSince1970` dates, e.g.
//   {"hello":{"_0":{"deviceID":"…","deviceName":"…","publicKey":"<base64>","protocolVersion":2}}}
//   {"pending":{}}   {"proof":{}} (nil)   {"command":{"_0":{"session":{"_0":"endExit"}}}}
// so a TypeScript host can talk to the real iPhone app.

import {
  type DateEncoding,
  type JSONObject,
  DecodingError,
  ObjectReader,
  SYNC_DATES,
  base64Encode,
  compact,
  encodeDate,
  expectData,
  expectString,
  readEnumCase,
  utf8Decode,
} from './codable'
import { TrainingPlan } from './models'
import { TrainingRecord } from './sessionLog'
import { SessionCommand, TrainingSession, type TrainingSessionSnapshot } from './trainingSession'
import { SyncDevice, SyncPlatform } from './syncDevice'
import { parseSwiftInt } from './text'

export const SyncProtocol = {
  /** Bonjour service type advertised by the Mac. */
  serviceType: '_waitingpaws._tcp',
  /** 2: key exchange, proof of pairing and encrypted messages (v1 sent everything in the clear). */
  version: 2,

  /** TXT record keys of the advertised service. */
  TXT: {
    /** Protocol version. */
    version: 'v',
    /** Camera name shown on the iPhone ("Прихожая"). */
    camera: 'cam',
    /** "1" when go2rtc runs and a camera is selected on the Mac. */
    ready: 'ready',
    /** "1" while a training runs on the Mac. */
    session: 'session',
    /** Current exit number while a training runs. */
    exit: 'exit',
    /** The host's stable id (`SyncDevice.id`); hosts before it are known by their name only. */
    id: 'id',
    /** `SyncPlatform` raw value ("mac", "windows"); missing = a Mac. */
    platform: 'os',
    /** "MacBook Air", "Mac mini". */
    model: 'model',
  },

  /** `encoder()` / `decoder()` date strategy. */
  dates: SYNC_DATES as DateEncoding,
} as const

// MARK: - Bonjour

/** What a Mac advertises before anyone connects (from the Bonjour TXT record). */
export interface SyncHostInfo {
  /** The Bonjour service name: the host's name, made unique on the network by Bonjour ("MacBook Pro (2)"). */
  name: string
  version: number
  cameraTitle: string
  cameraReady: boolean
  sessionRunning: boolean
  currentExit: number | null
  /** null for hosts that don't send one yet (they are told apart by name). */
  id: string | null
  /** `SyncPlatform` raw value; null = a Mac (the only host before the field existed). */
  platform: string | null
  model: string
}

export const SyncHostInfo = {
  make(fields: Pick<SyncHostInfo, 'name'> & Partial<SyncHostInfo>): SyncHostInfo {
    return {
      name: fields.name,
      version: fields.version ?? SyncProtocol.version,
      cameraTitle: fields.cameraTitle ?? '',
      cameraReady: fields.cameraReady ?? false,
      sessionRunning: fields.sessionRunning ?? false,
      currentExit: fields.currentExit ?? null,
      id: fields.id ?? null,
      platform: fields.platform ?? null,
      model: fields.model ?? '',
    }
  },

  fromTXT(name: string, txt: Record<string, string>): SyncHostInfo {
    const { TXT } = SyncProtocol
    const id = txt[TXT.id]
    return {
      name,
      version: parseSwiftInt(txt[TXT.version] ?? '') ?? 0,
      cameraTitle: txt[TXT.camera] ?? '',
      cameraReady: txt[TXT.ready] === '1',
      sessionRunning: txt[TXT.session] === '1',
      currentExit: parseSwiftInt(txt[TXT.exit] ?? ''),
      id: id === undefined || id === '' ? null : id,
      platform: txt[TXT.platform] ?? null,
      model: txt[TXT.model] ?? '',
    }
  },

  txt(info: SyncHostInfo): Record<string, string> {
    const { TXT } = SyncProtocol
    const txt: Record<string, string> = {
      [TXT.version]: `${info.version}`,
      [TXT.camera]: info.cameraTitle,
      [TXT.ready]: info.cameraReady ? '1' : '0',
      [TXT.session]: info.sessionRunning ? '1' : '0',
    }
    if (info.currentExit !== null) txt[TXT.exit] = `${info.currentExit}`
    if (info.id !== null) txt[TXT.id] = info.id
    if (info.platform !== null) txt[TXT.platform] = info.platform
    if (info.model !== '') txt[TXT.model] = info.model
    return txt
  },

  /** The host as the UI shows it. Without an id the name stands in for it ("name:" keeps the two apart). */
  device(info: SyncHostInfo): SyncDevice {
    return {
      id: info.id ?? 'name:' + info.name,
      name: info.name,
      kind: info.platform === null ? 'mac' : SyncPlatform.from(info.platform),
      model: info.model,
    }
  },
}

// MARK: - Messages

/** iPhone → Mac: who is asking, with the iPhone's key for this connection (Curve25519, raw 32 bytes). */
export interface SyncHello {
  deviceID: string
  deviceName: string
  publicKey: Uint8Array
  protocolVersion: number
  /** `SyncPlatform` raw value; null from builds before it (always an iPhone then). */
  platform: string | null
  /** "iPhone 16 Pro": iOS gives apps only "iPhone" as the device name, so the model is what tells two apart. */
  model: string | null
}

export const SyncHello = {
  make(
    fields: Pick<SyncHello, 'deviceID' | 'deviceName' | 'publicKey'> & Partial<SyncHello>,
  ): SyncHello {
    return {
      deviceID: fields.deviceID,
      deviceName: fields.deviceName,
      publicKey: fields.publicKey,
      protocolVersion: fields.protocolVersion ?? SyncProtocol.version,
      platform: fields.platform ?? null,
      model: fields.model ?? null,
    }
  },

  device(hello: SyncHello): SyncDevice {
    return {
      id: hello.deviceID,
      name: hello.deviceName,
      kind: hello.platform === null ? 'iphone' : SyncPlatform.from(hello.platform),
      model: hello.model ?? '',
    }
  },
}

/** Mac → iPhone after approval (sealed): access to the Mac's go2rtc. Sent again when the password changes. */
export interface SyncWelcome {
  hostName: string
  /** go2rtc API port on the Mac (LAN, Basic auth). */
  go2rtcPort: number
  username: string
  password: string
  /** The Mac's IPv4 addresses, in case the connection's own address is not usable for HTTP. */
  addresses: string[]
  /** Who the host is (as in its TXT record, but sealed); null from builds before these fields. */
  hostID: string | null
  platform: string | null
  model: string | null
}

export const SyncWelcome = {
  make(
    fields: Pick<SyncWelcome, 'hostName' | 'go2rtcPort' | 'username' | 'password' | 'addresses'> & Partial<SyncWelcome>,
  ): SyncWelcome {
    return {
      hostName: fields.hostName,
      go2rtcPort: fields.go2rtcPort,
      username: fields.username,
      password: fields.password,
      addresses: fields.addresses,
      hostID: fields.hostID ?? null,
      platform: fields.platform ?? null,
      model: fields.model ?? null,
    }
  },
}

/** Mac → iPhone: everything the iPhone shows, sent on every change. */
export interface SyncState {
  session: TrainingSessionSnapshot | null
  /** When the Mac's recording started (epoch ms; null = not recording). */
  recordingSince: number | null
  cameraReady: boolean
  cameraTitle: string
  streamName: string
  /** The session that has just finished on the Mac (for the summary and the log on the iPhone). */
  lastRecord: TrainingRecord | null
  /** A schedule pasted on either device and waiting for «Начать» (null while a session runs). */
  pendingPlan: TrainingPlan | null
  /**
   * The camera's `xiaomi://` source, for its settings on the iPhone (the Mac's go2rtc config, which also
   * holds the Xiaomi tokens, is closed to the LAN).
   */
  cameraSource: string | null
  /**
   * Changes whenever the Mac's players had to reconnect (quality change): the iPhone's player reconnects too,
   * or the old stream keeps a second connection to the camera open.
   */
  streamRevision: number | null
}

export const SyncState = {
  make(
    fields: Pick<SyncState, 'session' | 'recordingSince' | 'cameraReady' | 'cameraTitle' | 'streamName' | 'lastRecord'> &
      Partial<SyncState>,
  ): SyncState {
    return {
      session: fields.session,
      recordingSince: fields.recordingSince,
      cameraReady: fields.cameraReady,
      cameraTitle: fields.cameraTitle,
      streamName: fields.streamName,
      lastRecord: fields.lastRecord,
      pendingPlan: fields.pendingPlan ?? null,
      cameraSource: fields.cameraSource ?? null,
      streamRevision: fields.streamRevision ?? null,
    }
  },
}

/** iPhone → Mac. */
export type SyncCommand =
  | { kind: 'session'; command: SessionCommand }
  | { kind: 'startSession'; plan: TrainingPlan }
  /** A schedule pasted (or edited) on the iPhone becomes the Mac's waiting one; null clears it. */
  | { kind: 'setPendingPlan'; plan: TrainingPlan | null }
  | { kind: 'abandonSession' }
  | { kind: 'startRecording' }
  | { kind: 'stopRecording' }

export type SyncMessage =
  | { kind: 'hello'; hello: SyncHello }
  /** Mac → iPhone: the Mac's key for this connection. */
  | { kind: 'challenge'; publicKey: Uint8Array }
  /** iPhone → Mac: proof of an earlier pairing with this Mac, null for a new iPhone. */
  | { kind: 'proof'; proof: Uint8Array | null }
  /** The Mac shows an approval prompt; wait. */
  | { kind: 'pending' }
  | { kind: 'rejected'; reason: string }
  /** An encrypted `welcome`, `state` or `command` (see `SyncCipher`). */
  | { kind: 'sealed'; data: Uint8Array }
  | { kind: 'welcome'; welcome: SyncWelcome }
  | { kind: 'state'; state: SyncState }
  | { kind: 'command'; command: SyncCommand }

// MARK: - JSON

const dates = SYNC_DATES

// The identity fields are optional: left out when nil (`encodeIfPresent`), so older builds read the rest.

function encodeHello(hello: SyncHello): JSONObject {
  return compact({
    deviceID: hello.deviceID,
    deviceName: hello.deviceName,
    publicKey: base64Encode(hello.publicKey),
    protocolVersion: hello.protocolVersion,
    platform: hello.platform ?? null,
    model: hello.model ?? null,
  })
}

function decodeHello(value: unknown, path: string): SyncHello {
  const json = new ObjectReader(value, path)
  return {
    deviceID: json.string('deviceID'),
    deviceName: json.string('deviceName'),
    publicKey: json.required('publicKey', expectData),
    protocolVersion: json.int('protocolVersion'),
    platform: json.optionalString('platform'),
    model: json.optionalString('model'),
  }
}

function encodeWelcome(welcome: SyncWelcome): JSONObject {
  return compact({
    hostName: welcome.hostName,
    go2rtcPort: welcome.go2rtcPort,
    username: welcome.username,
    password: welcome.password,
    addresses: welcome.addresses,
    hostID: welcome.hostID ?? null,
    platform: welcome.platform ?? null,
    model: welcome.model ?? null,
  })
}

function decodeWelcome(value: unknown, path: string): SyncWelcome {
  const json = new ObjectReader(value, path)
  return {
    hostName: json.string('hostName'),
    go2rtcPort: json.int('go2rtcPort'),
    username: json.string('username'),
    password: json.string('password'),
    addresses: json.array('addresses', expectString),
    hostID: json.optionalString('hostID'),
    platform: json.optionalString('platform'),
    model: json.optionalString('model'),
  }
}

function encodeState(state: SyncState): JSONObject {
  return compact({
    session: state.session === null ? null : TrainingSession.encodeSnapshot(state.session, dates),
    recordingSince: state.recordingSince === null ? null : encodeDate(state.recordingSince, dates),
    cameraReady: state.cameraReady,
    cameraTitle: state.cameraTitle,
    streamName: state.streamName,
    lastRecord: state.lastRecord === null ? null : TrainingRecord.encode(state.lastRecord, dates),
    pendingPlan: state.pendingPlan === null ? null : TrainingPlan.encode(state.pendingPlan, dates),
    cameraSource: state.cameraSource,
    streamRevision: state.streamRevision,
  })
}

function decodeState(value: unknown, path: string): SyncState {
  const json = new ObjectReader(value, path)
  return {
    session: json.optional('session', (item, itemPath) => TrainingSession.decodeSnapshot(item, dates, itemPath)),
    recordingSince: json.optionalDate('recordingSince', dates),
    cameraReady: json.bool('cameraReady'),
    cameraTitle: json.string('cameraTitle'),
    streamName: json.string('streamName'),
    lastRecord: json.optional('lastRecord', (item, itemPath) => TrainingRecord.decode(item, dates, itemPath)),
    pendingPlan: json.optional('pendingPlan', (item, itemPath) => TrainingPlan.decode(item, dates, itemPath)),
    cameraSource: json.optionalString('cameraSource'),
    streamRevision: json.optionalInt('streamRevision'),
  }
}

function encodeCommand(command: SyncCommand): JSONObject {
  switch (command.kind) {
    case 'session':
      return { session: { _0: command.command } }
    case 'startSession':
      return { startSession: { _0: TrainingPlan.encode(command.plan, dates) } }
    case 'setPendingPlan':
      return { setPendingPlan: command.plan === null ? {} : { _0: TrainingPlan.encode(command.plan, dates) } }
    case 'abandonSession':
    case 'startRecording':
    case 'stopRecording':
      return { [command.kind]: {} }
  }
}

function decodeCommand(value: unknown, path: string): SyncCommand {
  const [name, json] = readEnumCase(value, path)
  switch (name) {
    case 'session':
      return { kind: 'session', command: json.required('_0', SessionCommand.decode) }
    case 'startSession':
      return { kind: 'startSession', plan: json.required('_0', (item, p) => TrainingPlan.decode(item, dates, p)) }
    case 'setPendingPlan':
      return { kind: 'setPendingPlan', plan: json.optional('_0', (item, p) => TrainingPlan.decode(item, dates, p)) }
    case 'abandonSession':
    case 'startRecording':
    case 'stopRecording':
      return { kind: name }
    default:
      throw new DecodingError(path, `unknown command ${name}`)
  }
}

export const SyncMessage = {
  /** Messages that only ever travel sealed. */
  needsSealing(message: SyncMessage): boolean {
    return message.kind === 'welcome' || message.kind === 'state' || message.kind === 'command'
  },

  /** The JSON value Swift's `JSONEncoder` produces for the message. */
  toJSON(message: SyncMessage): JSONObject {
    switch (message.kind) {
      case 'hello':
        return { hello: { _0: encodeHello(message.hello) } }
      case 'challenge':
        return { challenge: { _0: base64Encode(message.publicKey) } }
      case 'proof':
        return { proof: message.proof === null ? {} : { _0: base64Encode(message.proof) } }
      case 'pending':
        return { pending: {} }
      case 'rejected':
        return { rejected: { _0: message.reason } }
      case 'sealed':
        return { sealed: { _0: base64Encode(message.data) } }
      case 'welcome':
        return { welcome: { _0: encodeWelcome(message.welcome) } }
      case 'state':
        return { state: { _0: encodeState(message.state) } }
      case 'command':
        return { command: { _0: encodeCommand(message.command) } }
    }
  },

  fromJSON(value: unknown, path = ''): SyncMessage {
    const [name, json] = readEnumCase(value, path)
    switch (name) {
      case 'hello':
        return { kind: 'hello', hello: json.required('_0', decodeHello) }
      case 'challenge':
        return { kind: 'challenge', publicKey: json.required('_0', expectData) }
      case 'proof':
        return { kind: 'proof', proof: json.optional('_0', expectData) }
      case 'pending':
        return { kind: 'pending' }
      case 'rejected':
        return { kind: 'rejected', reason: json.required('_0', expectString) }
      case 'sealed':
        return { kind: 'sealed', data: json.required('_0', expectData) }
      case 'welcome':
        return { kind: 'welcome', welcome: json.required('_0', decodeWelcome) }
      case 'state':
        return { kind: 'state', state: json.required('_0', decodeState) }
      case 'command':
        return { kind: 'command', command: json.required('_0', decodeCommand) }
      default:
        throw new DecodingError(path, `unknown message ${name}`)
    }
  },

  /** One WebSocket text frame (`encoded()`). */
  encode(message: SyncMessage): string {
    return JSON.stringify(SyncMessage.toJSON(message))
  },

  /** Parses a frame (`SyncMessage.decode(_:)`); throws `SyntaxError` or `DecodingError`. */
  decode(frame: string | Uint8Array): SyncMessage {
    return SyncMessage.fromJSON(JSON.parse(typeof frame === 'string' ? frame : utf8Decode(frame)))
  },
}
