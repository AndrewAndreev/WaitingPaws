// Stills for the welcome page and the camera picker, cached for the app's lifetime: frames of go2rtc streams and
// previews of Mi Home cameras that are not streams yet. Port of the Mac app's `SetupStillStore` /
// `SetupFrameGrabber`.
//
// The bundled go2rtc has no ffmpeg, so `/api/frame.jpeg` cannot turn H.264/H.265 into a picture: a still is taken
// from the camera player itself (go2rtc's video-rtc.js over MSE) in a hidden element — the first frame it plays is
// drawn into a canvas and kept as a JPEG data URL. A user's own server may have ffmpeg: its JPEG is tried first.
//
// A preview registers a temporary stream `__wp_preview_<did>` with the camera's `xiaomi://` source, takes one frame
// from it and deletes it again — also after a failure, a timeout or a cancel. At most two stills load at a time
// (each is a connection to a camera, Mi Home cameras allow few) and each gets 12 s. The user's own streams are
// never touched. When no setup screen is open any more, running previews stop and remove their streams.
import { useEffect } from 'react'
import { create } from 'zustand'
import type { Go2RTCClient } from '@core/go2rtcClient'
import { createPlayer } from '../player/CameraPlayer'
import { useStore } from '../store'
import { Camera, PREVIEW_PREFIX, isPreviewStream, type CatalogCamera, type CatalogData } from './catalog'

export type StillState =
  | { kind: 'loading' }
  /// `image` is null when the picture came but could not be read back (the size is still known).
  | { kind: 'loaded'; image: string | null; width: number; height: number }
  | { kind: 'failed' }

/// What a still shows: a go2rtc stream, or a Mi Home camera go2rtc does not play yet (a preview).
export type StillSource = { kind: 'stream'; name: string } | { kind: 'camera'; camera: CatalogCamera }

export const stillSourceOf = (camera: CatalogCamera): StillSource =>
  camera.streamName ? { kind: 'stream', name: camera.streamName } : { kind: 'camera', camera }

const PREVIEW_TIMEOUT = 12_000
const STREAM_TIMEOUT = 15_000
/// A camera that was offline is tried again after a while, not on every redraw.
const STREAM_RETRY = 60_000
const PREVIEW_RETRY = 120_000

const useStills = create<{ states: Record<string, StillState> }>(() => ({ states: {} }))

function setState(key: string, state: StillState | null): void {
  const states = { ...useStills.getState().states }
  if (state) states[key] = state
  else delete states[key]
  useStills.setState({ states })
}

function getState(key: string): StillState | undefined {
  return useStills.getState().states[key]
}

const tasks = new Map<string, { abort: AbortController; done: Promise<void> }>()
const failedAt = new Map<string, number>()
/// Temporary streams that exist in go2rtc right now: the leftovers cleanup keeps away from them.
const livePreviews = new Map<string, Go2RTCClient>()

function key(client: Go2RTCClient, stream: string): string {
  return `${client.server.baseURL}|${stream}`
}

/// `__wp_preview_1093845577`: one per camera, so two screens asking for the same preview share it.
export function previewStreamName(camera: CatalogCamera): string {
  const did = Camera.deviceID(camera)
  let safe = (did ?? camera.source.url).replace(/[^A-Za-z0-9_-]/g, '_')
  if (did === null || safe.length > 40) safe = safe.slice(-40)
  return PREVIEW_PREFIX + safe
}

function previewKey(client: Go2RTCClient, camera: CatalogCamera): string {
  return key(client, previewStreamName(camera))
}

/// The state of a still, or undefined before it was asked for.
export function stillState(client: Go2RTCClient | null, source: StillSource, states = useStills.getState().states): StillState | undefined {
  if (!client) return undefined
  if (source.kind === 'stream') return states[key(client, source.name)]
  // No address in the home network: Mi Home sees the camera offline.
  if (Camera.host(source.camera) === null) return { kind: 'failed' }
  return states[previewKey(client, source.camera)]
}

/// The still of `source`, loaded on first use while `enabled` (the server is ready).
export function useStill(client: Go2RTCClient | null, source: StillSource | null, enabled: boolean): StillState | undefined {
  const states = useStills((store) => store.states)
  const id = source ? (source.kind === 'stream' ? `s|${source.name}` : `c|${source.camera.source.url}|${source.camera.streamName ?? ''}`) : null
  useEffect(() => {
    if (client && source && enabled) requestStill(client, source)
    // `id` stands for `source`.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client, id, enabled])
  return source ? stillState(client, source, states) : undefined
}

/// Starts loading a still unless one is cached (or loading). `force` refreshes a stream's still and retries a
/// failed preview; a preview that came through stays for the session.
export function requestStill(client: Go2RTCClient, source: StillSource, force = false): void {
  if (source.kind === 'stream') requestStreamStill(client, source.name, force)
  else requestPreview(client, source.camera, force)
}

/// A force refresh also takes new stills (a camera may have come online).
export function refreshStills(client: Go2RTCClient, data: CatalogData): void {
  for (const stream of data.streams) requestStill(client, { kind: 'stream', name: stream.name }, true)
  for (const camera of data.accounts.flatMap((account) => account.cameras)) {
    if (camera.streamName === null) requestStill(client, { kind: 'camera', camera }, true)
  }
}

function requestStreamStill(client: Go2RTCClient, stream: string, force: boolean): void {
  if (isPreviewStream(stream)) return
  const id = key(client, stream)
  const state = getState(id)
  if (!force && state) {
    if (state.kind !== 'failed' || Date.now() - (failedAt.get(id) ?? 0) < STREAM_RETRY) return
  }
  if (tasks.has(id)) return
  if (!state || state.kind === 'failed') setState(id, { kind: 'loading' })
  run(id, async (signal) => {
    const still = await grab(client, stream, signal, STREAM_TIMEOUT)
    if (signal.aborted) {
      if (getState(id)?.kind === 'loading') setState(id, null)
    } else if (still) {
      setState(id, still)
    } else if (getState(id)?.kind !== 'loaded') {
      // A failed refresh keeps the old picture.
      setState(id, { kind: 'failed' })
      failedAt.set(id, Date.now())
    }
  })
}

function requestPreview(client: Go2RTCClient, camera: CatalogCamera, force: boolean): void {
  if (camera.streamName !== null || Camera.host(camera) === null) return
  const id = previewKey(client, camera)
  const state = getState(id)
  if (state?.kind === 'loading' || state?.kind === 'loaded') return
  if (state?.kind === 'failed' && !force && Date.now() - (failedAt.get(id) ?? 0) < PREVIEW_RETRY) return
  if (tasks.has(id)) return
  setState(id, { kind: 'loading' })
  const stream = previewStreamName(camera)
  const source = camera.source.url
  run(id, async (signal) => {
    const still = await preview(client, source, stream, signal)
    if (signal.aborted) {
      // Cancelled for a real stream of the same camera, or the screens closed: nothing is known.
      if (getState(id)?.kind === 'loading') setState(id, null)
    } else if (still) {
      setState(id, still)
    } else {
      setState(id, { kind: 'failed' })
      failedAt.set(id, Date.now())
    }
  })
}

function run(id: string, body: (signal: AbortSignal) => Promise<void>): void {
  const abort = new AbortController()
  const done = body(abort.signal)
    .catch((error) => window.wp.log(`[setup] still ${id}: ${(error as Error)?.message ?? error}`))
    .finally(() => tasks.delete(id))
  tasks.set(id, { abort, done })
}

/// Waits for a free slot, registers the temporary stream, grabs a frame within the time budget and removes the
/// stream whatever happened.
async function preview(client: Go2RTCClient, source: string, stream: string, signal: AbortSignal): Promise<StillState | null> {
  if (!(await slots.acquire(signal))) return null
  const deadline = AbortSignal.any([signal, AbortSignal.timeout(PREVIEW_TIMEOUT)])
  livePreviews.set(stream, client)
  try {
    try {
      await client.addStream(stream, source)
    } catch (error) {
      window.wp.log(`[setup] preview ${stream}: ${(error as Error).message}`)
      return null
    }
    if (deadline.aborted) return null
    return await grabFrame(client.server.baseURL, stream, deadline)
  } finally {
    await deletePreviewStream(client, stream)
    livePreviews.delete(stream)
    slots.release()
  }
}

async function deletePreviewStream(client: Go2RTCClient, stream: string): Promise<void> {
  if (!isPreviewStream(stream)) return
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      await client.deleteStream(stream)
      return
    } catch (error) {
      window.wp.log(`[setup] preview ${stream} not removed (${attempt + 1}): ${(error as Error).message}`)
      await new Promise((resolve) => setTimeout(resolve, 500))
    }
  }
}

/// Stops a preview of `camera` (and waits until its temporary stream is gone).
export async function cancelPreview(client: Go2RTCClient, camera: CatalogCamera): Promise<void> {
  const task = tasks.get(previewKey(client, camera))
  if (!task) return
  task.abort.abort()
  await task.done
}

/// The camera became the go2rtc stream `stream`: its preview serves as that stream's still until a real one comes.
export function adoptPreview(client: Go2RTCClient, camera: CatalogCamera, stream: string): void {
  const still = getState(previewKey(client, camera))
  if (still?.kind !== 'loaded' || getState(key(client, stream))) return
  setState(key(client, stream), still)
}

/// Removes temporary preview streams that outlived their preview (the app quit in the middle of one).
export function removeLeftoverPreviews(client: Go2RTCClient, streams: string[]): void {
  for (const stream of streams) {
    if (!isPreviewStream(stream) || livePreviews.has(stream)) continue
    window.wp.log(`[setup] removing leftover preview stream ${stream}`)
    void deletePreviewStream(client, stream)
  }
}

// MARK: - Lifetime

let sessions = 0
let idleTimer: number | undefined

/// Keeps previews running while a setup screen is open. When the last one closes, previews stop (each removes its
/// temporary stream) and stills waiting for a slot are dropped.
export function useStillsSession(): void {
  useEffect(() => {
    sessions += 1
    window.clearTimeout(idleTimer)
    return () => {
      sessions -= 1
      if (sessions > 0) return
      // A screen replacing another (welcome page → picker) is not a close.
      idleTimer = window.setTimeout(() => {
        if (sessions === 0) for (const task of tasks.values()) task.abort.abort()
      }, 300)
    }
  }, [])
}

// The window closes while a preview runs: its stream goes now (the next catalog load removes it otherwise).
window.addEventListener('beforeunload', () => {
  for (const [stream, client] of livePreviews) void client.deleteStream(stream).catch(() => undefined)
})

// MARK: - Slots

/// At most `limit` stills at once; the rest wait in order. A waiting one that is cancelled leaves the queue.
class Slots {
  private busy = 0
  private waiting: { resolve: (ok: boolean) => void; signal: AbortSignal; onAbort: () => void }[] = []

  constructor(private readonly limit: number) {}

  /// `false` when cancelled while waiting (no slot is held then).
  acquire(signal: AbortSignal): Promise<boolean> {
    if (signal.aborted) return Promise.resolve(false)
    if (this.busy < this.limit) {
      this.busy += 1
      return Promise.resolve(true)
    }
    return new Promise((resolve) => {
      const entry = {
        resolve,
        signal,
        onAbort: () => {
          this.waiting = this.waiting.filter((item) => item !== entry)
          resolve(false)
        },
      }
      signal.addEventListener('abort', entry.onAbort, { once: true })
      this.waiting.push(entry)
    })
  }

  /// Hands the slot to the next in line, or frees it.
  release(): void {
    const next = this.waiting.shift()
    if (!next) {
      this.busy -= 1
      return
    }
    next.signal.removeEventListener('abort', next.onAbort)
    next.resolve(true)
  }
}

const slots = new Slots(2)

// MARK: - Grabbing a frame

async function grab(client: Go2RTCClient, stream: string, signal: AbortSignal, timeout: number): Promise<StillState | null> {
  if (!(await slots.acquire(signal))) return null
  try {
    const deadline = AbortSignal.any([signal, AbortSignal.timeout(timeout)])
    // A user's server may have ffmpeg for JPEG snapshots; the bundled one has not.
    if (!isBundled(client.server.baseURL)) {
      const jpeg = await loadJPEG(client.snapshotURL(stream), deadline)
      if (jpeg) return jpeg
    }
    if (deadline.aborted) return null
    return await grabFrame(client.server.baseURL, stream, deadline)
  } finally {
    slots.release()
  }
}

function isBundled(baseURL: string): boolean {
  const app = useStore.getState().app
  return app?.settings.connectionMode === 'embedded' && app.server?.baseURL === baseURL
}

function loadJPEG(url: string, signal: AbortSignal): Promise<StillState | null> {
  return new Promise((resolve) => {
    const image = new Image()
    const finish = (still: StillState | null) => {
      signal.removeEventListener('abort', onAbort)
      image.onload = image.onerror = null
      resolve(still)
    }
    const onAbort = () => {
      image.src = ''
      finish(null)
    }
    signal.addEventListener('abort', onAbort, { once: true })
    image.onload = () => finish(image.naturalWidth ? { kind: 'loaded', image: url, width: image.naturalWidth, height: image.naturalHeight } : null)
    image.onerror = () => finish(null)
    image.src = url
  })
}

/// Hidden stage for the players that take stills: inside the window (Chromium may skip decoding for elements far
/// off-screen) but invisible and out of the way.
function stage(): HTMLElement {
  let element = document.getElementById('wp-still-stage')
  if (!element) {
    element = document.createElement('div')
    element.id = 'wp-still-stage'
    element.setAttribute('aria-hidden', 'true')
    Object.assign(element.style, {
      position: 'fixed',
      left: '0',
      bottom: '0',
      width: '320px',
      height: '180px',
      opacity: '0',
      pointerEvents: 'none',
      overflow: 'hidden',
      zIndex: '-1',
    })
    document.body.appendChild(element)
  }
  return element
}

function socketURL(baseURL: string, stream: string): string {
  const url = new URL('api/ws', baseURL)
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
  url.searchParams.set('src', stream)
  return url.href
}

/// The first frame the camera player shows, as a JPEG data URL with the video's real size. `null` when the stream
/// fails, or nothing played before `signal` fired.
export function grabFrame(baseURL: string, stream: string, signal: AbortSignal): Promise<StillState | null> {
  return new Promise((resolve) => {
    if (signal.aborted) return resolve(null)
    const player = createPlayer()
    let done = false
    const finish = (still: StillState | null, note: string | null) => {
      if (done) return
      done = true
      signal.removeEventListener('abort', onAbort)
      player.dispose()
      player.remove()
      if (note) window.wp.log(`[setup] still ${stream}: ${note}`)
      resolve(still)
    }
    const video = () => player.video as HTMLVideoElement | undefined
    const onAbort = () => {
      // Out of time: a frame that arrived without playback starting still counts.
      const element = video()
      const timedOut = (signal.reason as DOMException | undefined)?.name === 'TimeoutError'
      if (timedOut && element && element.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA && element.videoWidth) {
        finish(drawFrame(element), `${element.videoWidth}x${element.videoHeight} (before playback)`)
      } else finish(null, timedOut ? 'no picture in time' : null)
    }
    signal.addEventListener('abort', onAbort, { once: true })

    const capture = () => {
      const element = video()
      if (!element || !element.videoWidth) return finish(null, 'no video size')
      const take = () => finish(drawFrame(element), `${element.videoWidth}x${element.videoHeight}`)
      // Wait for the frame to be really presented: `playing` can come a moment before it is drawable.
      if ('requestVideoFrameCallback' in element) {
        const fallback = window.setTimeout(take, 500)
        element.requestVideoFrameCallback(() => {
          window.clearTimeout(fallback)
          take()
        })
      } else take()
    }

    player.muted = true
    player.fit = 'cover'
    player.events = {
      phase: (phase) => {
        if (phase.kind === 'playing') capture()
        // go2rtc could not reach the camera (video-rtc.js would keep retrying).
        else if (phase.kind === 'failed') finish(null, `failed (${phase.reason})`)
      },
      delay: () => undefined,
      videoSize: () => undefined,
      log: () => undefined,
    }
    player.mode = 'mse'
    player.background = true
    player.style.display = 'block'
    player.style.width = '100%'
    player.style.height = '100%'
    stage().appendChild(player)
    player.src = socketURL(baseURL, stream)
  })
}

function drawFrame(video: HTMLVideoElement): StillState {
  const width = video.videoWidth
  const height = video.videoHeight
  try {
    const scale = Math.min(1, 640 / width)
    const canvas = document.createElement('canvas')
    canvas.width = Math.round(width * scale)
    canvas.height = Math.round(height * scale)
    const context = canvas.getContext('2d')
    if (!context) return { kind: 'loaded', image: null, width, height }
    context.drawImage(video, 0, 0, canvas.width, canvas.height)
    return { kind: 'loaded', image: canvas.toDataURL('image/jpeg', 0.82), width, height }
  } catch {
    return { kind: 'loaded', image: null, width, height }
  }
}
