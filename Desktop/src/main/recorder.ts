import { createWriteStream, mkdirSync, type WriteStream } from 'node:fs'
import { dirname } from 'node:path'
import { Readable } from 'node:stream'
import type { ReadableStream as WebReadableStream } from 'node:stream/web'
import { MP4FragmentScanner } from '@core/streamRecorder'

/// Records a go2rtc stream by downloading `/api/stream.mp4` straight into a file (fragmented MP4).
/// Port of the Swift `StreamRecorder`: `onEnded` fires when the stream ends without `stop()` — go2rtc lost
/// the camera, the server refused the stream, or the file could not be written (`writeFailed`) — so the app can go
/// on in a new part, or stop.
export class StreamRecorder {
  isRecording = false
  startedAt: number | null = null
  /// When the first media fragment arrived: the file's video starts here. go2rtc sends it only with the camera's
  /// next keyframe, up to a whole GOP after `startedAt`.
  firstFragmentAt: number | null = null
  filePath: string | null = null
  lastError: string | null = null
  /// The file could not be written (disk full, a folder Windows protects, a lock): `lastError` says why.
  writeFailed = false
  bytesWritten = 0
  onEnded: ((reason: string | null) => void) | null = null
  /// Called when the first media fragment arrived (`firstFragmentAt`).
  onFirstFragment: (() => void) | null = null

  private controller: AbortController | null = null
  /// Resolves once the current file is closed (after `stop()` or the stream's end); never rejects.
  private closed: Promise<void> = Promise.resolve()
  private generation = 0

  start(url: string, authorization: string | null, filePath: string): void {
    if (this.isRecording) void this.stop()
    mkdirSync(dirname(filePath), { recursive: true })
    const file = createWriteStream(filePath)
    const controller = new AbortController()
    const generation = ++this.generation
    const scanner = new MP4FragmentScanner()
    // Set by the 'error' handler (a cast: the compiler doesn't see assignments in callbacks).
    let fileError = null as Error | null
    // Disk full, Controlled Folder Access, an antivirus lock, a name too long: the error ends this recording (and
    // is its `lastError`) instead of reaching the process as an uncaught exception.
    file.on('error', (error) => {
      fileError ??= error
      controller.abort()
    })
    this.controller = controller
    this.filePath = filePath
    this.bytesWritten = 0
    this.lastError = null
    this.writeFailed = false
    this.startedAt = Date.now()
    this.firstFragmentAt = null
    this.isRecording = true

    const headers: Record<string, string> = {}
    if (authorization) headers.Authorization = authorization
    this.closed = (async () => {
      let reason: string | null = null
      try {
        const response = await fetch(url, { headers, signal: controller.signal })
        if (!response.ok || !response.body) {
          reason = `HTTP ${response.status}`
        } else {
          const body = Readable.fromWeb(response.body as unknown as WebReadableStream<Uint8Array>)
          for await (const chunk of body) {
            if (controller.signal.aborted) break
            const buffer = chunk as Buffer
            const current = generation === this.generation
            if (current) this.bytesWritten += buffer.length
            if (!scanner.sawFragment && scanner.feed(buffer) && current && this.firstFragmentAt === null) {
              this.firstFragmentAt = Date.now()
              this.onFirstFragment?.()
            }
            if (!file.write(buffer)) await writable(file)
          }
        }
      } catch (error) {
        if (!controller.signal.aborted) reason = error instanceof Error ? error.message : String(error)
      }
      // Whatever ended the stream, the request goes away with it.
      controller.abort()
      await close(file)
      if (fileError) reason = fileError.message
      // A task of an earlier `start` (stopped, then started again) must not end the current one.
      if (generation !== this.generation) return
      if (reason) this.lastError = reason
      if (fileError) this.writeFailed = true
      // Stopped: `stop()` has said so already.
      if (this.controller !== controller) return
      this.controller = null
      this.isRecording = false
      this.onEnded?.(this.lastError)
    })()
  }

  /// Stops writing; resolves when the file is closed and safe to read.
  stop(): Promise<void> {
    this.controller?.abort()
    this.controller = null
    this.isRecording = false
    return this.closed
  }

  duration(now = Date.now()): number {
    return this.startedAt === null ? 0 : (now - this.startedAt) / 1000
  }
}

/// Resolves when the file takes more data again, or failed (then nothing will drain it).
function writable(file: WriteStream): Promise<void> {
  return new Promise((resolve) => {
    if (file.destroyed) return resolve()
    const done = () => {
      file.off('drain', done)
      file.off('close', done)
      resolve()
    }
    file.on('drain', done)
    file.on('close', done)
  })
}

/// Flushes and closes the file; resolves once it is closed, also after an error.
function close(file: WriteStream): Promise<void> {
  return new Promise((resolve) => {
    if (file.closed) return resolve()
    file.once('close', () => resolve())
    if (!file.destroyed && !file.writableEnded) file.end()
  })
}
