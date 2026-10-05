// The go2rtc player inside the app window: go2rtc's own `video-rtc.js` (WebRTC with MSE/HLS fallbacks), subclassed
// the same way the Mac/iPhone apps do it in their WKWebView page (`CameraStreamView.swift`): a jitter-buffered MSE
// path instead of upstream's near-empty buffer, phases for the status overlay, delay figures and a stats line
// for the log. Each player instance keeps its own state (the Mac page had one player per page).
// @ts-expect-error vendored JS module without types
import { VideoRTC } from './video-rtc.js'

/// What the player is doing, for the overlay over the picture.
export type PlayerPhase =
  | { kind: 'connecting' }
  | { kind: 'waiting' }
  | { kind: 'playing' }
  | { kind: 'stalled' }
  /// `raw`: go2rtc's error chain ("streams: read udp [::]:51467: i/o timeout").
  | { kind: 'failed'; reason: string; raw: string }

export interface PlayerEvents {
  phase(phase: PlayerPhase, raw: string): void
  /// Every second: how far the picture trails the newest data (buffer, s) and how late that data came (network, s).
  delay(buffer: number, network: number | null): void
  videoSize(width: number, height: number): void
  log(text: string): void
}

/// Seconds the MSE player starts behind the live edge to ride out late chunks; it grows (up to 3.5 s) while data
/// comes in bursts and shrinks back when the stream is even.
export const JITTER_BUFFER = 0.8

const BaseRTC = VideoRTC as unknown as { new (): HTMLElement & Record<string, any> }

class WaitingPawsPlayer extends BaseRTC {
  events: PlayerEvents | null = null
  muted = true
  fit: 'contain' | 'cover' = 'contain'
  private phaseName = ''
  private timers: number[] = []
  // How far behind live the MSE player plays (seconds): starts at JITTER_BUFFER, grows at once to cover a gap in the
  // data up to 3.5, and every 10 s eases towards the longest gap of the last 30 s + 0.4.
  private jitter = { target: JITTER_BUFFER, min: JITTER_BUFFER, max: 3.5, windowGapMs: 0, recent: [] as number[] }
  private stats = {
    stalls: 0,
    stalledMs: 0,
    stallStart: 0,
    jumps: 0,
    errors: 0,
    bytes: 0,
    lastData: 0,
    maxGapMs: 0,
    lag: 0,
  }
  // How much later than the fastest of the last minute the newest video arrives (s).
  private network = { buckets: [] as { start: number; min: number }[], lateness: -1 }

  private report(text: string): void {
    this.events?.log(text)
  }

  private setPhase(next: string): void {
    if (next === this.phaseName) return
    this.phaseName = next
    const phase: PlayerPhase | null = parsePhase(next)
    if (phase) this.events?.phase(phase, next)
  }

  private statsRestart(): void {
    this.stats.lastData = 0
    this.network.buckets = []
    this.network.lateness = -1
  }

  private statsChunk(size: number): void {
    const now = performance.now()
    if (this.stats.lastData) {
      const gap = now - this.stats.lastData
      this.stats.maxGapMs = Math.max(this.stats.maxGapMs, gap)
      this.jitter.windowGapMs = Math.max(this.jitter.windowGapMs, gap)
      // A gap longer than the cushion would have frozen the picture: make the cushion cover it.
      if (gap / 1000 > this.jitter.target * 0.8) this.jitter.target = Math.min(this.jitter.max, gap / 1000 + 0.4)
    }
    this.stats.lastData = now
    this.stats.bytes += size
  }

  private networkNote(offset: number): void {
    const now = performance.now()
    let last = this.network.buckets[this.network.buckets.length - 1]
    if (!last || now - last.start >= 10000) {
      last = { start: now, min: offset }
      this.network.buckets = this.network.buckets.filter((b) => now - b.start < 50000).concat(last)
    }
    last.min = Math.min(last.min, offset)
    const late = offset - Math.min(...this.network.buckets.map((b) => b.min))
    this.network.lateness = this.network.lateness < 0 ? late : this.network.lateness + (late - this.network.lateness) * 0.2
  }

  dispose(): void {
    for (const id of this.timers) clearInterval(id)
    this.timers = []
    this.events = null
    try {
      this.ondisconnect()
    } catch {
      // Never connected.
    }
  }

  oninit(): void {
    super.oninit()
    this.setPhase('connecting')
    const video = this.video as HTMLVideoElement
    video.muted = this.muted
    video.controls = false
    video.style.objectFit = this.fit
    video.style.background = '#000'

    this.timers.push(
      window.setInterval(() => {
        this.jitter.recent = this.jitter.recent.concat(this.jitter.windowGapMs).slice(-3)
        this.jitter.windowGapMs = 0
        const goal = Math.max(this.jitter.min, Math.max(...this.jitter.recent) / 1000 + 0.4)
        if (this.jitter.target > goal) this.jitter.target = Math.max(goal, this.jitter.target - 0.3)
      }, 10000),
    )
    this.timers.push(
      window.setInterval(() => {
        const s = this.stats
        if (s.stallStart) {
          s.stalledMs += performance.now() - s.stallStart
          s.stallStart = performance.now()
        }
        if (s.stalls || s.jumps || s.errors || s.maxGapMs > 1500 || s.lag > 1.5) {
          this.report(
            `stats 30s: stalls ${s.stalls}, stalled ${(s.stalledMs / 1000).toFixed(1)} s, jumps ${s.jumps}, errors ${s.errors}, ` +
              `max data gap ${Math.round(s.maxGapMs)} ms, lag ${s.lag.toFixed(2)} s, cushion ${this.jitter.target.toFixed(1)} s, ` +
              `${Math.round((s.bytes * 8) / 30 / 1000)} kbit/s`,
          )
        }
        Object.assign(s, { stalls: 0, stalledMs: 0, jumps: 0, errors: 0, bytes: 0, maxGapMs: 0 })
      }, 30000),
    )

    let first = true
    video.addEventListener('playing', () => {
      if (first) {
        first = false
        this.report(`playing ${video.videoWidth}x${video.videoHeight}`)
        if (video.videoWidth) this.events?.videoSize(video.videoWidth, video.videoHeight)
      }
      this.setPhase('playing')
    })
    // A stall is the picture not moving while it should. `delay`: how old the frame on screen is against the newest
    // data — the time since that data came plus what is still buffered ahead.
    let lastTime = -1
    let still = 0
    let delay = -1
    let ticks = 0
    this.timers.push(
      window.setInterval(() => {
        if (first || video.paused) {
          lastTime = -1
          return
        }
        const buffered = video.buffered
        if (this.stats.lastData && buffered.length) {
          const now = (performance.now() - this.stats.lastData) / 1000 + Math.max(0, buffered.end(buffered.length - 1) - video.currentTime)
          delay = delay < 0 ? now : delay + (now - delay) * 0.3
        }
        if (++ticks % 4 === 0 && delay >= 0) {
          this.events?.delay(delay, this.network.lateness >= 0 ? this.network.lateness : null)
        }
        if (video.currentTime === lastTime) {
          still++
          if (still === 2 && !this.stats.stallStart) {
            this.stats.stalls++
            this.stats.stallStart = performance.now()
          }
          if (still === 8 && this.phaseName === 'playing') {
            this.setPhase('stalled') // 2 s: worth saying on screen
            this.report('stalled 2 s')
          }
        } else {
          if (this.phaseName === 'stalled') this.setPhase('playing')
          still = 0
          if (this.stats.stallStart) {
            this.stats.stalledMs += performance.now() - this.stats.stallStart
            this.stats.stallStart = 0
          }
        }
        lastTime = video.currentTime
      }, 250),
    )
    video.addEventListener('resize', () => {
      if (video.videoWidth) this.events?.videoSize(video.videoWidth, video.videoHeight)
      this.report(`size ${video.videoWidth}x${video.videoHeight}`)
    })
    video.addEventListener('error', () => this.report(`video error ${video.error ? video.error.code : '?'}`))
  }

  onwebrtc(): unknown {
    this.report('mode webrtc')
    return super.onwebrtc()
  }

  // A (re)connection; and go2rtc's {"type":"error"} when it cannot get the camera (video-rtc.js retries).
  onconnect(): unknown {
    this.setPhase('connecting')
    return super.onconnect()
  }

  onopen(): unknown {
    const modes = super.onopen()
    this.onmessage['status'] = (msg: { type: string; value: string }) => {
      if (msg.type === 'error') this.setPhase('error ' + msg.value)
    }
    return modes
  }

  // MSE with a small jitter buffer. Upstream video-rtc.js keeps the buffer nearly empty (playbackRate = buffered
  // seconds, down to 0.1×): every late chunk turned into a freeze and a fast-forward. Here playback trails the live
  // edge by `target` seconds: it starts (and restarts after a stall) only with that much buffered, and the rate
  // merely nudges the lag back towards it.
  onmse(): void {
    this.report('mode mse')
    const video = this.video as HTMLVideoElement
    const ms = new MediaSource()
    ms.addEventListener(
      'sourceopen',
      () => {
        if (video.src.startsWith('blob:')) URL.revokeObjectURL(video.src)
        // A live stream: without an infinite duration, running out of data counts as the end.
        try {
          ms.duration = Infinity
        } catch {
          // Not allowed in this state; harmless.
        }
        this.send({ type: 'mse', value: this.codecs((type: string) => MediaSource.isTypeSupported(type)) })
      },
      { once: true },
    )
    video.src = URL.createObjectURL(ms)
    video.srcObject = null
    this.mseCodecs = ''
    // Playback starts once `target` seconds are buffered; after that it is never paused on purpose.
    let buffering = true

    this.onmessage['mse'] = (msg: { type: string; value: string }) => {
      if (msg.type !== 'mse') return
      this.setPhase('waiting')
      this.mseCodecs = msg.value
      const sb = ms.addSourceBuffer(msg.value)
      sb.mode = 'segments'
      const queue: ArrayBuffer[] = []
      const append = (data: BufferSource) => {
        try {
          sb.appendBuffer(data)
        } catch {
          this.stats.errors++
        }
      }
      const flush = () => {
        if (sb.updating || !queue.length) return
        const data = new Uint8Array(queue.reduce((n, b) => n + b.byteLength, 0))
        let offset = 0
        for (const b of queue) {
          data.set(new Uint8Array(b), offset)
          offset += b.byteLength
        }
        queue.length = 0
        append(data)
      }
      let rate = 1
      sb.addEventListener('updateend', () => {
        flush()
        if (sb.updating || !sb.buffered || !sb.buffered.length) return
        const end = sb.buffered.end(sb.buffered.length - 1)
        const start = sb.buffered.start(0)
        if (end - 10 > start) {
          sb.remove(start, end - 10)
          try {
            ms.setLiveSeekableRange(end - 10, end)
          } catch {
            // Older engines.
          }
        }
        const target = this.jitter.target
        const lag = end - video.currentTime
        this.stats.lag = lag
        this.networkNote(performance.now() / 1000 - end)
        if (video.currentTime < start || lag > target + 3) {
          // Far behind (a long stall, the window was hidden): back to `target` behind live.
          video.currentTime = Math.max(start, end - target)
          if (video.currentTime > 0) this.stats.jumps++
        }
        if (buffering || video.paused || video.ended) {
          if (lag >= target) {
            buffering = false
            this.play()
          }
          return
        }
        // Small steps only: a speed change is hardly visible, a jump or a 0.1× crawl is. Slower than real time only
        // to restore the base cushion.
        const next = lag > target + 1 ? 1.3 : lag > target + 0.2 ? 1.15 : lag < this.jitter.min * 0.5 ? 0.95 : 1
        if (next !== rate) {
          rate = next
          video.playbackRate = rate
        }
      })
      this.statsRestart()
      let init = true
      this.ondata = (data: ArrayBuffer) => {
        if (init) {
          init = false
          this.stats.bytes += data.byteLength
        } else this.statsChunk(data.byteLength)
        if (sb.updating || queue.length) queue.push(data)
        else append(data)
      }
    }
  }

  onhls(): unknown {
    this.report('mode hls')
    return super.onhls()
  }

  onmjpeg(): unknown {
    this.report('mode mjpeg')
    return super.onmjpeg()
  }

  ondisconnect(): unknown {
    this.report('disconnect')
    return super.ondisconnect()
  }

  setMuted(muted: boolean): void {
    this.muted = muted
    if (this.video) (this.video as HTMLVideoElement).muted = muted
  }
}

/// "error mse: streams: dial …: i/o timeout" → the last, human part of go2rtc's error chain.
function parsePhase(state: string): PlayerPhase | null {
  switch (state) {
    case 'connecting':
      return { kind: 'connecting' }
    case 'waiting':
      return { kind: 'waiting' }
    case 'playing':
      return { kind: 'playing' }
    case 'stalled':
      return { kind: 'stalled' }
  }
  if (!state.startsWith('error')) return null
  const raw = state.slice(5).trim()
  const error = raw.toLowerCase()
  if (error.includes('timeout')) return { kind: 'failed', reason: 'нет ответа', raw }
  if (error.includes('refused')) return { kind: 'failed', reason: 'соединение отклонено', raw }
  if (error.includes('unreachable') || error.includes('no route')) return { kind: 'failed', reason: 'камера недоступна по сети', raw }
  const reason = raw.split(':').pop()?.trim()
  return { kind: 'failed', reason: reason || 'нет ответа', raw }
}

const TAG = 'wp-video-rtc'

export function createPlayer(): WaitingPawsPlayer {
  if (!customElements.get(TAG)) customElements.define(TAG, WaitingPawsPlayer)
  return document.createElement(TAG) as WaitingPawsPlayer
}

export type { WaitingPawsPlayer }
