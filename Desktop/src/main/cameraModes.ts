import { CameraModeOption, CameraSetting, MiotValue, XiaomiCameraError, type MiotPropertyID } from '@core/cameraModes'
import { Go2RTCError, type Go2RTCClient } from '@core/go2rtcClient'
import { MiotSpecProvider } from '@core/miotSpecProvider'
import { tr } from '@core/localization'
import { nodeStorage } from './storage'
import { write as log } from './log'

/// Night mode, image flip and the other settings the selected Mi Home camera declares in its MIoT spec (port of
/// the Mac app's `CameraModesModel`). The values live in the camera and change through Mi Cloud (go2rtc
/// `/api/xiaomi/miot`), as in Mi Home.
type State = { kind: 'none' } | { kind: 'loading' } | { kind: 'ready' } | { kind: 'unavailable'; reason: string }

export class CameraModesController {
  private state: State = { kind: 'none' }
  private options: CameraModeOption[] = []
  private values: Record<string, MiotValue> = {}
  private pending = new Set<string>()
  private client: Go2RTCClient | null = null
  private source: string | null = null
  private generation = 0
  private readonly specs: MiotSpecProvider

  constructor(
    cacheDirectory: string,
    private readonly changed: () => void,
  ) {
    this.specs = new MiotSpecProvider({ cacheDirectory, storage: nodeStorage })
  }

  /// Reads which settings the camera has and their current values. `source` is the stream's `xiaomi://` URL.
  async load(client: Go2RTCClient | null, source: string | null): Promise<void> {
    const current = ++this.generation
    const model = source ? queryValue(source, 'model') : null
    if (!client || !source || !model) {
      this.reset()
      return
    }
    if (this.source !== source) {
      this.options = []
      this.values = {}
    }
    this.client = client
    this.source = source
    this.state = { kind: 'loading' }
    this.changed()

    let found: CameraModeOption[]
    try {
      found = await this.specs.cameraModes(model)
    } catch (error) {
      if (current !== this.generation) return
      log(`[camera-modes] spec for ${model}: ${(error as Error).message}`)
      this.reset()
      return
    }
    if (current !== this.generation) return
    if (!found.length) {
      log(`[camera-modes] ${model}: no settings in its spec`)
      this.reset()
      return
    }
    this.options = found
    try {
      const read = await client.xiaomiProperties(source, found.map((option) => option.property))
      if (current !== this.generation) return
      this.values = read
      // Settings the camera did not report are not shown (e.g. tracking on a fixed camera).
      this.options = found.filter((option) => read[CameraModeOption.id(option)] !== undefined)
      this.state = this.options.length ? { kind: 'ready' } : { kind: 'none' }
    } catch (error) {
      if (current !== this.generation) return
      if (error instanceof Go2RTCError && error.status === 404) {
        // A go2rtc without the Waiting Paws addition (an external server).
        this.reset()
        return
      }
      log(`[camera-modes] read ${model}: ${(error as Error).message}`)
      this.state = { kind: 'unavailable', reason: message(error) }
    }
    this.changed()
  }

  /// Writes one setting; returns an error text for the UI, or null.
  async set(key: string, value: MiotValue): Promise<string | null> {
    const option = this.options.find((item) => CameraModeOption.id(item) === key)
    if (!option || this.values[key] === value || this.pending.has(key)) return null
    const previous = this.values[key]
    this.values = { ...this.values, [key]: value }
    const client = this.client
    const source = this.source
    if (!client || !source) return null
    this.pending.add(key)
    this.changed()
    try {
      await client.setXiaomiProperty(source, option.property as MiotPropertyID, value)
      log(`[camera-modes] ${option.setting} = ${CameraModeOption.text(option, value)}`)
      return null
    } catch (error) {
      this.values = { ...this.values, [key]: previous }
      return `${CameraModeOption.title(option)}: ${message(error)}`
    } finally {
      this.pending.delete(key)
      this.changed()
    }
  }

  /// What the UI shows (see renderer `CameraModesState`).
  view() {
    const ready = this.state.kind === 'ready'
    return {
      state: this.state.kind,
      reason: this.state.kind === 'unavailable' ? this.state.reason : null,
      error: null,
      options: this.options.map((option) => {
        const key = CameraModeOption.id(option)
        const value = this.values[key]
        return {
          key,
          setting: option.setting,
          title: CameraModeOption.title(option),
          hint: CameraModeOption.hint(option),
          kind: option.kind.type,
          choices: CameraModeOption.choices(option),
          isPicture: CameraSetting.isPicture(option.setting),
          isNight: option.setting === 'nightShot',
          value: value === undefined ? null : option.kind.type === 'toggle' ? MiotValue.isOn(value) : MiotValue.number(value),
          valueText: CameraModeOption.text(option, value),
          canChange: ready && !this.pending.has(key),
        }
      }),
    }
  }

  private reset(): void {
    this.state = { kind: 'none' }
    this.options = []
    this.values = {}
    this.client = null
    this.source = null
    this.changed()
  }
}

function queryValue(source: string, name: string): string | null {
  const query = source.split('?')[1] ?? ''
  for (const part of query.split('&')) {
    const [key, value] = part.split('=')
    if (key === name) return decodeURIComponent(value ?? '')
  }
  return null
}

function message(error: unknown): string {
  if (error instanceof XiaomiCameraError) return error.message
  if (error instanceof Go2RTCError && error.status === 502) {
    // go2rtc could not reach Mi Cloud or the account token expired.
    return error.message.includes('401') ? tr('вход в Xiaomi истёк — войдите заново', 'the Xiaomi sign-in expired — sign in again') : tr('облако Xiaomi недоступно', 'the Xiaomi cloud is unavailable')
  }
  return error instanceof Error ? error.message : String(error)
}
