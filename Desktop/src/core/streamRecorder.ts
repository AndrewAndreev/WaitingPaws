// Go2RTC/StreamRecorder.swift — only the contract is ported.
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
   * Called when the stream ends without `stop()`: go2rtc lost the camera, or the server refused the stream
   * ("HTTP 404" and the like is the argument; the file stays as written). Not called after `stop()`.
   */
  onEnded: ((reason: string | null) => void) | null
  /** Stops a running recording first. Non-2xx answers end the recording with `lastError = "HTTP <status>"`. */
  start(url: string, authorization: string | null, filePath: string): Promise<void>
  stop(): void
}

/** Seconds since `startedAt` (`StreamRecorder.duration(at:)`); 0 when not started. */
export function recordingDuration(startedAt: number | null, now: number = Date.now()): number {
  return startedAt === null ? 0 : (now - startedAt) / 1000
}
