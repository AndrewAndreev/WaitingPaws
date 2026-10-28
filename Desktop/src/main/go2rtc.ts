import { spawn, type ChildProcess } from 'node:child_process'
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:net'
import { dirname, resolve } from 'node:path'
import { tr } from '@core/localization'
import { clock, write } from './log'

/// Runs the bundled go2rtc (built from `GoMobile/` by `scripts/build-go2rtc.mjs`) as a child process and
/// exposes it on `http://127.0.0.1:11984/` (or the next free port) exactly like an external server.
/// The Mac app runs the same go2rtc inside its process; here it is a separate exe that dies with the app
/// (`-parent-pid`), which also lets us restart it — e.g. to open it to the LAN for a linked iPhone.

export type Go2RTCStatus =
  | { kind: 'idle' }
  | { kind: 'starting' }
  | { kind: 'running'; version: string }
  | { kind: 'failed'; message: string }
  /// The app was built without `resources\bin\go2rtc.exe`.
  | { kind: 'unavailable' }

/// Non-standard port so a go2rtc running on the same computer (default 1984) does not clash.
export const PREFERRED_API_PORT = 11984
/// Basic-auth user for LAN clients (the iPhone linked to this computer).
export const LAN_USERNAME = 'waitingpaws'

const DEFAULT_CONFIG = `# Waiting Paws embedded go2rtc. Listen addresses are enforced by the app on every launch.
log:
  level: info

`

export class EmbeddedGo2RTC {
  status: Go2RTCStatus = { kind: 'idle' }
  apiPort = PREFERRED_API_PORT
  webrtcPort = PREFERRED_API_PORT + 1
  /// Whether the API listens on the LAN (with Basic auth for everyone but loopback).
  lanEnabled = false
  private child: ChildProcess | null = null
  private listeners = new Set<(status: Go2RTCStatus) => void>()
  private stopping = false
  private restarts = 0
  /// The LAN password of the last start (null: loopback only); a restart after a crash uses it too.
  private lanPassword: string | null = null
  /// A restart after a crash, waiting its turn; `stop()` cancels it.
  private restartTimer: NodeJS.Timeout | null = null
  /// Bumped by `stop()`: a start still looking for free ports gives up.
  private generation = 0
  /// Someone else's go2rtc answered on our port.
  private foreign = false

  constructor(
    private readonly binary: string,
    private readonly configPath: string,
  ) {}

  get baseURL(): string {
    return `http://127.0.0.1:${this.apiPort}/`
  }

  get isRunning(): boolean {
    return this.status.kind === 'running'
  }

  /// Running, starting or about to restart after a crash, with the API open to the LAN.
  get isOpenToLAN(): boolean {
    return this.lanEnabled && (this.child !== null || this.restartTimer !== null || this.status.kind === 'starting')
  }

  onStatus(listener: (status: Go2RTCStatus) => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  private setStatus(status: Go2RTCStatus): void {
    this.status = status
    for (const listener of this.listeners) listener(status)
  }

  /// Starts go2rtc; `lanPassword` also opens the API on the LAN (Basic auth, loopback stays open for the app).
  async start(lanPassword: string | null): Promise<void> {
    if (this.status.kind === 'starting' || this.status.kind === 'running') return
    if (!existsSync(this.binary)) {
      write(`[go2rtc] ${this.binary} is missing: the bundled server is unavailable`)
      this.setStatus({ kind: 'unavailable' })
      return
    }
    // A restart after a crash still waiting is this start.
    if (this.restartTimer) clearTimeout(this.restartTimer)
    this.restartTimer = null
    this.setStatus({ kind: 'starting' })
    this.stopping = false
    this.lanPassword = lanPassword
    this.lanEnabled = lanPassword !== null
    const generation = this.generation

    const ports = await freePorts(this.lanEnabled)
    if (generation !== this.generation) return
    if (!ports) {
      const [first, last] = [PREFERRED_API_PORT, PREFERRED_API_PORT + 29]
      this.setStatus({
        kind: 'failed',
        message: tr(`Порты ${first}–${last} заняты другими программами — go2rtc негде запустить.`, `Ports ${first}–${last} are taken by other apps — go2rtc has nowhere to run.`),
      })
      return
    }
    if (ports.api !== PREFERRED_API_PORT) {
      write(`[go2rtc] port ${PREFERRED_API_PORT} is taken, using ${ports.api}`)
    }
    this.apiPort = ports.api
    this.webrtcPort = ports.webrtc

    try {
      mkdirSync(dirname(this.configPath), { recursive: true })
      if (!existsSync(this.configPath)) writeFileSync(this.configPath, DEFAULT_CONFIG)
    } catch (error) {
      this.setStatus({ kind: 'failed', message: String(error) })
      return
    }

    const args = ['-config', this.configPath, '-config', this.overrides(lanPassword), '-parent-pid', String(process.pid)]
    const child = spawn(this.binary, args, { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] })
    this.child = child
    const pipe = (stream: NodeJS.ReadableStream | null) => {
      let rest = ''
      stream?.setEncoding('utf8')
      stream?.on('data', (chunk: string) => {
        const lines = (rest + chunk).split(/\r?\n/)
        rest = lines.pop() ?? ''
        for (const line of lines) if (line.trim()) write(`[go2rtc] ${line}`)
      })
    }
    pipe(child.stdout)
    pipe(child.stderr)
    child.on('exit', (code, signal) => {
      if (this.child !== child) return
      this.child = null
      write(`[go2rtc] ${clock()} exited (code ${code ?? '-'}, signal ${signal ?? '-'})`)
      if (this.stopping) {
        this.setStatus({ kind: 'idle' })
        return
      }
      // A crash: try again a few times, then say so. With the password of the latest start: a forgotten iPhone's
      // must not come back.
      if (this.restarts < 3) {
        this.restarts += 1
        this.setStatus({ kind: 'idle' })
        this.restartTimer = setTimeout(() => {
          this.restartTimer = null
          void this.start(this.lanPassword)
        }, 1000 * this.restarts)
      } else {
        this.setStatus({ kind: 'failed', message: tr('go2rtc перестал отвечать. Перезапустите приложение.', 'go2rtc stopped responding. Restart the app.') })
      }
    })
    child.on('error', (error) => {
      write(`[go2rtc] failed to start: ${error.message}`)
      this.setStatus({ kind: 'failed', message: error.message })
    })

    this.foreign = false
    const version = await this.waitUntilReachable()
    if (this.child !== child) return
    if (version === null && this.foreign && this.restarts < 3) {
      // The port was taken between our check and go2rtc's bind: start again on the next free pair.
      write(`[go2rtc] port ${this.apiPort} answered by another go2rtc, trying the next one`)
      this.restarts += 1
      this.stopping = true
      child.kill()
      this.child = null
      // Still starting meanwhile (see `isOpenToLAN`).
      await new Promise((resolve) => setTimeout(resolve, 300))
      if (generation !== this.generation) return
      this.setStatus({ kind: 'idle' })
      return this.start(this.lanPassword)
    }
    if (version !== null) {
      this.restarts = 0
      this.setStatus({ kind: 'running', version: version.split('+')[0] || version })
    } else {
      this.setStatus({
        kind: 'failed',
        message: tr(`go2rtc запустился, но API на 127.0.0.1:${this.apiPort} не отвечает`, `go2rtc started, but its API at 127.0.0.1:${this.apiPort} doesn’t respond`),
      })
    }
  }

  async stop(): Promise<void> {
    // A restart after a crash or a start still looking for ports does not come any more.
    this.generation += 1
    if (this.restartTimer) clearTimeout(this.restartTimer)
    this.restartTimer = null
    const child = this.child
    if (!child) {
      if (this.status.kind === 'starting') this.setStatus({ kind: 'idle' })
      return
    }
    this.stopping = true
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        child.kill('SIGKILL')
        resolve()
      }, 3000)
      child.once('exit', () => {
        clearTimeout(timer)
        resolve()
      })
      child.stdin?.end()
      child.kill()
    })
    this.child = null
    this.setStatus({ kind: 'idle' })
  }

  async restart(lanPassword: string | null): Promise<void> {
    await this.stop()
    await this.start(lanPassword)
  }

  /// Inline config merged on top of the file at every launch: loopback only, RTSP server off.
  /// With `lanPassword` the API also listens on the LAN; go2rtc skips auth for loopback requests,
  /// so the app itself keeps talking to 127.0.0.1 without credentials.
  overrides(lanPassword: string | null): string {
    const api = lanPassword
      ? { listen: `:${this.apiPort}`, username: LAN_USERNAME, password: lanPassword }
      : { listen: `127.0.0.1:${this.apiPort}` }
    return JSON.stringify({
      api,
      rtsp: { listen: '' },
      webrtc: { listen: `127.0.0.1:${this.webrtcPort}`, candidates: [`127.0.0.1:${this.webrtcPort}`] },
    })
  }

  /// The version of OUR go2rtc on the port: another go2rtc that got the port first (a second copy of the app started at
  /// the same moment, the user's own go2rtc) answers too, but with another config file.
  private async version(): Promise<string | null> {
    try {
      const response = await fetch(`${this.baseURL}api`, { signal: AbortSignal.timeout(1500) })
      if (!response.ok) return null
      const body = (await response.json()) as { version?: string; config_path?: string }
      if (body.config_path && resolve(body.config_path).toLowerCase() !== resolve(this.configPath).toLowerCase()) {
        this.foreign = true
        return null
      }
      return body.version ?? ''
    } catch {
      return null
    }
  }

  /// Polls `GET /api` for a few seconds after start.
  private async waitUntilReachable(): Promise<string | null> {
    for (let attempt = 0; attempt < 50; attempt++) {
      const version = await this.version()
      if (version !== null) return version
      if (!this.child) return null
      await new Promise((resolve) => setTimeout(resolve, 150))
    }
    return null
  }
}

/// First pair (API, WebRTC) from 11984 up that can be bound right now. A real bind, not an HTTP probe:
/// any process on the port counts, not only another go2rtc.
async function freePorts(lan: boolean): Promise<{ api: number; webrtc: number } | null> {
  for (let api = PREFERRED_API_PORT; api < PREFERRED_API_PORT + 30; api += 2) {
    if ((await canBind(api, lan ? '0.0.0.0' : '127.0.0.1')) && (await canBind(api + 1, '127.0.0.1'))) {
      return { api, webrtc: api + 1 }
    }
  }
  return null
}

function canBind(port: number, host: string): Promise<boolean> {
  return new Promise((resolve) => {
    const server = createServer()
    server.once('error', () => resolve(false))
    server.listen({ port, host, exclusive: true }, () => server.close(() => resolve(true)))
  })
}
