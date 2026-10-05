// Video files of the history: which exist, their sizes and lengths, and the small frames of the table
// (MacHistoryModel.refreshFiles + MacHistoryThumbnails). Everything is read through `wp-media://` URLs by
// one hidden <video> at a time, visible rows first, and kept in memory (never regenerated while scrolling).
import { useEffect, useState } from 'react'
import { create } from 'zustand'
import { useStore } from '../store'
import type { VideoInfo } from './logic'

interface MediaStore {
  /// File name → what is known about it.
  videos: Map<string, VideoInfo>
  /// File name → how many times it was rewritten (finalized) while the app runs.
  generations: Record<string, number>
  set: (fileName: string, patch: Partial<VideoInfo>) => void
}

export const useMedia = create<MediaStore>((set) => ({
  videos: new Map(),
  generations: {},
  set: (fileName, patch) =>
    set((store) => {
      const previous = store.videos.get(fileName) ?? { fileName, exists: null, bytes: null, duration: null }
      const next = { ...previous, ...patch }
      if (previous.exists === next.exists && previous.bytes === next.bytes && previous.duration === next.duration) return store
      const videos = new Map(store.videos)
      videos.set(fileName, next)
      return { videos }
    }),
}))

/// Bumped per file when it is rewritten (finalized after recording): its frame, size and length are read again
/// and the player reloads it.
export function generation(fileName: string): number {
  return useMedia.getState().generations[fileName] ?? 0
}

export function bumpGeneration(fileName: string): void {
  useMedia.setState((store) => ({ generations: { ...store.generations, [fileName]: (store.generations[fileName] ?? 0) + 1 } }))
  for (const key of [...thumbnails.keys()]) if (key.startsWith(fileName + '|')) dropThumbnail(key)
  checked.delete(fileName)
}

// A file leaving `finalizing` was just rewritten: bump it in the same update as the app state, so the player
// never loads the old version once more.
let previousFinalizing: readonly string[] = []
useStore.subscribe((state) => {
  const current = state.app?.finalizing ?? []
  if (current === previousFinalizing) return
  const done = previousFinalizing.filter((name) => !current.includes(name))
  previousFinalizing = current
  for (const name of done) bumpGeneration(name)
})

/// URL for <video> elements; `v` changes when the file is rewritten so the element loads it again.
export function videoURL(fileName: string, version = generation(fileName)): string {
  return `${window.wp.mediaURL('recordings', fileName)}?v=${version}`
}

// MARK: - Checking files

/// Files whose existence/size was checked for the current generation.
const checked = new Set<string>()

/// Reads the size of the training videos (clips come with theirs) and finds out which exist. With a CORS-enabled
/// media scheme this is a HEAD request; otherwise the file's metadata is loaded by the queue (existence and
/// length, size unknown).
export async function checkFiles(recordVideos: readonly string[], clips: readonly { fileName: string; size: number }[], skip: ReadonlySet<string>): Promise<void> {
  const store = useMedia.getState()
  for (const clip of clips) store.set(clip.fileName, { exists: true, bytes: clip.size })
  for (const name of recordVideos) {
    if (skip.has(name) || checked.has(name)) continue
    checked.add(name)
    const head = await headRequest(name)
    if (head) {
      store.set(name, { exists: head.exists, bytes: head.exists ? head.bytes : null })
    }
  }
  for (const clip of clips) if (!skip.has(clip.fileName)) enqueue(clip.fileName, 'meta')
  for (const name of recordVideos) if (!skip.has(name) && useMedia.getState().videos.get(name)?.exists !== false) enqueue(name, 'meta')
}

let fetchWorks: boolean | null = null

async function headRequest(fileName: string): Promise<{ exists: boolean; bytes: number } | null> {
  if (fetchWorks === false) return null
  try {
    const response = await fetch(window.wp.mediaURL('recordings', fileName), { method: 'HEAD', cache: 'no-store' })
    fetchWorks = true
    if (response.status === 404) return { exists: false, bytes: 0 }
    const length = Number(response.headers.get('content-length'))
    return { exists: response.ok, bytes: Number.isFinite(length) ? length : 0 }
  } catch {
    // The scheme is not CORS-enabled for this page: fall back to the <video> element.
    fetchWorks = false
    return null
  }
}

// MARK: - Thumbnails and lengths

/// A frame as an image (CORS-enabled scheme), or the loaded <video> itself showing it (a tainted frame cannot be
/// copied into a canvas), or nothing (the file cannot be read).
export type Thumbnail = { kind: 'image'; url: string } | { kind: 'video'; element: HTMLVideoElement } | { kind: 'failed' }

const thumbnails = new Map<string, Thumbnail>()
const listeners = new Set<() => void>()
const LIMIT = 300

function thumbnailKey(fileName: string): string {
  return `${fileName}|${generation(fileName)}`
}

function dropThumbnail(key: string): void {
  const thumbnail = thumbnails.get(key)
  if (thumbnail?.kind === 'video') release(thumbnail.element)
  thumbnails.delete(key)
}

function release(element: HTMLVideoElement): void {
  element.removeAttribute('src')
  element.load()
  element.remove()
}

/// Loaded <video> elements kept as frames (each is a paused media player): only this many, those off screen go first.
const VIDEO_LIMIT = 40

function store(key: string, thumbnail: Thumbnail): void {
  thumbnails.set(key, thumbnail)
  // Oldest out first (Map keeps insertion order).
  while (thumbnails.size > LIMIT) dropThumbnail(thumbnails.keys().next().value!)
  const players = [...thumbnails].filter(([, item]) => item.kind === 'video') as [string, { kind: 'video'; element: HTMLVideoElement }][]
  let excess = players.length - VIDEO_LIMIT
  for (const [old, item] of players) {
    if (excess <= 0) break
    if (item.element.isConnected) continue
    dropThumbnail(old)
    excess -= 1
  }
  for (const listener of listeners) listener()
}

export function cachedThumbnail(fileName: string): Thumbnail | undefined {
  return thumbnails.get(thumbnailKey(fileName))
}

type Job = { fileName: string; kind: 'thumb' | 'meta'; key: string }
const queue: Job[] = []
let running = false
/// Frames from a scheme without CORS taint the canvas: then the loaded element itself is the thumbnail.
let canvasWorks: boolean | null = null
/// Files whose length was read (per generation).
const measured = new Set<string>()

/// Asks for a file's frame (`thumb`, visible rows) or only its length (`meta`, everything else).
export function enqueue(fileName: string, kind: 'thumb' | 'meta'): void {
  const key = thumbnailKey(fileName)
  if (kind === 'thumb' && thumbnails.has(key)) return
  if (kind === 'meta' && (measured.has(key) || thumbnails.has(key))) return
  const existing = queue.findIndex((job) => job.key === key)
  if (existing >= 0) {
    if (kind === 'thumb' && queue[existing].kind === 'meta') queue.splice(existing, 1)
    else return
  }
  // Visible rows go first, newest request first (the rows the user is looking at now).
  if (kind === 'thumb') queue.unshift({ fileName, kind, key })
  else queue.push({ fileName, kind, key })
  void pump()
}

/// A visible row no longer needs its frame (scrolled away before its turn).
export function cancel(fileName: string): void {
  const key = thumbnailKey(fileName)
  const index = queue.findIndex((job) => job.key === key && job.kind === 'thumb')
  if (index >= 0) queue[index] = { ...queue[index], kind: 'meta' }
}

async function pump(): Promise<void> {
  if (running) return
  running = true
  try {
    while (queue.length) {
      const job = queue.shift()!
      if (job.key !== thumbnailKey(job.fileName)) continue
      if (job.kind === 'thumb' && thumbnails.has(job.key)) continue
      await run(job)
    }
  } finally {
    running = false
  }
}

async function run(job: Job): Promise<void> {
  const wantsFrame = job.kind === 'thumb'
  const useCORS = wantsFrame && canvasWorks !== false
  let video = await load(job.fileName, useCORS, wantsFrame)
  if (!video.ok && useCORS && canvasWorks === null) {
    // The scheme refuses CORS requests: remember and read it the plain way.
    canvasWorks = false
    video = await load(job.fileName, false, wantsFrame)
  }
  const media = useMedia.getState()
  if (!video.ok) {
    media.set(job.fileName, { exists: video.missing ? false : media.videos.get(job.fileName)?.exists ?? null })
    measured.add(job.key)
    if (wantsFrame) store(job.key, { kind: 'failed' })
    release(video.element)
    return
  }
  const duration = video.element.duration
  media.set(job.fileName, { exists: true, duration: Number.isFinite(duration) && duration > 0 ? duration : null })
  measured.add(job.key)
  if (!wantsFrame) {
    release(video.element)
    return
  }
  if (useCORS) {
    const url = capture(video.element)
    if (url) {
      canvasWorks = true
      store(job.key, { kind: 'image', url })
      release(video.element)
      return
    }
    canvasWorks = false
  }
  // Keep the element: it shows the frame without copying it.
  video.element.className = 'hthumb__video'
  store(job.key, { kind: 'video', element: video.element })
}

async function load(fileName: string, cors: boolean, seek: boolean): Promise<{ ok: boolean; missing: boolean; element: HTMLVideoElement }> {
  const element = document.createElement('video')
  element.muted = true
  element.playsInline = true
  element.preload = 'metadata'
  if (cors) element.crossOrigin = 'anonymous'
  element.src = videoURL(fileName)
  const metadata = await waitFor(element, 'loadedmetadata', 8000)
  if (metadata !== 'ok') return { ok: false, missing: metadata === 'error' && element.error?.code === MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED, element }
  if (!seek) return { ok: true, missing: false, element }
  // About a second in (past a camera's first, sometimes grey picture).
  const duration = element.duration
  element.currentTime = Number.isFinite(duration) && duration > 2 ? 1 : 0
  const seeked = await waitFor(element, 'seeked', 8000)
  if (seeked !== 'ok' && element.readyState < 2) await waitFor(element, 'loadeddata', 3000)
  return { ok: element.readyState >= 2 || seeked === 'ok', missing: false, element }
}

function waitFor(element: HTMLVideoElement, event: string, timeout: number): Promise<'ok' | 'error' | 'timeout'> {
  return new Promise((resolve) => {
    const done = (result: 'ok' | 'error' | 'timeout') => {
      element.removeEventListener(event, onEvent)
      element.removeEventListener('error', onError)
      window.clearTimeout(timer)
      resolve(result)
    }
    const onEvent = () => done('ok')
    const onError = () => done('error')
    const timer = window.setTimeout(() => done('timeout'), timeout)
    element.addEventListener(event, onEvent)
    element.addEventListener('error', onError)
  })
}

/// A 92×52 JPEG of the current frame (twice the cell's size), cropped to fill; null if the canvas is tainted.
function capture(element: HTMLVideoElement): string | null {
  const width = 92
  const height = 52
  const canvas = document.createElement('canvas')
  canvas.width = width
  canvas.height = height
  const context = canvas.getContext('2d')
  if (!context || !element.videoWidth) return null
  const ratio = Math.max(width / element.videoWidth, height / element.videoHeight)
  const w = element.videoWidth * ratio
  const h = element.videoHeight * ratio
  context.drawImage(element, (width - w) / 2, (height - h) / 2, w, h)
  try {
    return canvas.toDataURL('image/jpeg', 0.82)
  } catch {
    return null
  }
}

/// The thumbnail of `fileName` (re-renders when it arrives); requests it while `wanted` (the cell is on screen).
export function useThumbnail(fileName: string | null, wanted: boolean): Thumbnail | undefined {
  const [, setTick] = useState(0)
  const version = useMedia((store) => (fileName ? store.generations[fileName] ?? 0 : 0))
  useEffect(() => {
    const listener = () => setTick((tick) => tick + 1)
    listeners.add(listener)
    return () => {
      listeners.delete(listener)
    }
  }, [])
  useEffect(() => {
    if (!fileName || !wanted) return
    enqueue(fileName, 'thumb')
    return () => cancel(fileName)
  }, [fileName, wanted, version])
  return fileName ? cachedThumbnail(fileName) : undefined
}
