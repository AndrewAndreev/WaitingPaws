import { createWriteStream, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { Readable } from 'node:stream'
import type { ReadableStream as WebReadableStream } from 'node:stream/web'

/// Records a go2rtc stream by downloading `/api/stream.mp4` straight into a file (fragmented MP4).
/// Port of the Swift `StreamRecorder`: `onEnded` fires when the stream ends without `stop()` — go2rtc lost
/// the camera, or the server refused the stream — so the app can go on in a new part.
export class StreamRecorder {
  isRecording = false
  startedAt: number | null = null
  filePath: string | null = null
  lastError: string | null = null
  bytesWritten = 0
  onEnded: ((reason: string | null) => void) | null = null

  private controller: AbortController | null = null
  /// Resolves once the current file is closed (after `stop()` or the stream's end).
  private closed: Promise<void> = Promise.resolve()
  private generation = 0

  start(url: string, authorization: string | null, filePath: string): void {
    if (this.isRecording) void this.stop()
    mkdirSync(dirname(filePath), { recursive: true })
    const file = createWriteStream(filePath)
    const controller = new AbortController()
    const generation = ++this.generation
    this.controller = controller
    this.filePath = filePath
    this.bytesWritten = 0
    this.lastError = null
    this.startedAt = Date.now()
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
            if (generation === this.generation) this.bytesWritten += buffer.length
            if (!file.write(buffer)) await new Promise<void>((resolve) => file.once('drain', () => resolve()))
          }
        }
      } catch (error) {
        if (!controller.signal.aborted) reason = error instanceof Error ? error.message : String(error)
      }
      await new Promise<void>((resolve) => file.end(() => resolve()))
      // A task of an earlier `start` (stopped, then started again) must not end the current one.
      if (generation !== this.generation || controller.signal.aborted) return
      if (reason) this.lastError = reason
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
