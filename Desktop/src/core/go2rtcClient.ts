// Port of Go2RTC/Go2RTCClient.swift: a thin async client for the go2rtc HTTP API (streams, the configured
// sources, the Xiaomi login with captcha and verification code, Mi Home cameras, camera settings over MIoT).
//
// Uses the global `fetch` (Node 24, Electron, browsers); another implementation (Electron's `net.fetch`,
// a test double) can be passed in the options.

import { base64Decode, base64Encode, utf8Decode, utf8Encode } from './codable'
import { MiotPropertyID, MiotValue, XiaomiCameraError } from './cameraModes'
import { coreLanguage, coreLocale, coreRegion, tr } from './localization'
import { splitLines, trimWhitespaces, trimWhitespacesAndNewlines } from './text'

// MARK: - Server

/** Connection parameters of a go2rtc server. `baseURL` ends with "/". */
export interface Go2RTCServer {
  baseURL: string
  username: string
  password: string
}

export const Go2RTCServer = {
  make(baseURL: string, username = '', password = ''): Go2RTCServer {
    return { baseURL, username, password }
  },

  hasCredentials(server: Go2RTCServer): boolean {
    return server.username !== ''
  },

  /** `Authorization: Basic …` value, when credentials are configured. */
  authorizationHeader(server: Go2RTCServer): string | null {
    if (!Go2RTCServer.hasCredentials(server)) return null
    return 'Basic ' + base64Encode(utf8Encode(`${server.username}:${server.password}`))
  },

  /** Base URL with the credentials embedded (`http://user:pass@host:1984/`) for the web player. */
  urlWithCredentials(server: Go2RTCServer): string {
    if (!Go2RTCServer.hasCredentials(server)) return server.baseURL
    try {
      const url = new URL(server.baseURL)
      url.username = server.username
      url.password = server.password
      return url.href
    } catch {
      return server.baseURL
    }
  },

  /** "192.168.1.5:1984" → "http://192.168.1.5:1984/"; `null` when it is not a URL with a host. */
  parse(text: string): string | null {
    let trimmed = trimWhitespacesAndNewlines(text)
    if (trimmed === '') return null
    if (!trimmed.includes('://')) trimmed = 'http://' + trimmed
    if (!trimmed.endsWith('/')) trimmed += '/'
    try {
      if (new URL(trimmed).hostname === '') return null
    } catch {
      return null
    }
    return trimmed
  },
}

// MARK: - Streams and sources

export interface Go2RTCStream {
  name: string
  sources: string[]
}

export const Go2RTCStream = {
  isXiaomi(stream: Go2RTCStream): boolean {
    return stream.sources.some((source) => source.startsWith('xiaomi://'))
  },
}

/**
 * The value of the query item `name` of a source URL (`xiaomi://…?did=…&model=…&subtype=hd`), read as
 * `URLComponents.queryItems` reads it: split at the first "=", percent-decoded, "+" left as is; `null` when the item
 * is missing, has no "=", or does not decode (a malformed escape).
 */
export function queryValue(source: string, name: string): string | null {
  const start = source.indexOf('?')
  if (start < 0) return null
  const end = source.indexOf('#', start)
  const query = source.slice(start + 1, end < 0 ? undefined : end)
  for (const item of query.split('&')) {
    const equals = item.indexOf('=')
    if (percentDecoded(equals < 0 ? item : item.slice(0, equals)) !== name) continue
    return equals < 0 ? null : percentDecoded(item.slice(equals + 1))
  }
  return null
}

function percentDecoded(text: string): string | null {
  try {
    return decodeURIComponent(text)
  } catch {
    return null
  }
}

/** A discoverable source returned by go2rtc (`/api/xiaomi?id=…`); `url` is its id. */
export interface Go2RTCSource {
  name: string
  info: string | null
  url: string
}

export type XiaomiLoginStep =
  | { kind: 'success' }
  /** A captcha image (PNG/JPEG bytes) must be solved and sent back via `xiaomiSubmitCaptcha`. */
  | { kind: 'captcha'; image: Uint8Array }
  /** A verification code was sent to the masked phone/email; send it back via `xiaomiSubmitVerify`. */
  | { kind: 'verify'; phone: string | null; email: string | null }

export type XiaomiRegion = 'cn' | 'ru' | 'de' | 'us' | 'sg' | 'i2'

export const XiaomiRegion = {
  allCases: ['cn', 'ru', 'de', 'us', 'sg', 'i2'] as readonly XiaomiRegion[],

  title(region: XiaomiRegion): string {
    switch (region) {
      case 'cn':
        return tr('China (default)', 'Китай (по умолчанию)')
      case 'ru':
        return tr('Russia', 'Россия')
      case 'de':
        return tr('Europe (de)', 'Европа (de)')
      case 'us':
        return tr('United States', 'США')
      case 'sg':
        return tr('Singapore', 'Сингапур')
      case 'i2':
        return tr('India', 'Индия')
    }
  },

  /** The Mi Home server region most likely for this device's region (the user can change it). */
  suggested(): XiaomiRegion {
    const region = coreRegion()
    if (!region) return coreLanguage() === 'ru' ? 'ru' : 'de'
    switch (region) {
      case 'RU':
      case 'BY':
      case 'KZ':
      case 'KG':
      case 'AM':
      case 'UZ':
      case 'TJ':
        return 'ru'
      case 'CN':
      case 'HK':
      case 'MO':
      case 'TW':
        return 'cn'
      case 'US':
      case 'CA':
      case 'MX':
      case 'BR':
      case 'AR':
      case 'CL':
      case 'CO':
      case 'PE':
        return 'us'
      case 'IN':
        return 'i2'
      case 'SG':
      case 'MY':
      case 'ID':
      case 'TH':
      case 'VN':
      case 'PH':
      case 'AU':
      case 'NZ':
      case 'JP':
      case 'KR':
        return 'sg'
      default:
        return 'de'
    }
  },
}

// MARK: - Errors

export type Go2RTCErrorKind = 'invalidURL' | 'http' | 'decoding' | 'noSources' | 'network'

/**
 * `Go2RTCError`. `network` is TS-only: fetch failures and timeouts (Swift lets `URLError` through), with the
 * underlying message.
 */
export class Go2RTCError extends Error {
  /** HTTP status (`http`). */
  readonly status: number | null
  /** Response body (`http`), what could not be read (`decoding`), the failure (`network`). */
  readonly detail: string

  private constructor(
    readonly kind: Go2RTCErrorKind,
    status: number | null,
    detail: string,
    options?: { cause?: unknown },
  ) {
    super('', options)
    this.name = 'Go2RTCError'
    this.status = status
    this.detail = detail
    this.message = this.errorDescription
  }

  static invalidURL(): Go2RTCError {
    return new Go2RTCError('invalidURL', null, '')
  }
  static http(status: number, message: string): Go2RTCError {
    return new Go2RTCError('http', status, message)
  }
  static decoding(what: string): Go2RTCError {
    return new Go2RTCError('decoding', null, what)
  }
  static noSources(): Go2RTCError {
    return new Go2RTCError('noSources', null, '')
  }
  static network(message: string, cause?: unknown): Go2RTCError {
    return new Go2RTCError('network', null, message, { cause })
  }

  /** The text in the current language (`message` is fixed when the error is made). */
  get errorDescription(): string {
    switch (this.kind) {
      case 'invalidURL':
        return tr('Invalid server address', 'Некорректный адрес сервера')
      case 'http': {
        const text = trimWhitespacesAndNewlines(this.detail)
        return text === ''
          ? tr(`The server answered HTTP ${this.status}`, `Сервер ответил HTTP ${this.status}`)
          : `HTTP ${this.status}: ${text}`
      }
      case 'decoding':
        return tr(`Couldn't read the server's response (${this.detail})`, `Не удалось разобрать ответ сервера (${this.detail})`)
      case 'noSources':
        return tr('No cameras found', 'Камеры не найдены')
      case 'network':
        return this.detail
    }
  }

  equals(other: unknown): boolean {
    return (
      other instanceof Go2RTCError && other.kind === this.kind && other.status === this.status && other.detail === this.detail
    )
  }
}

// MARK: - Client

export interface Go2RTCClientOptions {
  /** Defaults to the global `fetch`. */
  fetch?: typeof globalThis.fetch
  /** Per request, including the body; 20 s like the Swift client. Mi Cloud calls get `cloudTimeoutMs`. */
  timeoutMs?: number
}

interface MiotResult {
  siid: number
  piid: number
  code: number
  value: MiotValue | null
}

/** Thin async client for the go2rtc HTTP API. */
export class Go2RTCClient {
  /**
   * Deadline of the requests go2rtc answers only after talking to Mi Cloud (signing in, listing cameras): an account
   * with shared homes takes page after page there, well past `timeoutMs`.
   */
  static readonly cloudTimeoutMs = 90_000

  private readonly fetchImpl: typeof globalThis.fetch
  private readonly timeoutMs: number

  constructor(
    readonly server: Go2RTCServer,
    options: Go2RTCClientOptions = {},
  ) {
    this.fetchImpl = options.fetch ?? ((input, init) => globalThis.fetch(input, init))
    this.timeoutMs = options.timeoutMs ?? 20_000
  }

  // MARK: - URLs

  /** `baseURL` + `path` with the query items (percent-encoded). */
  url(path: string, query: Record<string, string> = {}): string {
    return Go2RTCClient.buildURL(this.server.baseURL, path, query)
  }

  /** WebSocket endpoint used by go2rtc's `video-rtc.js` player (credentials embedded). */
  playerSocketURL(stream: string): string {
    const url = new URL(Go2RTCClient.buildURL(Go2RTCServer.urlWithCredentials(this.server), 'api/ws', { src: stream }))
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
    return url.href
  }

  playerScriptURL(): string {
    return Go2RTCClient.buildURL(Go2RTCServer.urlWithCredentials(this.server), 'video-rtc.js')
  }

  /**
   * Progressive MP4 stream suitable for saving straight to a file.
   * The camera's sound is taken as is: go2rtc cannot transcode without ffmpeg, but it stores
   * Opus untouched and turns PCMA/PCMU into FLAC. The app converts that audio to AAC after
   * recording (Photos and most players only accept AAC in MP4).
   */
  mp4URL(stream: string): string {
    return this.url('api/stream.mp4', { src: stream, video: 'h264,h265', audio: 'aac,opus,pcma,pcmu' })
  }

  hlsURL(stream: string): string {
    return this.url('api/stream.m3u8', { src: stream })
  }

  snapshotURL(stream: string): string {
    return this.url('api/frame.jpeg', { src: stream })
  }

  // MARK: - Server

  /** Returns the server version (or an empty string for very old builds). Throws when unreachable. */
  async version(): Promise<string> {
    const object = this.parseJSON(await this.request('GET', 'api'), 'version')
    return isRecord(object) && typeof object.version === 'string' ? object.version : ''
  }

  // MARK: - Streams

  async streams(): Promise<Go2RTCStream[]> {
    const object = this.parseJSON(await this.request('GET', 'api/streams'), 'streams')
    if (!isRecord(object)) throw Go2RTCError.decoding('streams')
    const result: Go2RTCStream[] = []
    for (const [name, value] of Object.entries(object)) {
      let sources: string[] = []
      if (isRecord(value) && Array.isArray(value.producers) && value.producers.every(isRecord)) {
        sources = value.producers.flatMap((producer) => (typeof producer.url === 'string' ? [producer.url] : []))
      }
      result.push({ name, sources })
    }
    const collator = new Intl.Collator(coreLocale(), { sensitivity: 'accent' })
    return result.sort((a, b) => collator.compare(a.name, b.name))
  }

  /** `GET /api/streams?src=<name>`: the stream's producers and consumers as go2rtc reports them (diagnostics). */
  async streamInfo(name: string): Promise<string> {
    return utf8Decode(await this.request('GET', 'api/streams', { src: name }))
  }

  async addStream(name: string, source: string): Promise<void> {
    await this.request('PUT', 'api/streams', { name, src: source })
  }

  async deleteStream(name: string): Promise<void> {
    await this.request('DELETE', 'api/streams', { src: name })
  }

  /**
   * Sources of `stream` as written in the server's config file (`GET /api/config`).
   * Needed while the stream is live: `/api/streams` then describes the running connection
   * instead of the configured source URL.
   */
  async configuredSources(stream: string): Promise<string[]> {
    const yaml = utf8Decode(await this.request('GET', 'api/config'))
    return Go2RTCClient.streamSources(yaml, stream)
  }

  /** Sources of several streams from one read of the config file. */
  async configuredSourcesOf(streams: readonly string[]): Promise<Record<string, string[]>> {
    const yaml = utf8Decode(await this.request('GET', 'api/config'))
    return Object.fromEntries(streams.map((name) => [name, Go2RTCClient.streamSources(yaml, name)]))
  }

  /**
   * Reads one stream from the `streams:` section of a go2rtc YAML config. Handles the forms
   * go2rtc itself writes (`name: url`, a block list under `name:`) and a flow list `[a, b]`.
   */
  static streamSources(yaml: string, stream: string): string[] {
    const unquote = (text: string): string => {
      let value = trimWhitespaces(text)
      const first = value[0]
      if (value.length >= 2 && first === value[value.length - 1] && (first === '"' || first === "'")) {
        value = value.slice(1, -1)
      }
      return value
    }

    let inStreams = false
    let currentKey: string | null = null
    const sources: string[] = []
    for (const line of splitLines(yaml)) {
      const trimmed = trimWhitespaces(line)
      // Only whole-line comments: `#` is legal inside source URLs (`ffmpeg:…#video=h264`).
      if (trimmed === '' || trimmed.startsWith('#')) continue
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        inStreams = trimmed === 'streams:'
        currentKey = null
        continue
      }
      if (!inStreams) continue
      if (trimmed === '-' || trimmed.startsWith('- ')) {
        const item = unquote(trimmed.slice(1))
        if (currentKey === stream && item !== '') sources.push(item)
        continue
      }
      const colon = trimmed.indexOf(':')
      if (colon < 0) continue
      const key = unquote(trimmed.slice(0, colon))
      const value = trimWhitespaces(trimmed.slice(colon + 1))
      currentKey = key
      if (key !== stream || value === '') continue
      if (value.startsWith('[') && value.endsWith(']')) {
        sources.push(
          ...value
            .slice(1, -1)
            .split(',')
            .map(unquote)
            .filter((item) => item !== ''),
        )
      } else {
        sources.push(unquote(value))
      }
    }
    return sources
  }

  // MARK: - Xiaomi

  /** Xiaomi account IDs already authorised on the server. */
  async xiaomiAccounts(): Promise<string[]> {
    const list = this.parseJSON(await this.request('GET', 'api/xiaomi'), 'xiaomi accounts')
    if (!Array.isArray(list) || !list.every((item) => typeof item === 'string')) {
      throw Go2RTCError.decoding('xiaomi accounts')
    }
    return [...(list as string[])].sort()
  }

  xiaomiLogin(username: string, password: string): Promise<XiaomiLoginStep> {
    return this.xiaomiAuth({ username, password })
  }

  xiaomiSubmitCaptcha(code: string): Promise<XiaomiLoginStep> {
    return this.xiaomiAuth({ captcha: code })
  }

  xiaomiSubmitVerify(code: string): Promise<XiaomiLoginStep> {
    return this.xiaomiAuth({ verify: code })
  }

  /**
   * Forgets a Mi Home account: go2rtc drops its token from memory and from its config
   * (`POST /api/xiaomi/logout`, a Waiting Paws addition — another go2rtc answers 404).
   */
  async xiaomiLogout(accountID: string): Promise<void> {
    const { status, body } = await this.send('POST', this.url('api/xiaomi/logout'), { id: accountID })
    if (status < 200 || status >= 300) throw Go2RTCError.http(status, utf8Decode(body))
  }

  /**
   * Cameras of the given account, as ready-to-use `xiaomi://` sources. Asks `/api/xiaomi/cameras` (a Waiting
   * Paws addition that also lists homes shared with the account), another go2rtc answers 404 there and is
   * asked `/api/xiaomi` (own and one-by-one shared devices only).
   */
  async xiaomiCameras(accountID: string, region: XiaomiRegion): Promise<Go2RTCSource[]> {
    const query = { id: accountID, region }
    let data: Uint8Array
    try {
      data = await this.request('GET', 'api/xiaomi/cameras', query, Go2RTCClient.cloudTimeoutMs)
    } catch (error) {
      if (!isNotFound(error)) throw error
      try {
        data = await this.request('GET', 'api/xiaomi', query, Go2RTCClient.cloudTimeoutMs)
      } catch (fallbackError) {
        if (isNotFound(fallbackError)) throw Go2RTCError.noSources()
        throw fallbackError
      }
    }
    const object = this.parseJSON(data, 'xiaomi sources')
    if (!isRecord(object) || !Array.isArray(object.sources) || !object.sources.every(isRecord)) {
      throw Go2RTCError.decoding('xiaomi sources')
    }
    const cameras = object.sources.flatMap((item): Go2RTCSource[] => {
      if (typeof item.url !== 'string') return []
      return [
        {
          name: typeof item.name === 'string' ? item.name : item.url,
          info: typeof item.info === 'string' ? item.info : null,
          url: item.url,
        },
      ]
    })
    if (cameras.length === 0) throw Go2RTCError.noSources()
    return cameras
  }

  // MARK: - Xiaomi camera settings

  /**
   * Current values of camera settings, through the app's go2rtc (`POST /api/xiaomi/miot`, a Waiting Paws
   * addition — another go2rtc answers 404), keyed by `MiotPropertyID.description` ("2.3"). Properties the
   * camera did not report are left out; when it reported none, the camera's error is thrown.
   */
  async xiaomiProperties(source: string, ids: readonly MiotPropertyID[]): Promise<Record<string, MiotValue>> {
    if (ids.length === 0) return {}
    const params = ids.map((id) => ({ siid: id.siid, piid: id.piid }))
    const results = await this.miot(source, 'get', params)
    const values: Record<string, MiotValue> = {}
    let firstError: unknown = null
    for (const result of results) {
      try {
        XiaomiCameraError.check(result.code)
        if (result.value !== null) values[MiotPropertyID.description(result)] = result.value
      } catch (error) {
        firstError ??= error
      }
    }
    if (Object.keys(values).length === 0 && firstError !== null) throw firstError
    return values
  }

  /** Changes one camera setting (night mode, image flip…). */
  async setXiaomiProperty(source: string, id: MiotPropertyID, value: MiotValue): Promise<void> {
    const results = await this.miot(source, 'set', [{ siid: id.siid, piid: id.piid, value }])
    const result = results[0]
    if (!result) throw Go2RTCError.decoding('xiaomi miot')
    XiaomiCameraError.check(result.code)
  }

  private async miot(source: string, method: string, params: unknown[]): Promise<MiotResult[]> {
    const form = { src: source, method, params: JSON.stringify(params) }
    const { status, body } = await this.send('POST', this.url('api/xiaomi/miot'), form)
    if (status < 200 || status >= 300) throw Go2RTCError.http(status, utf8Decode(body))
    const list = this.parseJSON(body, 'xiaomi miot')
    if (!Array.isArray(list)) throw Go2RTCError.decoding('xiaomi miot')
    return list.map((item) => {
      if (!isRecord(item) || !isInt(item.siid) || !isInt(item.piid)) throw Go2RTCError.decoding('xiaomi miot')
      let value: MiotValue | null = null
      // String properties (time ranges…) are not settings the app shows.
      try {
        if (item.value !== undefined && item.value !== null) value = MiotValue.decode(item.value)
      } catch {
        value = null
      }
      return { siid: item.siid, piid: item.piid, code: isInt(item.code) ? item.code : 0, value }
    })
  }

  private async xiaomiAuth(form: Record<string, string>): Promise<XiaomiLoginStep> {
    const { status, body } = await this.send('POST', this.url('api/xiaomi'), form, Go2RTCClient.cloudTimeoutMs)
    if (status >= 200 && status < 300) return { kind: 'success' }
    if (status !== 401) throw Go2RTCError.http(status, utf8Decode(body))

    let object: unknown
    try {
      object = JSON.parse(utf8Decode(body))
    } catch {
      object = null
    }
    if (!isRecord(object)) throw Go2RTCError.http(status, utf8Decode(body))
    if (typeof object.captcha === 'string') {
      const image = base64Decode(object.captcha)
      if (image) return { kind: 'captcha', image }
    }
    const phone = typeof object.verify_phone === 'string' ? object.verify_phone : null
    const email = typeof object.verify_email === 'string' ? object.verify_email : null
    if (phone !== null || email !== null) {
      return { kind: 'verify', phone: phone || null, email: email || null }
    }
    throw Go2RTCError.http(
      status,
      tr('Xiaomi rejected the sign-in: check the login and password', 'Xiaomi отклонил вход: проверьте логин и пароль'),
    )
  }

  // MARK: - Plumbing

  private async request(method: string, path: string, query: Record<string, string> = {}, timeoutMs = this.timeoutMs): Promise<Uint8Array> {
    const { status, body } = await this.send(method, this.url(path, query), undefined, timeoutMs)
    if (status < 200 || status >= 300) throw Go2RTCError.http(status, utf8Decode(body))
    return body
  }

  /** One HTTP exchange; `form` is sent as `application/x-www-form-urlencoded`. */
  private async send(
    method: string,
    url: string,
    form?: Record<string, string>,
    timeoutMs = this.timeoutMs,
  ): Promise<{ status: number; body: Uint8Array }> {
    const headers: Record<string, string> = {}
    const authorization = Go2RTCServer.authorizationHeader(this.server)
    if (authorization) headers.Authorization = authorization
    let body: string | undefined
    if (form) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded'
      body = Go2RTCClient.formEncode(form)
    }
    try {
      const response = await this.fetchImpl(url, {
        method,
        headers,
        body,
        signal: AbortSignal.timeout(timeoutMs),
      })
      return { status: response.status, body: new Uint8Array(await response.arrayBuffer()) }
    } catch (error) {
      throw Go2RTCError.network(networkMessage(error), error)
    }
  }

  private parseJSON(data: Uint8Array, what: string): unknown {
    try {
      return JSON.parse(utf8Decode(data))
    } catch {
      throw Go2RTCError.decoding(what)
    }
  }

  /** `application/x-www-form-urlencoded` body: everything but ASCII letters, digits and `-._~` is percent-encoded. */
  static formEncode(form: Record<string, string>): string {
    return Object.entries(form)
      .map(([key, value]) => `${percentEncode(key)}=${percentEncode(value)}`)
      .join('&')
  }

  /** `base` + `path` (as `appendingPathComponent`) + percent-encoded query items. */
  static buildURL(base: string, path: string, query: Record<string, string> = {}): string {
    const url = new URL(base)
    const prefix = url.pathname.endsWith('/') ? url.pathname : url.pathname + '/'
    url.pathname = prefix + path.replace(/^\/+/, '')
    const items = Object.entries(query)
    url.search = items.length === 0 ? '' : '?' + items.map(([k, v]) => `${percentEncode(k)}=${percentEncode(v)}`).join('&')
    url.hash = ''
    return url.href
  }

  /**
   * Stream name for a camera: "Гостиная" → "gostinaa" style ASCII slug (ICU `Any-Latin` + strip diacritics
   * as on the Mac; Cyrillic is transliterated like ICU, other scripts only lose their accents).
   */
  static streamName(cameraName: string): string {
    const ascii = transliterateCyrillic(cameraName).normalize('NFD').replace(/\p{Mn}/gu, '').normalize('NFC')
    let slug = ''
    let lastWasDash = false
    for (const char of ascii.toLowerCase()) {
      if (/^[a-z0-9]$/.test(char)) {
        slug += char
        lastWasDash = false
      } else if (!lastWasDash && slug !== '') {
        slug += '-'
        lastWasDash = true
      }
    }
    slug = slug.replace(/-+$/, '')
    return slug === '' ? 'camera' : slug
  }
}

// MARK: - Helpers

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isInt(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value)
}

function isNotFound(error: unknown): boolean {
  return error instanceof Go2RTCError && error.kind === 'http' && error.status === 404
}

function networkMessage(error: unknown): string {
  if (error instanceof Error) {
    const cause = (error as { cause?: unknown }).cause
    if (cause instanceof Error && cause.message) return `${error.message}: ${cause.message}`
    return error.message
  }
  return String(error)
}

/** RFC 3986 unreserved characters stay, everything else is UTF-8 percent-encoded. */
function percentEncode(text: string): string {
  return encodeURIComponent(text).replace(/[!'()*]/g, (char) => '%' + char.charCodeAt(0).toString(16).toUpperCase())
}

/**
 * ICU's Cyrillic-Latin (ISO 9) letters, lower case. `ђ` → `đ`, `ъ` → `ʺ` and `ь` → `ʹ` are not ASCII
 * letters even after stripping accents, so they end up as separators, as on the Mac.
 */
const cyrillicToLatin: Record<string, string> = {
  а: 'a', б: 'b', в: 'v', г: 'g', ґ: 'g̀', д: 'd', ѓ: 'ǵ', ђ: 'đ', е: 'e', є: 'ê',
  ё: 'ë', ж: 'ž', з: 'z', ѕ: 'ẑ', и: 'i', і: 'ì', ї: 'ï', й: 'j',
  ј: 'ǰ', к: 'k', ќ: 'ḱ', л: 'l', љ: 'l̂', м: 'm', н: 'n', њ: 'n̂', о: 'o',
  п: 'p', р: 'r', с: 's', т: 't', ћ: 'ć', у: 'u', ў: 'ŭ', ф: 'f', х: 'h', ц: 'c',
  ч: 'č', џ: 'd̂', ш: 'š', щ: 'ŝ', ъ: 'ʺ', ы: 'y', ь: 'ʹ', э: 'è',
  ю: 'û', я: 'â',
}

function transliterateCyrillic(text: string): string {
  let out = ''
  for (const char of text.normalize('NFC')) {
    const lower = char.toLowerCase()
    const latin = cyrillicToLatin[lower]
    out += latin === undefined ? char : lower === char ? latin : latin.toUpperCase()
  }
  return out
}
