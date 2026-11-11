// What go2rtc already knows: signed-in Mi Home accounts with their cameras (own and shared homes) and the registered
// streams. Shared by the welcome page and the camera picker; choosing a camera registers its stream and saves it.
// Port of the Mac app's `SetupCameraCatalog` (+ the text helpers of `SetupText`).
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Go2RTCClient, Go2RTCError, Go2RTCServer, queryValue as sourceQueryValue, type Go2RTCSource, type Go2RTCStream, type XiaomiRegion } from '@core/go2rtcClient'
import type { Settings } from '@shared/settings'
import { t } from '@shared/i18n'
import { bridgeFetch } from '../platform/bridge'
import { useStore } from '../store'
import { adoptPreview, cancelPreview, removeLeftoverPreviews } from './stills'

// MARK: - Models

/// A Mi Home camera of a signed-in account. `streamName`: the go2rtc stream that already plays it.
export interface CatalogCamera {
  source: Go2RTCSource
  accountID: string
  region: XiaomiRegion
  streamName: string | null
}

export interface CatalogAccount {
  id: string
  region: XiaomiRegion
  cameras: CatalogCamera[]
  /// The camera list could not be fetched (token expired, wrong region…).
  error: string | null
}

export type Choice = { kind: 'camera'; camera: CatalogCamera } | { kind: 'stream'; stream: Go2RTCStream }

/// Prefix of the short-lived go2rtc streams that fetch a preview of a Mi Home camera go2rtc does not play yet
/// (`stills.ts`). They are left out of every list and never saved as the app's camera.
export const PREVIEW_PREFIX = '__wp_preview_'

export function isPreviewStream(name: string): boolean {
  return name.startsWith(PREVIEW_PREFIX)
}

export function streamID(name: string): string {
  return `stream|${name}`
}

export function cameraID(camera: CatalogCamera): string {
  return `camera|${camera.accountID}|${camera.source.url}`
}

export function choiceID(choice: Choice): string {
  return choice.kind === 'camera' ? cameraID(choice.camera) : streamID(choice.stream.name)
}

/// `name=value` from the query of a source URL (`xiaomi://…?did=…&model=…`), as the core reads it.
export function queryValue(name: string, source: string): string | null {
  return sourceQueryValue(source, name)
}

/// Host of `scheme://user:pass@host:port/path?query`, `null` when there is none.
function sourceHost(source: string): string | null {
  const match = /^[a-z][a-z0-9+.-]*:\/\/([^/?#]*)/i.exec(source)
  if (!match) return null
  const authority = match[1]
  const host = authority.slice(authority.lastIndexOf('@') + 1).replace(/:\d*$/, '')
  return host === '' ? null : host
}

export const Camera = {
  /// Mi Home model id from the source URL ("chuangmi.camera.069a01"): for tooltips only.
  model: (camera: CatalogCamera) => queryValue('model', camera.source.url),
  deviceID: (camera: CatalogCamera) => queryValue('did', camera.source.url),
  /// The camera's address in the home network, which go2rtc dials. Mi Home gives none for a camera that is
  /// offline: no preview is tried then.
  host: (camera: CatalogCamera) => sourceHost(camera.source.url),
  /// «Камера Xiaomi» instead of "chuangmi.camera.039a01".
  kind: (camera: CatalogCamera) => cameraKind(Camera.model(camera)),
  /// Tooltip with what the readable text leaves out: the Mi Home model id and the address.
  technicalDetails(camera: CatalogCamera): string {
    const model = Camera.model(camera)
    const host = Camera.host(camera)
    return [model ? t('Mi Home model: %@', model) : null, host ? `IP ${host}` : null].filter(Boolean).join(' · ')
  },
}

// MARK: - Texts

const cameraVendors: Record<string, string> = {
  xiaomi: 'Xiaomi',
  mijia: 'Xiaomi',
  chuangmi: 'Xiaomi',
  isa: 'Xiaomi',
  xiaovv: 'Xiaovv',
  lumi: 'Aqara',
}

/// "chuangmi.camera.039a01" → «Камера Xiaomi»: the device type and the maker from the Mi Home model id. Only makers
/// that are certain; anything else is «Камера Mi Home».
export function cameraKind(model: string | null): string {
  const parts = (model ?? '').toLowerCase().split('.')
  const peephole = parts.length > 1 && parts[1] === 'cateye'
  const vendor = parts[0] ? cameraVendors[parts[0]] : undefined
  if (!vendor) return peephole ? t('Mi Home Peephole Camera') : t('Mi Home Camera')
  return peephole ? t('%@ Peephole Camera', vendor) : t('%@ Camera', vendor)
}

/// "rtsp://192.168.1.20:554/live" → "RTSP"; Mi Home sources → "Mi Home".
export function sourceBadge(source: string | undefined): string | null {
  if (!source || !source.includes(':')) return null
  const scheme = source.split(':')[0].toLowerCase()
  if (!scheme) return null
  switch (scheme) {
    case 'xiaomi':
      return 'Mi Home'
    case 'rtsp':
    case 'rtsps':
    case 'rtspx':
      return 'RTSP'
    case 'onvif':
      return 'ONVIF'
    case 'http':
    case 'https':
      return 'HTTP'
    case 'ffmpeg':
      return 'FFmpeg'
    case 'exec':
      return 'exec'
    case 'homekit':
      return 'HomeKit'
    default:
      return scheme.toUpperCase()
  }
}

/// A source without its password ("rtsp://admin:secret@cam/live" → "rtsp://admin@cam/live").
export function redacted(source: string): string {
  return source.replace(/^([a-z][a-z0-9+.-]*:\/\/)([^:@/?#]*):([^@/?#]*)@/i, '$1$2@')
}

/// The first source of a stream as the list shows it.
export function streamDetail(stream: Go2RTCStream): string {
  return stream.sources[0] ? redacted(stream.sources[0]) : t('No source specified')
}

/// "1920×1080". H.265 streams report the coded height (1088 for 1080p): within a macroblock of 16:9 it is rounded.
export function pixels(width: number, height: number): string {
  const w = Math.round(width)
  let h = Math.round(height)
  if (w % 16 === 0 && Math.abs(h - Math.floor((w * 9) / 16)) <= 8) h = Math.floor((w * 9) / 16)
  return `${w}×${h}`
}

/// Mi account regions in the order people in Russia look for them, with the Mac app's short titles.
export const REGIONS: XiaomiRegion[] = ['ru', 'de', 'cn', 'us', 'sg', 'i2']

export function regionTitle(region: XiaomiRegion): string {
  switch (region) {
    case 'ru':
      return t('Russia')
    case 'de':
      return t('Europe')
    case 'cn':
      return t('China')
    case 'us':
      return t('United States')
    case 'sg':
      return t('Singapore')
    case 'i2':
      return t('India')
  }
}

/// "192.168.1.10:1984" from a base URL.
export function hostText(baseURL: string): string {
  try {
    return new URL(baseURL).host || baseURL
  } catch {
    return baseURL
  }
}

/// A message for the user from whatever was thrown (without the IPC wrapping of errors the backend made).
export function errorText(error: unknown): string {
  const text = error instanceof Go2RTCError ? error.errorDescription : error instanceof Error ? error.message : String(error)
  return text.replace(/^Error invoking remote method '[^']+': /, '').replace(/^(TypeError|Error): /, '')
}

/// The request did not reach the server (refused, timed out, not allowed), as opposed to an answer it gave.
export function isUnreachable(error: unknown): boolean {
  return error instanceof Go2RTCError && error.kind === 'network'
}

// MARK: - The server the setup screens talk to

export interface SetupServer {
  /// The active go2rtc (credentials are added by the backend), `null` without one.
  server: Go2RTCServer | null
  client: Go2RTCClient | null
  /// Whether the go2rtc API may be queried right now.
  ready: boolean
  embedded: boolean
  /// What the lists depend on: the server and whether it runs.
  key: string
}

export function useSetupServer(): SetupServer {
  const app = useStore((store) => store.app)!
  const baseURL = app.server?.baseURL ?? null
  const embedded = app.settings.connectionMode === 'embedded'
  const ready = baseURL !== null && (embedded ? app.go2rtc.status === 'running' : true)
  const client = useMemo(() => (baseURL ? new Go2RTCClient(Go2RTCServer.make(baseURL), { fetch: bridgeFetch }) : null), [baseURL])
  return {
    server: client?.server ?? null,
    client,
    ready,
    embedded,
    key: `${app.settings.connectionMode}|${baseURL ?? '-'}|${app.settings.serverUsername}|${ready}`,
  }
}

// MARK: - Loading

export type CatalogPhase = { kind: 'idle' } | { kind: 'waiting' } | { kind: 'loading' } | { kind: 'ready' } | { kind: 'failed'; message: string }

export interface CatalogData {
  accounts: CatalogAccount[]
  streams: Go2RTCStream[]
  serverVersion: string | null
}

/// Reads accounts, cameras and streams. `account` limits the Mi Home part to one account (right after a sign-in).
export async function loadCatalog(client: Go2RTCClient, region: XiaomiRegion, account: string | null): Promise<CatalogData> {
  const serverVersion = await client.version()
  const streamsTask = loadStreams(client)
  // A server without the xiaomi module answers 404 here: simply no accounts.
  const ids = await client.xiaomiAccounts().catch(() => [] as string[])
  const wanted = account ? [account] : ids
  const loaded = await Promise.all(
    wanted.map(async (id): Promise<CatalogAccount> => {
      try {
        const sources = await client.xiaomiCameras(id, region)
        return { id, region, cameras: sources.map((source) => ({ source, accountID: id, region, streamName: null })), error: null }
      } catch (error) {
        if (error instanceof Go2RTCError && error.kind === 'noSources') return { id, region, cameras: [], error: null }
        return { id, region, cameras: [], error: errorText(error) }
      }
    }),
  )
  const all = await streamsTask
  // Preview streams of a closed or crashed preview: not the user's, removed quietly.
  removeLeftoverPreviews(
    client,
    all.map((stream) => stream.name),
  )
  const streams = all.filter((stream) => !isPreviewStream(stream.name))
  const accounts = loaded.map((item) => ({
    ...item,
    cameras: item.cameras.map((camera) => ({ ...camera, streamName: streamFor(camera, streams)?.name ?? null })),
  }))
  return { accounts, streams, serverVersion }
}

/// `/api/streams` describes a live stream by its connection, without the source URL: those sources come from the
/// config file instead (needed to match Mi Home cameras to streams).
async function loadStreams(client: Go2RTCClient): Promise<Go2RTCStream[]> {
  let streams: Go2RTCStream[]
  try {
    streams = await client.streams()
  } catch {
    return []
  }
  const missing = streams.filter((stream) => stream.sources.length === 0 && !isPreviewStream(stream.name)).map((stream) => stream.name)
  if (missing.length === 0) return streams
  const configured = await client.configuredSourcesOf(missing).catch(() => ({}) as Record<string, string[]>)
  return streams.map((stream) => (configured[stream.name]?.length ? { name: stream.name, sources: configured[stream.name] } : stream))
}

/// go2rtc stream whose source is this Mi Home camera (same device id).
function streamFor(camera: CatalogCamera, streams: Go2RTCStream[]): Go2RTCStream | undefined {
  const did = Camera.deviceID(camera)
  if (!did) return streams.find((stream) => stream.sources.includes(camera.source.url))
  return streams.find((stream) => stream.sources.some((source) => queryValue('did', source) === did))
}

/// Streams that are not one of the listed Mi Home cameras.
export function otherStreams(data: CatalogData): Go2RTCStream[] {
  const deviceIDs = new Set(data.accounts.flatMap((account) => account.cameras.map(Camera.deviceID)).filter((id): id is string => id !== null))
  return data.streams.filter((stream) => !stream.sources.some((source) => deviceIDs.has(queryValue('did', source) ?? '')))
}

export function findChoice(data: CatalogData, id: string | null): Choice | null {
  if (!id) return null
  for (const account of data.accounts) {
    const camera = account.cameras.find((item) => cameraID(item) === id)
    if (camera) return { kind: 'camera', camera }
  }
  const stream = data.streams.find((item) => streamID(item.name) === id)
  return stream ? { kind: 'stream', stream } : null
}

/// Selection id of the camera the app uses now.
export function currentID(data: CatalogData, settings: Settings): string | null {
  const name = settings.streamName
  if (!name) return null
  for (const account of data.accounts) {
    const camera = account.cameras.find((item) => item.streamName === name)
    if (camera) return cameraID(camera)
  }
  return data.streams.some((stream) => stream.name === name) ? streamID(name) : null
}

export interface Catalog extends CatalogData {
  phase: CatalogPhase
  /// A refresh is running while the old content stays on screen.
  refreshing: boolean
  reload(): Promise<CatalogData | null>
}

const emptyData: CatalogData = { accounts: [], streams: [], serverVersion: null }

/// The catalog of the active server, loaded when it becomes ready and whenever it changes. `account` limits the
/// Mi Home part to one account, `region` overrides the settings' region (right after a sign-in).
export function useCatalog(setup: SetupServer, options: { account?: string | null; region?: XiaomiRegion | null } = {}): Catalog {
  const settingsRegion = useStore((store) => store.app!.settings.xiaomiRegion)
  const region = options.region ?? settingsRegion
  const account = options.account ?? null
  const [data, setData] = useState<CatalogData>(emptyData)
  const [phase, setPhase] = useState<CatalogPhase>({ kind: 'idle' })
  const [refreshing, setRefreshing] = useState(false)
  const generation = useRef(0)
  const phaseRef = useRef(phase)
  phaseRef.current = phase

  const { client, ready } = setup
  const reload = useCallback(async (): Promise<CatalogData | null> => {
    const current = ++generation.current
    if (!ready || !client) {
      setPhase({ kind: 'waiting' })
      setData(emptyData)
      return null
    }
    if (phaseRef.current.kind === 'ready') setRefreshing(true)
    else setPhase({ kind: 'loading' })
    try {
      const loaded = await loadCatalog(client, region, account)
      if (current !== generation.current) return null
      setData(loaded)
      setPhase({ kind: 'ready' })
      return loaded
    } catch (error) {
      if (current !== generation.current) return null
      setData(emptyData)
      setPhase({
        kind: 'failed',
        message: isUnreachable(error) ? `${t('%@ is not responding', hostText(client.server.baseURL))} (${errorText(error)})` : errorText(error),
      })
      return null
    } finally {
      if (current === generation.current) setRefreshing(false)
    }
  }, [client, ready, region, account])

  useEffect(() => {
    // Settings may be editing the server address: wait until the typing stops.
    const timer = window.setTimeout(() => void reload(), phaseRef.current.kind === 'idle' ? 0 : 500)
    return () => window.clearTimeout(timer)
  }, [reload, setup.key])

  return { ...data, phase, refreshing, reload }
}

// MARK: - Choosing

/// Registers the camera's stream in go2rtc when needed and returns the settings that make it the app's camera
/// (for `streams.select`).
export async function prepareChoice(choice: Choice, client: Go2RTCClient): Promise<Partial<Settings>> {
  if (choice.kind === 'stream') {
    const { name } = choice.stream
    if (isPreviewStream(name)) throw new Error(t('This is a temporary preview stream and can’t be chosen'))
    return { streamName: name, cameraTitle: name }
  }
  const { camera } = choice
  let name = camera.streamName && !isPreviewStream(camera.streamName) ? camera.streamName : null
  if (!name) {
    // One connection to the camera at a time: a preview still running gives way first.
    await cancelPreview(client, camera)
    const taken = new Set((await client.streams()).map((stream) => stream.name))
    const fresh = uniqueStreamName(Go2RTCClient.streamName(camera.source.name), taken)
    await client.addStream(fresh, camera.source.url)
    adoptPreview(client, camera, fresh)
    window.wp.log(`[setup] added stream ${fresh} for ${camera.source.name}`)
    name = fresh
  }
  return { streamName: name, cameraTitle: camera.source.name, xiaomiAccountID: camera.accountID, xiaomiRegion: camera.region }
}

/// "gostinaya", or "gostinaya-2" when another source already uses that name.
export function uniqueStreamName(base: string, taken: Set<string>): string {
  if (!taken.has(base)) return base
  let counter = 2
  while (taken.has(`${base}-${counter}`)) counter += 1
  return `${base}-${counter}`
}

/// Adds any go2rtc source by URL (`rtsp://…`, `onvif://…`) as a new stream.
export async function addSourceStream(client: Go2RTCClient, name: string, source: string): Promise<Go2RTCStream> {
  const trimmedName = name.trim()
  const trimmedSource = source.trim()
  if (isPreviewStream(trimmedName)) throw new Error(t('Names starting with “%@” are reserved for Waiting Paws', PREVIEW_PREFIX))
  await client.addStream(trimmedName, trimmedSource)
  window.wp.log(`[setup] added stream ${trimmedName}`)
  return { name: trimmedName, sources: [trimmedSource] }
}
