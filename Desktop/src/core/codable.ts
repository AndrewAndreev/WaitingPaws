// JSON compatibility with Swift's `Codable` as the Mac and iPhone apps use it.
//
// - Optionals are left out when nil (`encodeIfPresent`); on decode a missing key and `null` both mean nil,
//   a value of the wrong type is an error (like `JSONDecoder`).
// - Dates: `iso8601` on disk (`SessionStore`: "2026-09-25T15:00:05Z", whole seconds, UTC) and
//   `millisecondsSince1970` on the iPhone ↔ Mac link (`SyncProtocol`: a JSON number, may be fractional).
// - `UUID` is its `uuidString`: upper-case 8-4-4-4-12 hex. Decoded ids are normalised to upper case.
// - `Data` is a standard base64 string with padding.
// - Enums with associated values: `{"case":{"label":value}}`, unlabeled values as `"_0"`, cases without
//   values as `{"case":{}}` (Swift 5.5 synthesized Codable).

export type DateEncoding = 'iso8601' | 'millisecondsSince1970'

/** Dates as `SessionStore` writes them (`JSONEncoder.dateEncodingStrategy = .iso8601`). */
export const DISK_DATES: DateEncoding = 'iso8601'
/** Dates as `SyncProtocol` sends them (`.millisecondsSince1970`). */
export const SYNC_DATES: DateEncoding = 'millisecondsSince1970'

export type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue }
export type JSONObject = { [key: string]: JSONValue }

/** A JSON document that does not have the shape Swift's `JSONDecoder` would accept. */
export class DecodingError extends Error {
  constructor(
    readonly path: string,
    readonly reason: string,
  ) {
    super(`${path || '<root>'}: ${reason}`)
    this.name = 'DecodingError'
  }
}

// MARK: - Reading

function describe(value: unknown): string {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'an array'
  return typeof value === 'object' ? 'an object' : `a ${typeof value}`
}

function at(path: string, key: string | number): string {
  return typeof key === 'number' ? `${path}[${key}]` : path ? `${path}.${key}` : key
}

export function expectObject(value: unknown, path = ''): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new DecodingError(path, `expected an object, found ${describe(value)}`)
  }
  return value as Record<string, unknown>
}

export function expectArray<T>(value: unknown, path: string, item: (value: unknown, path: string) => T): T[] {
  if (!Array.isArray(value)) throw new DecodingError(path, `expected an array, found ${describe(value)}`)
  return value.map((element, index) => item(element, at(path, index)))
}

export function expectString(value: unknown, path: string): string {
  if (typeof value !== 'string') throw new DecodingError(path, `expected a string, found ${describe(value)}`)
  return value
}

export function expectNumber(value: unknown, path: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new DecodingError(path, `expected a number, found ${describe(value)}`)
  }
  return value
}

/** `Int`: a JSON number without a fractional part. */
export function expectInt(value: unknown, path: string): number {
  const number = expectNumber(value, path)
  if (!Number.isInteger(number)) throw new DecodingError(path, `expected an integer, found ${number}`)
  return number
}

export function expectBool(value: unknown, path: string): boolean {
  if (typeof value !== 'boolean') throw new DecodingError(path, `expected a bool, found ${describe(value)}`)
  return value
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function expectUUID(value: unknown, path: string): string {
  const text = expectString(value, path)
  if (!uuidPattern.test(text)) throw new DecodingError(path, `not a UUID: ${text}`)
  return text.toUpperCase()
}

export function expectDate(value: unknown, path: string, dates: DateEncoding): number {
  if (dates === 'millisecondsSince1970') return expectNumber(value, path)
  const text = expectString(value, path)
  const ms = parseISO8601(text)
  if (ms === null) throw new DecodingError(path, `expected an ISO 8601 date, found ${text}`)
  return ms
}

export function expectData(value: unknown, path: string): Uint8Array {
  const bytes = base64Decode(expectString(value, path))
  if (bytes === null) throw new DecodingError(path, 'not base64')
  return bytes
}

/** Reads keys of one JSON object; `optional…` accept a missing key or `null`. */
export class ObjectReader {
  readonly object: Record<string, unknown>

  constructor(
    value: unknown,
    readonly path = '',
  ) {
    this.object = expectObject(value, path)
  }

  has(key: string): boolean {
    return this.object[key] !== undefined && this.object[key] !== null
  }

  required<T>(key: string, read: (value: unknown, path: string) => T): T {
    if (!(key in this.object) || this.object[key] === undefined) {
      throw new DecodingError(at(this.path, key), 'missing key')
    }
    return read(this.object[key], at(this.path, key))
  }

  optional<T>(key: string, read: (value: unknown, path: string) => T): T | null {
    return this.has(key) ? read(this.object[key], at(this.path, key)) : null
  }

  string(key: string): string {
    return this.required(key, expectString)
  }
  optionalString(key: string): string | null {
    return this.optional(key, expectString)
  }
  number(key: string): number {
    return this.required(key, expectNumber)
  }
  optionalNumber(key: string): number | null {
    return this.optional(key, expectNumber)
  }
  int(key: string): number {
    return this.required(key, expectInt)
  }
  optionalInt(key: string): number | null {
    return this.optional(key, expectInt)
  }
  bool(key: string): boolean {
    return this.required(key, expectBool)
  }
  optionalBool(key: string): boolean | null {
    return this.optional(key, expectBool)
  }
  uuid(key: string): string {
    return this.required(key, expectUUID)
  }
  date(key: string, dates: DateEncoding): number {
    return this.required(key, (value, path) => expectDate(value, path, dates))
  }
  optionalDate(key: string, dates: DateEncoding): number | null {
    return this.optional(key, (value, path) => expectDate(value, path, dates))
  }
  array<T>(key: string, item: (value: unknown, path: string) => T): T[] {
    return this.required(key, (value, path) => expectArray(value, path, item))
  }
}

/**
 * The single case of a Swift enum with associated values: `{"ready":{"exitIndex":0}}` →
 * `["ready", reader of {"exitIndex":0}]`. Like `JSONDecoder`, exactly one key is required.
 */
export function readEnumCase(value: unknown, path: string): [string, ObjectReader] {
  const object = expectObject(value, path)
  const keys = Object.keys(object)
  if (keys.length !== 1) throw new DecodingError(path, `expected one enum case key, found ${keys.length}`)
  const name = keys[0]
  return [name, new ObjectReader(object[name], at(path, name))]
}

// MARK: - Writing

export function encodeDate(ms: number, dates: DateEncoding): string | number {
  return dates === 'millisecondsSince1970' ? ms : formatISO8601(ms)
}

/** Builds a JSON object, leaving out `null` / `undefined` values like `encodeIfPresent`. */
export function compact(entries: Record<string, JSONValue | undefined>): JSONObject {
  const object: JSONObject = {}
  for (const [key, value] of Object.entries(entries)) {
    if (value !== null && value !== undefined) object[key] = value
  }
  return object
}

/**
 * `JSONEncoder` text: `outputFormatting = [.prettyPrinted, .sortedKeys]` gives 2-space indentation,
 * `"key" : value` and keys in case-insensitive order; slashes are escaped (`\/`) as Foundation does.
 */
export function swiftJSONString(value: JSONValue, options: { pretty?: boolean; sortedKeys?: boolean } = {}): string {
  const { pretty = false, sortedKeys = false } = options
  const write = (item: JSONValue, indent: string): string => {
    if (item === null) return 'null'
    if (typeof item === 'boolean') return item ? 'true' : 'false'
    if (typeof item === 'number') return Number.isFinite(item) ? String(item) : 'null'
    if (typeof item === 'string') return JSON.stringify(item).replace(/\//g, '\\/')
    const inner = indent + '  '
    if (Array.isArray(item)) {
      if (item.length === 0) return '[]'
      const parts = item.map((element) => write(element, inner))
      return pretty ? `[\n${inner}${parts.join(`,\n${inner}`)}\n${indent}]` : `[${parts.join(',')}]`
    }
    let keys = Object.keys(item).filter((key) => item[key] !== undefined)
    if (keys.length === 0) return '{}'
    if (sortedKeys) keys = keys.sort(compareKeys)
    const separator = pretty ? ' : ' : ':'
    const parts = keys.map((key) => `${write(key, inner)}${separator}${write(item[key], inner)}`)
    return pretty ? `{\n${inner}${parts.join(`,\n${inner}`)}\n${indent}}` : `{${parts.join(',')}}`
  }
  return write(value, '')
}

/** Foundation's `.sortedKeys` order: case-insensitive, then exact. */
function compareKeys(a: string, b: string): number {
  const la = a.toLowerCase()
  const lb = b.toLowerCase()
  if (la !== lb) return la < lb ? -1 : 1
  return a < b ? -1 : a > b ? 1 : 0
}

// MARK: - ISO 8601

/**
 * `ISO8601DateFormatter` with `.withInternetDateTime`, as `.iso8601` writes it: UTC, whole seconds
 * (fractions are dropped, not rounded), e.g. `2026-09-25T15:00:05Z`.
 */
export function formatISO8601(ms: number): string {
  const whole = Math.floor(ms / 1000) * 1000
  return new Date(whole).toISOString().replace(/\.\d{3}Z$/, 'Z')
}

const isoPattern = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/i

/**
 * Parses what `.iso8601` writes ("…Z" or "…+03:00"). Swift refuses fractional seconds here; they are
 * accepted (and kept) so files from other tools still load.
 */
export function parseISO8601(text: string): number | null {
  const match = isoPattern.exec(text)
  if (!match) return null
  const [, y, mo, d, h, mi, s, fraction, zone] = match
  let ms = Date.UTC(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(s))
  if (fraction) ms += Number(fraction) * 1000
  if (zone.toUpperCase() !== 'Z') {
    const sign = zone.startsWith('-') ? -1 : 1
    const digits = zone.slice(1).replace(':', '')
    ms -= sign * (Number(digits.slice(0, 2)) * 60 + Number(digits.slice(2))) * 60_000
  }
  return Number.isFinite(ms) ? ms : null
}

// MARK: - UUID

/** A new random UUID in Swift's `uuidString` form (upper case). */
export function newUUID(): string {
  type WebCrypto = { randomUUID?: () => string; getRandomValues?: (array: Uint8Array) => Uint8Array }
  const crypto = (globalThis as { crypto?: WebCrypto }).crypto
  if (typeof crypto?.randomUUID === 'function') return crypto.randomUUID().toUpperCase()
  const bytes = new Uint8Array(16)
  if (typeof crypto?.getRandomValues === 'function') {
    crypto.getRandomValues(bytes)
  } else {
    for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256)
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('').toUpperCase()
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}

/** Two UUID strings name the same UUID (Swift compares the 16 bytes, so case does not matter). */
export function sameUUID(a: string, b: string): boolean {
  return a.toUpperCase() === b.toUpperCase()
}

// MARK: - Base64 and UTF-8

const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
const lookup = new Map(Array.from(alphabet, (char, index) => [char, index]))

/** `Data.base64EncodedString()`. */
export function base64Encode(bytes: Uint8Array): string {
  let out = ''
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i]
    const b = i + 1 < bytes.length ? bytes[i + 1] : 0
    const c = i + 2 < bytes.length ? bytes[i + 2] : 0
    const triple = (a << 16) | (b << 8) | c
    out += alphabet[(triple >> 18) & 63] + alphabet[(triple >> 12) & 63]
    out += i + 1 < bytes.length ? alphabet[(triple >> 6) & 63] : '='
    out += i + 2 < bytes.length ? alphabet[triple & 63] : '='
  }
  return out
}

/** `Data(base64Encoded:)`; `null` when the text is not base64. Padding is optional. */
export function base64Decode(text: string): Uint8Array | null {
  const body = text.replace(/=+$/, '')
  if (body.length % 4 === 1 || text.length - body.length > 2) return null
  const out = new Uint8Array(Math.floor((body.length * 3) / 4))
  let buffer = 0
  let bits = 0
  let index = 0
  for (const char of body) {
    const value = lookup.get(char)
    if (value === undefined) return null
    buffer = (buffer << 6) | value
    bits += 6
    if (bits >= 8) {
      bits -= 8
      out[index++] = (buffer >> bits) & 0xff
    }
  }
  return out
}

const encoder = new TextEncoder()
const decoder = new TextDecoder()

export function utf8Encode(text: string): Uint8Array {
  return encoder.encode(text)
}

/** `String(decoding: data, as: UTF8.self)`: invalid sequences become U+FFFD. */
export function utf8Decode(bytes: Uint8Array): string {
  return decoder.decode(bytes)
}

// MARK: - Equality

/** Structural equality of plain data (what Swift's synthesized `Equatable` compares). */
export function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true
  if (typeof a !== typeof b || a === null || b === null || typeof a !== 'object') return false
  if (a instanceof Uint8Array || b instanceof Uint8Array) {
    if (!(a instanceof Uint8Array && b instanceof Uint8Array) || a.length !== b.length) return false
    return a.every((byte, index) => byte === b[index])
  }
  if (Array.isArray(a) !== Array.isArray(b)) return false
  if (Array.isArray(a)) {
    const other = b as unknown[]
    return a.length === other.length && a.every((item, index) => deepEqual(item, other[index]))
  }
  const x = a as Record<string, unknown>
  const y = b as Record<string, unknown>
  const keys = new Set([...Object.keys(x), ...Object.keys(y)])
  for (const key of keys) {
    // A missing key and `null` are the same nil.
    const left = x[key] ?? null
    const right = y[key] ?? null
    if (!deepEqual(left, right)) return false
  }
  return true
}
