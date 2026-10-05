import { safeStorage } from 'electron'
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { defaultSettings, type Settings, type XiaomiRegion } from '@shared/settings'

/// Settings in `%APPDATA%\Waiting Paws\settings.json`; the go2rtc server password is encrypted with
/// Electron's safeStorage (DPAPI on Windows) and the LAN password for linked iPhones lives next to them.
interface StoredSettings extends Omit<Settings, 'serverPassword'> {
  serverPasswordEncrypted?: string
  lanPassword?: string
}

/// What the UI gets instead of the real password.
export const PASSWORD_MARKER = '••••••'

export class SettingsStore {
  private data: StoredSettings
  private listeners = new Set<(settings: Settings) => void>()

  constructor(private readonly file: string) {
    let stored: Partial<StoredSettings> = {}
    try {
      stored = JSON.parse(readFileSync(file, 'utf8'))
    } catch {
      stored = { xiaomiRegion: suggestedRegion() }
    }
    this.data = { ...defaultSettings, ...stored } as StoredSettings
    delete (this.data as Partial<Settings>).serverPassword
  }

  get value(): Settings {
    return { ...this.data, serverPassword: this.serverPassword() } as Settings
  }

  /// What the UI may see: the password is replaced by a marker.
  get publicValue(): Settings {
    const { serverPasswordEncrypted, lanPassword: _lan, ...rest } = this.data
    return { ...rest, serverPassword: serverPasswordEncrypted ? PASSWORD_MARKER : '' } as Settings
  }

  update(patch: Partial<Settings>): void {
    const { serverPassword, ...rest } = patch
    Object.assign(this.data, rest)
    if (serverPassword !== undefined && serverPassword !== PASSWORD_MARKER) {
      this.data.serverPasswordEncrypted = serverPassword ? encrypt(serverPassword) : undefined
    }
    this.save()
    const value = this.value
    for (const listener of this.listeners) listener(value)
  }

  onChange(listener: (settings: Settings) => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  /// Password of the bundled go2rtc for LAN clients (linked iPhones); generated once.
  get lanPassword(): string {
    return this.data.lanPassword || this.rotateLanPassword()
  }

  /// A new LAN password (an iPhone was forgotten: it must lose access to the video too).
  rotateLanPassword(): string {
    const generated = (crypto.randomUUID() + crypto.randomUUID()).replace(/-/g, '').toLowerCase()
    this.data.lanPassword = generated
    this.save()
    return generated
  }

  private serverPassword(): string {
    return this.data.serverPasswordEncrypted ? decrypt(this.data.serverPasswordEncrypted) : ''
  }

  private save(): void {
    mkdirSync(dirname(this.file), { recursive: true })
    const temp = this.file + '.tmp'
    writeFileSync(temp, JSON.stringify(this.data, null, 2))
    renameSync(temp, this.file)
  }
}

function encrypt(text: string): string {
  if (safeStorage.isEncryptionAvailable()) return 'enc:' + safeStorage.encryptString(text).toString('base64')
  return 'raw:' + Buffer.from(text).toString('base64')
}

function decrypt(value: string): string {
  try {
    if (value.startsWith('enc:')) return safeStorage.decryptString(Buffer.from(value.slice(4), 'base64'))
    if (value.startsWith('raw:')) return Buffer.from(value.slice(4), 'base64').toString()
  } catch {
    // A profile copied from another Windows account can't be decrypted: the user enters the password again.
  }
  return ''
}

/// The Mi Home server region most likely for this computer's region (the user can change it).
function suggestedRegion(): XiaomiRegion {
  const locale = Intl.DateTimeFormat().resolvedOptions().locale
  const region = (locale.split('-')[1] ?? '').toUpperCase()
  if (['RU', 'BY', 'KZ', 'KG', 'AM', 'UZ', 'TJ'].includes(region)) return 'ru'
  if (['CN', 'HK', 'MO', 'TW'].includes(region)) return 'cn'
  if (['US', 'CA', 'MX', 'BR', 'AR', 'CL', 'CO', 'PE'].includes(region)) return 'us'
  if (region === 'IN') return 'i2'
  if (['SG', 'MY', 'ID', 'TH', 'VN', 'PH', 'AU', 'NZ', 'JP', 'KR'].includes(region)) return 'sg'
  if (locale.startsWith('ru')) return 'ru'
  return 'de'
}
