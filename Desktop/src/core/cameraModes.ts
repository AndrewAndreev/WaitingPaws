// Port of Xiaomi/CameraModes.swift: MIoT values, the camera settings the app presents, and reading
// device specs published on miot-spec.org. The spec download with its disk cache (`MiotSpecProvider`)
// is in miotSpecProvider.ts.

import { DecodingError, ObjectReader, expectArray, expectNumber, expectString } from './codable'
import { tr } from './localization'
import { trimWhitespaces } from './text'

/**
 * A MIoT property value. Camera switches are bools, modes are small integers (Swift's
 * `MiotValue.bool` / `.int`; in JSON simply `true` or `2`).
 */
export type MiotValue = boolean | number

export const MiotValue = {
  /** Some firmwares answer 0/1 for bool properties. */
  isOn(value: MiotValue): boolean {
    return typeof value === 'boolean' ? value : value !== 0
  },

  number(value: MiotValue): number {
    return typeof value === 'boolean' ? (value ? 1 : 0) : value
  },

  /** A bool, or a number (truncated to an integer); anything else is an error. */
  decode(value: unknown, path = ''): MiotValue {
    if (typeof value === 'boolean') return value
    if (typeof value === 'number' && Number.isFinite(value)) return Math.trunc(value)
    throw new DecodingError(path, 'Not a bool or a number')
  },
}

/** Service and property instance ids of a MIoT property (they differ from model to model). */
export interface MiotPropertyID {
  siid: number
  piid: number
}

export const MiotPropertyID = {
  /** "2.3": also the key of `Go2RTCClient.xiaomiProperties` results. */
  description(id: MiotPropertyID): string {
    return `${id.siid}.${id.piid}`
  },

  equals(a: MiotPropertyID, b: MiotPropertyID): boolean {
    return a.siid === b.siid && a.piid === b.piid
  },
}

/** Camera settings the app knows how to present, in display order (`CameraSetting.allCases`). */
export type CameraSetting =
  | 'nightShot'
  | 'glimmerFullColor'
  | 'wdr'
  | 'distortionCorrection'
  | 'imageRollover'
  | 'timeWatermark'
  | 'powerFrequency'
  | 'motionTracking'
  | 'humanTracking'
  | 'petTracking'
  | 'indicatorLight'

export const CameraSetting = {
  allCases: [
    'nightShot',
    'glimmerFullColor',
    'wdr',
    'distortionCorrection',
    'imageRollover',
    'timeWatermark',
    'powerFrequency',
    'motionTracking',
    'humanTracking',
    'petTracking',
    'indicatorLight',
  ] as readonly CameraSetting[],

  /** Names from the spec URNs (`urn:miot-spec-v2:service:camera-control:…`, `…:property:night-shot:…`). */
  specNames(setting: CameraSetting): { service: string; property: string } {
    switch (setting) {
      case 'nightShot':
        return { service: 'camera-control', property: 'night-shot' }
      case 'glimmerFullColor':
        return { service: 'camera-control', property: 'glimmer-full-color' }
      case 'wdr':
        return { service: 'camera-control', property: 'wdr-mode' }
      case 'distortionCorrection':
        return { service: 'camera-control', property: 'image-distortion-correction' }
      case 'imageRollover':
        return { service: 'camera-control', property: 'image-rollover' }
      case 'timeWatermark':
        return { service: 'camera-control', property: 'time-watermark' }
      case 'powerFrequency':
        return { service: 'camera-control', property: 'power-frequency' }
      case 'motionTracking':
        return { service: 'camera-control', property: 'motion-tracking' }
      case 'humanTracking':
        return { service: 'camera-control', property: 'human-tracking' }
      case 'petTracking':
        return { service: 'ai-detection', property: 'pet-tracking' }
      case 'indicatorLight':
        return { service: 'indicator-light', property: 'on' }
    }
  },

  title(setting: CameraSetting): string {
    switch (setting) {
      case 'nightShot':
        return tr('Night vision', 'Режим съёмки')
      case 'glimmerFullColor':
        return tr('Full-color night vision', 'Цветная ночная съёмка')
      case 'wdr':
        return tr('WDR (wide dynamic range)', 'WDR (широкий диапазон)')
      case 'distortionCorrection':
        return tr('Lens distortion correction', 'Коррекция искажений')
      case 'imageRollover':
        return tr('Rotate image', 'Поворот изображения')
      case 'timeWatermark':
        return tr('Time stamp on video', 'Время на изображении')
      case 'powerFrequency':
        return tr('Power line frequency', 'Частота сети')
      case 'motionTracking':
        return tr('Motion tracking', 'Следить за движением')
      case 'humanTracking':
        return tr('Human tracking', 'Следить за человеком')
      case 'petTracking':
        return tr('Pet tracking', 'Следить за питомцем')
      case 'indicatorLight':
        return tr('Status light', 'Индикатор на камере')
    }
  },

  /** One line under the title where the name alone is not obvious. */
  hint(setting: CameraSetting): string | null {
    switch (setting) {
      case 'nightShot':
        return tr('Night uses infrared light and a black-and-white picture.', 'Ночной — ИК-подсветка, чёрно-белая картинка.')
      case 'glimmerFullColor':
        return tr('Color in low light instead of infrared.', 'Цвет при слабом свете вместо ИК.')
      case 'powerFrequency':
        return tr('Removes flicker from lamps.', 'Убирает мерцание от ламп.')
      case 'motionTracking':
      case 'humanTracking':
      case 'petTracking':
        return tr('A pan-tilt camera follows on its own.', 'Поворотная камера сама ведёт объектив.')
      default:
        return null
    }
  },

  /** SF Symbols name used by the Apple apps (kept for parity; map it to a desktop icon set). */
  systemImage(setting: CameraSetting): string {
    switch (setting) {
      case 'nightShot':
        return 'moon.stars'
      case 'glimmerFullColor':
        return 'moon.haze'
      case 'wdr':
        return 'camera.aperture'
      case 'distortionCorrection':
        return 'camera.viewfinder'
      case 'imageRollover':
        return 'rotate.right'
      case 'timeWatermark':
        return 'clock'
      case 'powerFrequency':
        return 'bolt'
      case 'motionTracking':
        return 'figure.walk.motion'
      case 'humanTracking':
        return 'figure.walk'
      case 'petTracking':
        return 'pawprint'
      case 'indicatorLight':
        return 'lightbulb'
    }
  },

  /** Picture settings first, then what the camera does by itself. */
  isPicture(setting: CameraSetting): boolean {
    switch (setting) {
      case 'motionTracking':
      case 'humanTracking':
      case 'petTracking':
      case 'indicatorLight':
        return false
      default:
        return true
    }
  },
}

export interface CameraModeChoice {
  value: number
  title: string
}

export type CameraModeKind = { type: 'toggle' } | { type: 'choice'; choices: CameraModeChoice[] }

/** One camera setting as a particular model declares it. */
export interface CameraModeOption {
  setting: CameraSetting
  property: MiotPropertyID
  kind: CameraModeKind
}

export const CameraModeOption = {
  /** Stable id (`MiotPropertyID.description`). */
  id(option: CameraModeOption): string {
    return MiotPropertyID.description(option.property)
  },
  title(option: CameraModeOption): string {
    return CameraSetting.title(option.setting)
  },
  hint(option: CameraModeOption): string | null {
    return CameraSetting.hint(option.setting)
  },
  systemImage(option: CameraModeOption): string {
    return CameraSetting.systemImage(option.setting)
  },

  choices(option: CameraModeOption): CameraModeChoice[] {
    return option.kind.type === 'choice' ? option.kind.choices : []
  },

  /** The value to write for a switch: switches are bools. */
  valueOn(on: boolean): MiotValue {
    return on
  },

  /** The value to write for a mode: modes are integers. */
  valueChoice(choice: number): MiotValue {
    return Math.trunc(choice)
  },

  /** Title of the current value ("Авто", "Включено"). */
  text(option: CameraModeOption, value: MiotValue | null | undefined): string {
    if (value === null || value === undefined) return '—'
    if (option.kind.type === 'toggle') return MiotValue.isOn(value) ? tr('On', 'Включено') : tr('Off', 'Выключено')
    const number = MiotValue.number(value)
    return option.kind.choices.find((choice) => choice.value === number)?.title ?? `${number}`
  },
}

/** The spec could not be read (`MiotSpec.SpecError.unreadable`). */
export class MiotSpecError extends Error {
  readonly kind = 'unreadable' as const

  constructor(cause?: unknown) {
    super(tr("Couldn't read the camera's description (MIoT spec)", 'Не удалось разобрать описание камеры (MIoT spec)'), {
      cause,
    })
    this.name = 'MiotSpecError'
  }
}

// MARK: - Spec JSON (as Swift's Decodable structs read it: required keys must be there, present keys must have the right type)

interface SpecValue {
  value: number
  description: string
}

interface SpecProperty {
  iid: number
  type: string
  format: string | null
  access: string[] | null
  valueList: SpecValue[] | null
  valueRange: number[] | null
}

interface SpecService {
  iid: number
  type: string
  properties: SpecProperty[] | null
}

function decodeSpecValue(value: unknown, path: string): SpecValue {
  const json = new ObjectReader(value, path)
  const description = json.object.description
  return {
    value: Math.trunc(json.number('value')),
    description: typeof description === 'string' ? description : '',
  }
}

function decodeSpecProperty(value: unknown, path: string): SpecProperty {
  const json = new ObjectReader(value, path)
  return {
    iid: json.int('iid'),
    type: json.string('type'),
    format: json.optionalString('format'),
    access: json.optional('access', (item, itemPath) => expectArray(item, itemPath, expectString)),
    valueList: json.optional('value-list', (item, itemPath) => expectArray(item, itemPath, decodeSpecValue)),
    valueRange: json.optional('value-range', (item, itemPath) => expectArray(item, itemPath, expectNumber)),
  }
}

function decodeSpecService(value: unknown, path: string): SpecService {
  const json = new ObjectReader(value, path)
  return {
    iid: json.int('iid'),
    type: json.string('type'),
    properties: json.optional('properties', (item, itemPath) => expectArray(item, itemPath, decodeSpecProperty)),
  }
}

function parseJSONInput(input: string | Uint8Array | unknown): unknown {
  if (typeof input === 'string') return JSON.parse(input)
  if (input instanceof Uint8Array) return JSON.parse(new TextDecoder().decode(input))
  return input
}

/** Spec descriptions are English: "Auto", "On", "Off", sometimes "Open"/"Close". */
function nightTitle(description: string): { order: number; title: string } | null {
  const text = trimWhitespaces(description.toLowerCase())
  if (text.includes('auto')) return { order: 0, title: tr('Auto', 'Авто') }
  if (text === 'on' || text.includes('open') || text.endsWith(' on')) return { order: 1, title: tr('Night', 'Ночной') }
  if (text === 'off' || text.includes('close') || text.endsWith(' off')) return { order: 2, title: tr('Day', 'Обычный') }
  return null
}

function rolloverTitle(degrees: number): string {
  return degrees === 0 ? tr('Not rotated', 'Без поворота') : `${degrees}°`
}

function kindFor(setting: CameraSetting, property: SpecProperty): CameraModeKind | null {
  if (property.format === 'bool') return { type: 'toggle' }
  let choices: CameraModeChoice[]
  switch (setting) {
    case 'nightShot':
      choices = (property.valueList ?? [])
        .flatMap((item) => {
          const title = nightTitle(item.description)
          return title ? [{ value: item.value, ...title }] : []
        })
        .sort((a, b) => a.order - b.order)
        .map(({ value, title }) => ({ value, title }))
      break
    case 'powerFrequency':
      choices = (property.valueList ?? []).map((item) => {
        const text = trimWhitespaces(item.description)
        if (text.toLowerCase().includes('auto')) return { value: item.value, title: tr('Auto', 'Авто') }
        const digits = Array.from(text.matchAll(/\p{N}/gu), (match) => match[0]).join('')
        return { value: item.value, title: digits === '' ? text : tr(`${digits} Hz`, `${digits} Гц`) }
      })
      break
    case 'imageRollover': {
      const list = property.valueList
      const range = property.valueRange
      if (list && list.length > 0) {
        choices = list.map((item) => ({ value: item.value, title: rolloverTitle(item.value) }))
      } else if (range && range.length >= 3 && Math.trunc(range[2]) > 0) {
        // [0, 180, 180] → 0°, 180°; some specs declare 360, which is 0° again.
        const values: number[] = []
        for (let value = Math.trunc(range[0]); value <= Math.trunc(range[1]); value += Math.trunc(range[2])) {
          if (value < 360) values.push(value)
        }
        choices = values.slice(0, 8).map((value) => ({ value, title: rolloverTitle(value) }))
      } else {
        choices = []
      }
      break
    }
    default:
      choices = (property.valueList ?? []).map((item) => ({ value: item.value, title: item.description }))
  }
  return choices.length >= 2 ? { type: 'choice', choices } : null
}

/** Reads device specs published on miot-spec.org (the same ones Mi Home uses). */
export const MiotSpec = {
  /**
   * The settings from `CameraSetting` that the spec (`/miot-spec-v2/instance?type=…`) declares as readable
   * and writable, with their choices translated. Value meanings come from the spec: night-shot 0 is
   * "Off" on some models and "On" on others. Accepts the JSON text, its UTF-8 bytes or the parsed value.
   */
  cameraModes(spec: string | Uint8Array | unknown): CameraModeOption[] {
    let services: SpecService[]
    try {
      services = new ObjectReader(parseJSONInput(spec)).array('services', decodeSpecService)
    } catch (error) {
      throw new MiotSpecError(error)
    }
    const found = new Map<CameraSetting, CameraModeOption>()
    for (const service of services) {
      const serviceName = MiotSpec.urnName(service.type)
      for (const property of service.properties ?? []) {
        const access = new Set(property.access ?? [])
        if (!access.has('read') || !access.has('write')) continue
        const propertyName = MiotSpec.urnName(property.type)
        const setting = CameraSetting.allCases.find((candidate) => {
          const names = CameraSetting.specNames(candidate)
          return names.service === serviceName && names.property === propertyName
        })
        if (setting === undefined || found.has(setting)) continue
        const kind = kindFor(setting, property)
        if (kind) found.set(setting, { setting, property: { siid: service.iid, piid: property.iid }, kind })
      }
    }
    return CameraSetting.allCases.flatMap((setting) => {
      const option = found.get(setting)
      return option ? [option] : []
    })
  },

  /** Type URN of the newest spec for `model` in the instance list (`/miot-spec-v2/instances?status=released`). */
  specType(model: string, index: string | Uint8Array | unknown): string | null {
    let instances: { model: string; version: number | null; type: string }[]
    try {
      instances = new ObjectReader(parseJSONInput(index)).array('instances', (item, path) => {
        const json = new ObjectReader(item, path)
        return { model: json.string('model'), version: json.optionalInt('version'), type: json.string('type') }
      })
    } catch (error) {
      throw new MiotSpecError(error)
    }
    let newest: (typeof instances)[number] | null = null
    for (const instance of instances) {
      if (instance.model !== model) continue
      // Like Swift's max(by:): the first of equal versions wins.
      if (newest === null || (newest.version ?? 0) < (instance.version ?? 0)) newest = instance
    }
    return newest?.type ?? null
  },

  /** `urn:miot-spec-v2:property:night-shot:00000…:xiaomi-c302n:1` → `night-shot`. */
  urnName(urn: string): string {
    const parts = urn.split(':')
    return parts.length > 3 ? parts[3] : ''
  },
}

/** A camera setting change or read that Mi Cloud refused. */
export class XiaomiCameraError extends Error {
  private constructor(
    readonly kind: 'offline' | 'failed',
    readonly code: number | null,
  ) {
    super('')
    this.name = 'XiaomiCameraError'
    this.message = this.errorDescription
  }

  static offline(): XiaomiCameraError {
    return new XiaomiCameraError('offline', null)
  }

  static failed(code: number): XiaomiCameraError {
    return new XiaomiCameraError('failed', code)
  }

  /** MIoT result codes: 0 done, 1 accepted (applied asynchronously). */
  static check(code: number): void {
    switch (code) {
      case 0:
      case 1:
        return
      case -704042011:
      case -704083036:
        throw XiaomiCameraError.offline()
      default:
        throw XiaomiCameraError.failed(code)
    }
  }

  /** The text in the current language (`message` is fixed when the error is made). */
  get errorDescription(): string {
    return this.kind === 'offline'
      ? tr(
          "The camera didn't answer the Xiaomi cloud: it is off or offline",
          'Камера не ответила облаку Xiaomi — она выключена или без интернета',
        )
      : tr(`Xiaomi didn't apply the setting (code ${this.code})`, `Xiaomi не применил настройку (код ${this.code})`)
  }

  equals(other: unknown): boolean {
    return other instanceof XiaomiCameraError && other.kind === this.kind && other.code === this.code
  }
}
