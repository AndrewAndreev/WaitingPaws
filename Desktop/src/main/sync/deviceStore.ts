import { randomUUID } from 'node:crypto'
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

/// iPhones allowed to join (the Mac app keeps `[SyncHost.PairedDevice]` in its defaults) and this computer's own
/// identity for the link (the Mac's `SyncIdentity`): a stable host id the iPhones bind their pairings to, and the
/// last PC model read. Stored in `%APPDATA%\Waiting Paws\sync-devices.json`:
///   { "hostID": "…", "model": "Dell XPS 15 9510", "devices": [{ deviceID, name, secret, platform, model, … }] }
/// Each device's pairing secret is encrypted with Electron's safeStorage (DPAPI on Windows) when it is available,
/// base64 otherwise (like the server password in settings).

export interface PairedDevice {
  deviceID: string
  name: string
  /// The pairing secret both sides derived when the device was allowed (`SyncHandshake.newPairingSecret()`);
  /// null when the stored one can't be decrypted here (profile copied from another Windows account): the device
  /// then has to be allowed again.
  secret: string | null
  /// Epoch ms.
  pairedAt: number
  /// From the device's last hello (`SyncPlatform` raw value, "iPhone 16"); null for pairings made before these
  /// were sent.
  platform: string | null
  model: string | null
  /// When it last joined (epoch ms).
  lastSeen: number | null
}

/// How secrets are kept at rest.
export interface SecretBox {
  encrypt(text: string): string
  /// null when the value can't be decrypted.
  decrypt(stored: string): string | null
}

/// Base64 only (no encryption available, tests).
export const plainSecretBox: SecretBox = {
  encrypt: (text) => 'raw:' + Buffer.from(text, 'utf8').toString('base64'),
  decrypt: (stored) => (stored.startsWith('raw:') ? Buffer.from(stored.slice(4), 'base64').toString('utf8') : null),
}

/// The subset of Electron's `safeStorage` used here.
export interface SafeStorageLike {
  isEncryptionAvailable(): boolean
  encryptString(text: string): Buffer
  decryptString(data: Buffer): string
}

/// Electron's safeStorage when it works, base64 otherwise (the same scheme as settings.ts).
export function safeStorageSecretBox(safeStorage: SafeStorageLike): SecretBox {
  return {
    encrypt(text) {
      try {
        if (safeStorage.isEncryptionAvailable()) return 'enc:' + safeStorage.encryptString(text).toString('base64')
      } catch {
        // Fall back to base64 below.
      }
      return plainSecretBox.encrypt(text)
    },
    decrypt(stored) {
      try {
        if (stored.startsWith('enc:')) return safeStorage.decryptString(Buffer.from(stored.slice(4), 'base64'))
      } catch {
        return null
      }
      return plainSecretBox.decrypt(stored)
    },
  }
}

interface StoredDevice {
  deviceID: string
  name: string
  secret: string
  pairedAt?: number
  platform?: string
  model?: string
  lastSeen?: number
}

interface StoredFile {
  hostID?: string
  model?: string
  devices: StoredDevice[]
}

export interface PairedDeviceStoreOptions {
  /// The JSON file; null keeps everything in memory only.
  file: string | null
  box?: SecretBox
  log?: (line: string) => void
}

export class PairedDeviceStore {
  private list: PairedDevice[] = []
  /// Stored values of secrets that could not be decrypted, kept as they are in the file.
  private undecryptable = new Map<string, string>()
  private storedHostID: string | null = null
  private storedModel: string | null = null
  private readonly box: SecretBox
  private readonly log: (line: string) => void

  constructor(private readonly options: PairedDeviceStoreOptions) {
    this.box = options.box ?? plainSecretBox
    this.log = options.log ?? (() => undefined)
    this.load()
  }

  get devices(): readonly PairedDevice[] {
    return this.list
  }

  /// This computer's id for the link (TXT `id`, `welcome.hostID`): made once, then kept.
  get hostID(): string {
    if (!this.storedHostID) {
      this.storedHostID = randomUUID().toUpperCase()
      this.write()
    }
    return this.storedHostID
  }

  /// The PC model found last time (null before the first look).
  get hostModel(): string | null {
    return this.storedModel
  }

  set hostModel(model: string | null) {
    if (model === this.storedModel) return
    this.storedModel = model
    this.write()
  }

  find(deviceID: string): PairedDevice | null {
    return this.list.find((device) => device.deviceID === deviceID) ?? null
  }

  /// Adds the device or updates the one with the same id (a new secret after pairing again, a new name or model),
  /// keeping its place in the list.
  save(device: {
    deviceID: string
    name: string
    secret: string
    pairedAt?: number
    platform?: string | null
    model?: string | null
    lastSeen?: number | null
  }): void {
    const previous = this.find(device.deviceID)
    const entry: PairedDevice = {
      deviceID: device.deviceID,
      name: device.name,
      secret: device.secret,
      pairedAt: device.pairedAt ?? (previous?.secret === device.secret ? previous.pairedAt : Date.now()),
      platform: device.platform !== undefined ? device.platform : (previous?.platform ?? null),
      model: device.model !== undefined ? device.model : (previous?.model ?? null),
      lastSeen: device.lastSeen !== undefined ? device.lastSeen : (previous?.lastSeen ?? null),
    }
    this.undecryptable.delete(device.deviceID)
    this.list = previous ? this.list.map((item) => (item === previous ? entry : item)) : [...this.list, entry]
    this.write()
  }

  remove(deviceID: string): boolean {
    const count = this.list.length
    this.list = this.list.filter((item) => item.deviceID !== deviceID)
    this.undecryptable.delete(deviceID)
    if (this.list.length === count) return false
    this.write()
    return true
  }

  private load(): void {
    const file = this.options.file
    if (!file) return
    let raw: string
    try {
      raw = readFileSync(file, 'utf8')
    } catch {
      return // No file yet: no paired devices.
    }
    try {
      const parsed = JSON.parse(raw) as Partial<StoredFile>
      if (typeof parsed.hostID === 'string' && parsed.hostID !== '') this.storedHostID = parsed.hostID
      if (typeof parsed.model === 'string') this.storedModel = parsed.model
      const devices = Array.isArray(parsed.devices) ? parsed.devices : []
      for (const item of devices as Partial<StoredDevice>[]) {
        if (!item || typeof item.deviceID !== 'string' || typeof item.secret !== 'string') continue
        if (this.list.some((device) => device.deviceID === item.deviceID)) continue
        const secret = this.box.decrypt(item.secret)
        if (secret === null) {
          this.undecryptable.set(item.deviceID, item.secret)
          this.log(`[sync] the pairing of ${item.name ?? item.deviceID} can't be read here: it has to be allowed again`)
        }
        this.list.push({
          deviceID: item.deviceID,
          name: typeof item.name === 'string' ? item.name : 'iPhone',
          secret,
          pairedAt: typeof item.pairedAt === 'number' ? item.pairedAt : 0,
          platform: typeof item.platform === 'string' ? item.platform : null,
          model: typeof item.model === 'string' ? item.model : null,
          lastSeen: typeof item.lastSeen === 'number' ? item.lastSeen : null,
        })
      }
    } catch (error) {
      this.log(`[sync] ${file} is damaged, starting without paired devices: ${(error as Error).message}`)
      this.list = []
    }
  }

  private write(): void {
    const file = this.options.file
    if (!file) return
    const devices: StoredDevice[] = []
    for (const device of this.list) {
      const stored = device.secret !== null ? this.box.encrypt(device.secret) : this.undecryptable.get(device.deviceID)
      if (stored === undefined) continue
      const entry: StoredDevice = { deviceID: device.deviceID, name: device.name, secret: stored, pairedAt: device.pairedAt }
      if (device.platform !== null) entry.platform = device.platform
      if (device.model !== null) entry.model = device.model
      if (device.lastSeen !== null) entry.lastSeen = device.lastSeen
      devices.push(entry)
    }
    const content: StoredFile = { devices }
    if (this.storedHostID) content.hostID = this.storedHostID
    if (this.storedModel !== null) content.model = this.storedModel
    try {
      mkdirSync(dirname(file), { recursive: true })
      const temp = file + '.tmp'
      writeFileSync(temp, JSON.stringify(content, null, 2))
      renameSync(temp, file)
    } catch (error) {
      this.log(`[sync] could not save paired devices: ${(error as Error).message}`)
    }
  }
}

/// The app's store: `sync-devices.json` in Electron's userData, secrets through safeStorage. Electron is imported
/// here lazily, so the rest of this folder runs under plain Node (tests).
export async function defaultDeviceStore(log: (line: string) => void): Promise<PairedDeviceStore> {
  const [{ safeStorage }, { paths }] = await Promise.all([import('electron'), import('../paths')])
  return new PairedDeviceStore({ file: join(paths.userData, 'sync-devices.json'), box: safeStorageSecretBox(safeStorage), log })
}
