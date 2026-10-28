// The hidden "media" window: finalizes recordings with WebCodecs (see finalizer.ts) on request of the main process.
import { needsFinalizing, writeRecording, type MediaIO, type RecordingPart } from './finalizer'

interface MediaBridge extends MediaIO {
  onJob(handler: (job: MediaJob) => void): void
  done(id: number, result: { ok: true; value: unknown } | { ok: false; error: string }): void
}

export type MediaJob =
  | { id: number; kind: 'check'; path: string }
  /** `replacing`: the file the result is to replace (see `writeRecording`). */
  | { id: number; kind: 'write'; parts: RecordingPart[]; output: string; replacing?: string }

declare global {
  interface Window {
    media: MediaBridge
  }
}

const bridge = window.media
// One job at a time: WebCodecs encoders are not free, and the files are big.
let queue: Promise<void> = Promise.resolve()

bridge.onJob((job) => {
  queue = queue.then(async () => {
    try {
      const value = job.kind === 'check' ? await needsFinalizing(bridge, job.path) : await writeRecording(bridge, job.parts, job.output, job.replacing ?? null)
      bridge.done(job.id, { ok: true, value })
    } catch (error) {
      bridge.done(job.id, { ok: false, error: error instanceof Error ? error.message : String(error) })
    }
  })
})
