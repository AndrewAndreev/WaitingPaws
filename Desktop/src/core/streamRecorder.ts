// Go2RTC/StreamRecorder.swift — only the contract is ported, plus Go2RTC/MP4FragmentScanner.swift.
//
// Skipped: the recording itself (`URLSession` streaming `GET /api/stream.mp4` into a `FileHandle`, the
// HTTP status check, byte counting, the `onEnded` callback when go2rtc closes the stream without `stop()`).
// It is file and network IO, so the Electron main process implements it (Node `fetch` + a write stream).
// The URL to record is `Go2RTCClient.mp4URL(stream)`, sent with `Go2RTCServer.authorizationHeader(server)`.
// The interface below is what the Swift class exposes, for that implementation to follow.

/** Records a go2rtc stream by downloading `/api/stream.mp4` straight into a file (a fragmented MP4). */
export interface StreamRecorder {
  readonly isRecording: boolean
  /** Epoch ms. */
  readonly startedAt: number | null
  readonly filePath: string | null
  readonly lastError: string | null
  /** Bytes written so far. */
  readonly bytesWritten: number
  /**
   * When the first media fragment arrived (epoch ms): the file's video starts here. go2rtc sends it only with the
   * camera's next keyframe, up to a whole GOP after `startedAt`.
   */
  readonly firstFragmentAt: number | null
  /**
   * Called when the stream ends without `stop()`: go2rtc lost the camera, or the server refused the stream
   * ("HTTP 404" and the like is the argument; the file stays as written). Not called after `stop()`.
   */
  onEnded: ((reason: string | null) => void) | null
  /** Called when the first media fragment arrived (`firstFragmentAt`). */
  onFirstFragment: (() => void) | null
  /** Stops a running recording first. Non-2xx answers end the recording with `lastError = "HTTP <status>"`. */
  start(url: string, authorization: string | null, filePath: string): Promise<void>
  stop(): void
}

/** Seconds since `startedAt` (`StreamRecorder.duration(at:)`); 0 when not started. */
export function recordingDuration(startedAt: number | null, now: number = Date.now()): number {
  return startedAt === null ? 0 : (now - startedAt) / 1000
}

/**
 * Reads the top-level box headers of a fragmented MP4 as it streams in, to tell when the first media fragment
 * arrives: go2rtc sends the init segment (`ftyp`, `moov`) at once and the first `moof` only with the camera's next
 * keyframe — up to a whole GOP (a few seconds) after the request.
 */
export class MP4FragmentScanner {
  /** The current box header read so far (8 bytes, 16 with a 64-bit size). */
  private header: number[] = []
  /** Bytes of the current box's body still to skip. */
  private remaining = 0
  /** A box that runs to the end of the stream (size 0), or one too short to be a box: nothing more to read. */
  private gaveUp = false
  private seen = false

  get sawFragment(): boolean {
    return this.seen
  }

  /** Feeds the next bytes of the stream; true once a `moof` (or a bare `mdat`) has started. */
  feed(data: Uint8Array): boolean {
    if (this.seen || this.gaveUp) return this.seen
    let index = 0
    while (index < data.length) {
      if (this.remaining > 0) {
        const step = Math.min(this.remaining, data.length - index)
        this.remaining -= step
        index += step
        continue
      }
      this.header.push(data[index])
      index += 1
      if (this.header.length < 8) continue
      const size32 = readUInt(this.header, 0, 4)
      const type = String.fromCharCode(...this.header.slice(4, 8))
      if (type === 'moof' || type === 'mdat') {
        this.seen = true
        return true
      }
      let size = size32
      let headerLength = 8
      if (size32 === 1) {
        // A 64-bit size follows the type.
        if (this.header.length < 16) continue
        size = readUInt(this.header, 8, 16)
        headerLength = 16
      }
      if (size < headerLength) {
        this.gaveUp = true
        return false
      }
      this.remaining = size - headerLength
      this.header = []
    }
    return false
  }
}

/** Big-endian unsigned integer of `bytes[start..<end]` (exact up to 2^53, far beyond any recording). */
function readUInt(bytes: readonly number[], start: number, end: number): number {
  let value = 0
  for (let i = start; i < end; i++) value = value * 256 + bytes[i]
  return value
}
