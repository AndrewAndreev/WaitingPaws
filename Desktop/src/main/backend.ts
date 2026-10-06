import { app, clipboard, ClipboardItem, shell } from 'electron'
import { execFile } from 'node:child_process'
import { existsSync, mkdirSync, readdirSync, statSync, unlinkSync } from 'node:fs'
import { basename, join } from 'node:path'
import { Go2RTCClient, Go2RTCServer } from '@core/go2rtcClient'
import { TrainingSession, type TrainingSessionSnapshot } from '@core/trainingSession'
import { TrainingPlan } from '@core/models'
import { SessionLogFormatter, type TrainingRecord } from '@core/sessionLog'
import { setCoreLanguage } from '@core/localization'
import type { AppState, RecordingClip, XiaomiQuality } from '@shared/api'
import type { Settings } from '@shared/settings'
import { EmbeddedGo2RTC, LAN_USERNAME } from './go2rtc'
import { StreamRecorder } from './recorder'
import { MediaFinalizer } from './finalizer'
import { SettingsStore } from './settings'
import { RecordStore } from './storage'
import { CameraModesController } from './cameraModes'
import { SyncHost } from './sync/host'
import { clock, currentLogFile, write as log } from './log'
import { argValue, paths, isUIPreview } from './paths'
import { demoHistory, demoPlan, demoReplay } from './demo'
import { legalText } from './legal'
import packageInfo from '../../package.json'

/// One part of a recording: the file and when it was requested (a new part starts each time the camera stream
/// breaks off and comes back).
interface RecordingSegment {
  path: string
  startedAt: number
  bytes: number
}

/// The backend of the app — the Mac app's `AppModel` without the UI: settings, the bundled go2rtc, the running
/// training, recording (in parts when the camera drops out), finalizing, history and the iPhone link. The UI gets
/// `AppState` snapshots and calls the methods in `handlers` (see shared/api.ts).
export class AppBackend {
  readonly go2rtc = new EmbeddedGo2RTC(paths.go2rtcBinary, paths.go2rtcConfig)
  readonly store = new RecordStore(paths.documentsRoot)
  readonly recorder = new StreamRecorder()
  readonly cameraModes: CameraModesController
  readonly sync: SyncHost

  private session: TrainingSession | null = null
  private sessionUnsubscribe: (() => void) | null = null
  private pendingPlan: TrainingPlan | null = null
  private pendingOriginal: TrainingPlan | null = null
  private history: TrainingRecord[] = []
  private clips: RecordingClip[] = []
  private historyRevision = 0
  private lastRecord: TrainingRecord | null = null
  private lastClip: RecordingClip | null = null
  private errorMessage: string | null = null

  private currentRecordingPath: string | null = null
  private segments: RecordingSegment[] = []
  private resuming = false
  private resumeTimer: NodeJS.Timeout | null = null
  private lastRequestedPart = 0
  private finalizing = new Set<string>()
  private finalizeTasks = new Map<string, Promise<void>>()

  private xiaomiQuality: XiaomiQuality | null = null
  private xiaomiSource: string | null = null
  private videoSize: { width: number; height: number } | null = null
  private playerGeneration = 0

  private tickTimer: NodeJS.Timeout | null = null
  private listeners = new Set<(state: AppState) => void>()
  private emitScheduled = false
  private ready = false

  constructor(
    readonly settings: SettingsStore,
    private readonly finalizer: MediaFinalizer,
  ) {
    this.applyLanguage()
    this.cameraModes = new CameraModesController(join(paths.cacheDirectory, 'MiotSpec'), () => this.emit())
    this.sync = new SyncHost({
      state: () => this.syncState(),
      command: (command) => this.applyRemote(command),
      access: () => ({ port: this.go2rtc.apiPort, username: LAN_USERNAME, password: this.go2rtc.lanEnabled ? this.settings.lanPassword : '' }),
      onDeviceForgotten: () => void this.rotateLanPassword(),
      onChange: () => this.emit(),
    })
    this.recorder.onEnded = (reason) => this.recordingStreamEnded(reason)
    this.go2rtc.onStatus((status) => {
      if (status.kind === 'running') {
        this.playerGeneration += 1
        void this.refreshCamera()
      }
      this.emit()
    })
    this.settings.onChange(() => {
      this.applyLanguage()
      this.emit()
    })
  }

  async start(): Promise<void> {
    await this.reloadHistory()
    this.applyDemoArguments()
    this.ready = true
    this.emit()
    if (this.settings.value.connectionMode === 'embedded' && !isUIPreview) {
      await this.go2rtc.start(this.settings.value.shareWithIPhone ? this.settings.lanPassword : null)
    } else {
      void this.refreshCamera()
    }
    if (this.settings.value.shareWithIPhone && !isUIPreview) this.sync.start()
    this.startStreamDiagnostics()
  }

  /// Launch arguments for checks and screenshots (nothing is written): `--demo-history` (sample trainings),
  /// `--demo-plan` (a parsed schedule waiting), `--demo-session` with `--demo-exits-done=N` and
  /// `--demo-phase=leaving|away|break`.
  private applyDemoArguments(): void {
    const args = process.argv
    if (args.includes('--demo-history')) {
      this.history = demoHistory()
      this.historyRevision += 1
    }
    if (args.includes('--demo-plan')) this.setPending(demoPlan())
    if (args.includes('--demo-session')) {
      const plan = demoPlan()
      const done = Number(argValue('demo-exits-done') ?? 0)
      const session = done > 0 ? demoReplay(plan, done) : new TrainingSession(plan)
      this.session = session
      this.sessionUnsubscribe = session.subscribe(() => this.emit())
      const phase = argValue('demo-phase')
      if (phase === 'leaving') session.startExit()
      if (phase === 'away') session.markBehindDoor()
      this.startTicking()
    }
    // `--debug-join=<out.mp4>|<part.mp4>@<seconds>|…`: the recording finalizer on given files (checks without a camera
    // outage); the result is logged.
    const join = argValue('debug-join')
    if (join) {
      const [output, ...parts] = join.split('|')
      void this.finalizer
        .write(parts.map((part) => ({ path: part.split('@')[0], offset: Number(part.split('@')[1] ?? 0) })), output)
        .then(() => log(`[debug] joined into ${output}`), (error: Error) => log(`[debug] join failed: ${error.message}`))
    }
    this.emit()
  }

  async shutdown(): Promise<void> {
    if (this.session) {
      // Closing the window during a training keeps what was done: the record and the video are saved.
      this.session.finish()
      await this.completeSessionIfNeeded()
    } else if (this.isRecordingLocally) {
      await this.stopRecording(false)
    }
    await Promise.allSettled([...this.finalizeTasks.values()])
    this.sync.stop()
    await this.go2rtc.stop()
  }

  // MARK: - State

  onState(listener: (state: AppState) => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  /// Coalesces many changes in one tick into one snapshot for the UI.
  emit(): void {
    if (this.emitScheduled) return
    this.emitScheduled = true
    setImmediate(() => {
      this.emitScheduled = false
      const state = this.state()
      for (const listener of this.listeners) listener(state)
      this.sync.broadcast()
    })
  }

  state(): AppState {
    const settings = this.settings.publicValue
    const status = this.go2rtc.status
    const server = this.server()
    return {
      ready: this.ready,
      // From package.json at build time: right in development builds started from another folder too.
      version: packageInfo.version,
      platform: process.platform,
      systemLocale: app.getSystemLocale(),
      settings,
      go2rtc: {
        status: status.kind,
        message: status.kind === 'failed' ? status.message : null,
        version: status.kind === 'running' ? status.version : null,
        port: this.go2rtc.apiPort,
        lanEnabled: this.go2rtc.lanEnabled,
      },
      server: server ? { baseURL: server.baseURL, hasCredentials: Go2RTCServer.hasCredentials(server) } : null,
      session: this.session?.snapshot ?? null,
      pendingPlan: this.pendingPlan,
      pendingOriginal: this.pendingOriginal,
      recording: { since: this.localRecordingStartedAt, resuming: this.resuming },
      lastRecord: this.lastRecord,
      lastClip: this.lastClip,
      historyRevision: this.historyRevision,
      finalizing: [...this.finalizing],
      camera: { xiaomiQuality: this.xiaomiQuality, xiaomiSource: this.xiaomiSource, videoSize: this.videoSize, playerGeneration: this.playerGeneration },
      cameraModes: this.cameraModes.view(),
      sync: { ...this.sync.view(), hostName: this.sync.name },
      errorMessage: this.errorMessage,
      paths: {
        documents: paths.documentsRoot,
        recordings: this.store.recordingsDirectory,
        sessions: this.store.sessionsDirectory,
        logs: paths.logsDirectory,
      },
    }
  }

  private applyLanguage(): void {
    const preference = this.settings.value.language
    const language = preference === 'system' ? (app.getPreferredSystemLanguages()[0] ?? app.getLocale()).toLowerCase().startsWith('ru') ? 'ru' : 'en' : preference
    setCoreLanguage(language)
  }

  private fail(message: string): void {
    this.errorMessage = message
    log(`[app] error: ${message}`)
    this.emit()
  }

  // MARK: - Server

  /// The go2rtc the player, recorder and settings talk to: the bundled one, or the user's server.
  server(): Go2RTCServer | null {
    const value = this.settings.value
    if (value.connectionMode === 'embedded') return Go2RTCServer.make(this.go2rtc.baseURL)
    const url = Go2RTCServer.parse(value.serverURL)
    return url ? Go2RTCServer.make(url, value.serverUsername, value.serverPassword) : null
  }

  client(): Go2RTCClient | null {
    const server = this.server()
    return server ? new Go2RTCClient(server) : null
  }

  get isConfigured(): boolean {
    return this.server() !== null && this.settings.value.streamName !== ''
  }

  /// For the network rules: requests to the active go2rtc (http or ws) get no Origin and the server's credentials.
  serverForRequest(url: string): { authorization: string | null } | null {
    const server = this.server()
    if (!server) return null
    try {
      const target = new URL(url)
      const base = new URL(server.baseURL)
      if (target.host !== base.host) return null
      return { authorization: Go2RTCServer.authorizationHeader(server) }
    } catch {
      return null
    }
  }

  private async waitForServer(): Promise<void> {
    if (this.settings.value.connectionMode !== 'embedded') return
    for (let i = 0; i < 80; i++) {
      const kind = this.go2rtc.status.kind
      if (kind === 'running' || kind === 'failed' || kind === 'unavailable') return
      await delay(100)
    }
  }

  // MARK: - Session

  startSession(plan: TrainingPlan): void {
    if (this.session) return
    const renumbered = TrainingPlan.renumbered(plan)
    // A recording that broke off earlier must not end up attached to this session.
    if (!this.isRecordingLocally) this.currentRecordingPath = null
    const session = new TrainingSession(renumbered)
    session.autoFinishAfterLastBreak = this.settings.value.autoFinishAfterLastBreak
    this.session = session
    this.sessionUnsubscribe = session.subscribe(() => this.emit())
    this.lastRecord = null
    this.lastClip = null
    this.setPending(null)
    log(`[session] started «${renumbered.title}», ${renumbered.exits.length} exits`)
    // Without a camera the training is the timer and the log only.
    if (this.settings.value.autoRecord && this.isConfigured && !isUIPreview) {
      if (this.isRecordingLocally) this.session.noteRecording(true, this.currentRecordingPath ? basename(this.currentRecordingPath) : null)
      else void this.startRecording()
    }
    this.startTicking()
    this.emit()
  }

  async finishSession(): Promise<void> {
    if (!this.session) return
    this.session.finish()
    await this.completeSessionIfNeeded()
  }

  /// Drops the running session without saving anything (asked explicitly by the user).
  async abandonSession(): Promise<void> {
    await this.stopRecording(true)
    this.endSession()
    this.lastRecord = null
    this.emit()
  }

  private endSession(): void {
    this.sessionUnsubscribe?.()
    this.sessionUnsubscribe = null
    this.session = null
    if (this.tickTimer) clearInterval(this.tickTimer)
    this.tickTimer = null
  }

  private startTicking(): void {
    if (this.tickTimer) clearInterval(this.tickTimer)
    this.tickTimer = setInterval(() => {
      this.session?.tick()
      void this.completeSessionIfNeeded()
    }, 500)
  }

  private completing = false

  private async completeSessionIfNeeded(): Promise<void> {
    const session = this.session
    if (!session || !session.isFinished || this.completing) return
    this.completing = true
    try {
      const fileName = this.currentRecordingPath ? basename(this.currentRecordingPath) : null
      await this.stopRecording(false)
      const record = session.makeRecord(fileName)
      try {
        await this.store.save(record)
      } catch (error) {
        this.fail(`Не удалось сохранить лог: ${(error as Error).message}`)
      }
      this.history = [record, ...this.history.filter((item) => item.id !== record.id)]
      this.historyRevision += 1
      this.lastRecord = record
      this.currentRecordingPath = null
      this.endSession()
      log(`[session] finished, ${record.results.length} attempts, video ${fileName ?? 'none'}`)
      this.emit()
    } finally {
      this.completing = false
    }
  }

  /// A button press here (`at` null: now) or on a linked iPhone (`at`: when it was pressed there).
  private sessionCommand(command: string, at: number | null = null): void {
    const session = this.session
    if (!session) return
    switch (command) {
      case 'startExit':
        session.startExit(at)
        break
      case 'markBehindDoor':
        session.markBehindDoor(at)
        break
      case 'endExit':
        session.endExit(at)
        break
      case 'resetExit':
        session.resetExit(at)
        break
      case 'finish':
        void this.finishSession()
        return
    }
    void this.completeSessionIfNeeded()
  }

  /// The running session's schedule, edited here or on a linked iPhone. False when the edit drops exits already done.
  /// `quiet`: a step of an edit still going on (no log note); `changesSince`: log the whole edit against that plan.
  updateSessionPlan(plan: TrainingPlan, options: { quiet?: boolean; changesSince?: TrainingPlan | null } = {}): boolean {
    const updated = this.session?.updatePlan(plan, options) ?? false
    if (updated) this.emit()
    return updated
  }

  /// A new waiting schedule (paste, «Повторить», a linked iPhone); null clears it.
  setPending(plan: TrainingPlan | null, keepOriginal = false): void {
    this.pendingPlan = plan
    if (!keepOriginal) this.pendingOriginal = plan
    this.emit()
  }

  // MARK: - Recording

  get isRecordingLocally(): boolean {
    return this.recorder.isRecording || this.resuming
  }

  /// When the recording in progress started (its first part).
  get localRecordingStartedAt(): number | null {
    if (!this.isRecordingLocally) return null
    return this.segments[0]?.startedAt ?? this.recorder.startedAt
  }

  async toggleRecording(): Promise<void> {
    if (this.isRecordingLocally) await this.stopRecording(false)
    else await this.startRecording()
  }

  async startRecording(): Promise<void> {
    await this.waitForServer()
    const client = this.client()
    const stream = this.settings.value.streamName
    if (!client || !stream) {
      this.fail('Камера не настроена')
      return
    }
    if (this.isRecordingLocally) return
    const plan = this.session?.snapshot.plan ?? TrainingPlan.make({ title: 'Запись' })
    const path = await this.store.newRecordingPath(plan)
    if (this.isRecordingLocally) return
    try {
      this.recorder.start(client.mp4URL(stream), Go2RTCServer.authorizationHeader(client.server), path)
      this.currentRecordingPath = path
      this.segments = [{ path, startedAt: this.recorder.startedAt ?? Date.now(), bytes: 0 }]
      this.session?.noteRecording(true, basename(path))
      if (!this.session) {
        // A recording without a training replaces whatever summary was shown.
        this.lastRecord = null
        this.lastClip = null
      }
      log(`[rec] started ${basename(path)}`)
    } catch (error) {
      this.fail(`Не удалось начать запись: ${(error as Error).message}`)
    }
    this.emit()
  }

  async stopRecording(deleteFile: boolean): Promise<void> {
    const wasRecording = this.isRecordingLocally
    if (this.resumeTimer) clearTimeout(this.resumeTimer)
    this.resumeTimer = null
    this.resuming = false
    if (!wasRecording && !this.currentRecordingPath) return
    if (this.recorder.isRecording) {
      await this.recorder.stop()
      this.noteSegmentEnded()
    }
    const main = this.currentRecordingPath
    const startedAt = this.segments[0]?.startedAt ?? this.recorder.startedAt ?? Date.now()
    // Parts that got nothing (the camera was still away) are dropped; the first file stays as the name.
    const filled = this.segments.filter((segment) => segment.bytes > 0)
    for (const part of this.segments.slice(1)) if (part.bytes === 0) removeQuietly(part.path)
    this.segments = []
    if (wasRecording) {
      this.session?.noteRecording(false)
      log(`[rec] stopped ${main ? basename(main) : '?'} parts=${filled.length} error=${this.recorder.lastError ?? 'none'}`)
    }
    this.emit()
    // Nothing arrived (stopped right away, or the stream never delivered): drop the empty file quietly.
    if (wasRecording && filled.length === 0 && main) {
      removeQuietly(main)
      this.currentRecordingPath = null
      return
    }
    if (deleteFile && main) {
      removeQuietly(main)
      for (const part of filled) if (part.path !== main) removeQuietly(part.path)
      this.currentRecordingPath = null
      return
    }
    if (!wasRecording || !main) return
    const needsJoin = filled.length > 1 || filled[0]?.path !== main
    const task = (needsJoin ? this.joinRecording(main, filled, startedAt) : this.finalizeRecording(main)).then(async () => {
      await this.reloadClips()
      this.emit()
    })
    // Quitting waits for it (see shutdown).
    if (needsJoin) {
      const key = `join:${basename(main)}`
      this.finalizeTasks.set(key, task)
      void task.finally(() => this.finalizeTasks.delete(key))
    }
    if (!this.session) {
      // Without a training nothing else will claim the file: it becomes a standalone recording.
      this.currentRecordingPath = null
      this.lastClip = { fileName: basename(main), date: startedAt, size: safeSize(main) }
      await this.reloadClips()
      this.historyRevision += 1
    }
    this.emit()
    if (deleteFile) return
    void task
  }

  private noteSegmentEnded(): void {
    const last = this.segments[this.segments.length - 1]
    if (last && last.path === this.recorder.filePath) last.bytes = this.recorder.bytesWritten
  }

  /// The recording's stream ended without a stop: go2rtc lost the camera (it reconnects by itself) or refused the
  /// stream. The recording goes on in a new part as soon as the stream is back, instead of silently ending here.
  private recordingStreamEnded(reason: string | null): void {
    const main = this.currentRecordingPath
    if (!main || !this.segments.length) return
    this.noteSegmentEnded()
    const last = this.segments[this.segments.length - 1]
    // A try that got nothing (the camera still away) is not a part, and not worth a line in the log each time.
    if (last && last.bytes === 0 && last.path !== main) {
      removeQuietly(last.path)
      this.segments.pop()
    } else {
      log(`[rec] the camera stream broke off (${reason ?? 'ended'}): going on when the camera is back`)
    }
    this.resuming = true
    if (this.resumeTimer) clearTimeout(this.resumeTimer)
    this.resumeTimer = setTimeout(() => this.startNextRecordingPart(), 2000)
    this.emit()
  }

  private startNextRecordingPart(): void {
    const main = this.currentRecordingPath
    const client = this.client()
    const stream = this.settings.value.streamName
    if (!this.resuming || !main || !client || !stream) return
    const number = this.segments.length + 1
    const directory = join(this.store.recordingsDirectory, '.parts')
    mkdirSync(directory, { recursive: true })
    const path = join(directory, `${basename(main, '.mp4')}-part${number}.mp4`)
    try {
      this.recorder.start(client.mp4URL(stream), Go2RTCServer.authorizationHeader(client.server), path)
      this.segments.push({ path, startedAt: this.recorder.startedAt ?? Date.now(), bytes: 0 })
      this.resuming = false
      if (number !== this.lastRequestedPart) log(`[rec] waiting for the camera to write part ${number}`)
      this.lastRequestedPart = number
    } catch (error) {
      log(`[rec] part ${number} failed: ${(error as Error).message}`)
      this.recordingStreamEnded((error as Error).message)
    }
    this.emit()
  }

  /// Puts the parts of a recording the camera broke off back into its first file, each at its own time.
  private async joinRecording(output: string, parts: RecordingSegment[], startedAt: number): Promise<void> {
    const name = basename(output)
    this.finalizing.add(name)
    this.emit()
    try {
      await this.finalizer.write(
        parts.map((part) => ({ path: part.path, offset: Math.max(0, (part.startedAt - startedAt) / 1000) })),
        output,
      )
      for (const part of parts) if (part.path !== output) removeQuietly(part.path)
      log(`[rec] joined ${parts.length} parts into ${name}`)
    } catch (error) {
      log(`[rec] joining ${name} failed: ${(error as Error).message}`)
    } finally {
      this.finalizing.delete(name)
      this.emit()
    }
  }

  /// Turns a finished recording into a regular MP4 with an AAC sound track. Cheap for files that are already done;
  /// concurrent calls for one file share the work.
  finalizeRecording(path: string): Promise<void> {
    const name = basename(path)
    const running = this.finalizeTasks.get(name)
    if (running) return running
    const task = (async () => {
      this.finalizing.add(name)
      this.emit()
      try {
        if (await this.finalizer.needsFinalizing(path)) {
          await this.finalizer.write([{ path, offset: 0 }], path)
          log(`[rec] finalized ${name}`)
        }
      } catch (error) {
        log(`[rec] finalize failed ${name}: ${(error as Error).message}`)
      } finally {
        this.finalizing.delete(name)
        this.finalizeTasks.delete(name)
        this.emit()
      }
    })()
    this.finalizeTasks.set(name, task)
    return task
  }

  // MARK: - Camera quality and modes

  private static query(source: string, name: string): string | null {
    const query = source.split('?')[1] ?? ''
    for (const part of query.split('&')) {
      const [key, value] = part.split('=')
      if (key === name) return decodeURIComponent(value ?? '')
    }
    return null
  }

  /// The selected stream's `xiaomi://` source. While the camera is live, `/api/streams` describes the running
  /// connection without the source URL, so the config file is read instead.
  private async readXiaomiSource(client: Go2RTCClient, name = this.settings.value.streamName): Promise<string | null> {
    try {
      const stream = (await client.streams()).find((item) => item.name === name)
      const source = stream?.sources.find((item) => item.startsWith('xiaomi://'))
      if (source) return source
    } catch {
      // Fall through to the config.
    }
    try {
      return (await client.configuredSources(name)).find((item) => item.startsWith('xiaomi://')) ?? null
    } catch {
      return null
    }
  }

  async refreshCamera(): Promise<void> {
    await this.waitForServer()
    const client = this.client()
    if (!client || !this.settings.value.streamName || isUIPreview) {
      this.xiaomiQuality = null
      this.xiaomiSource = null
      await this.cameraModes.load(null, null)
      this.emit()
      return
    }
    const source = await this.readXiaomiSource(client)
    this.xiaomiSource = source
    if (source) {
      const raw = AppBackend.query(source, 'subtype')
      this.xiaomiQuality = raw === null || raw === 'hd' ? '2' : raw === 'sd' ? '1' : (['auto', '1', '2', '3'].includes(raw) ? raw : '2') as XiaomiQuality
    } else {
      this.xiaomiQuality = null
    }
    this.emit()
    await this.cameraModes.load(client, source)
  }

  /// Re-registers the stream with `subtype=<quality>`: the one quality of the picture and of the recordings.
  /// go2rtc then creates a new stream connection, so every player reconnects.
  async setQuality(quality: XiaomiQuality): Promise<void> {
    const client = this.client()
    if (!client) return
    const source = await this.readXiaomiSource(client)
    if (!source) {
      this.fail('Не удалось сменить качество: go2rtc не отдал адрес камеры')
      return
    }
    const [base, query = ''] = source.split('?')
    const items = query.split('&').filter((item) => item && !item.startsWith('subtype='))
    items.push(`subtype=${quality}`)
    const updated = `${base}?${items.join('&')}`
    try {
      await client.addStream(this.settings.value.streamName, updated)
      this.xiaomiQuality = quality
      this.xiaomiSource = updated
      this.videoSize = null
      this.playerGeneration += 1
      log(`[camera] quality ${quality}`)
    } catch (error) {
      this.fail(`Не удалось сменить качество: ${(error as Error).message}`)
    }
    this.emit()
  }

  /// Remembers what the current level gave. Only for an explicit `subtype`: without one go2rtc picks a level by
  /// model, which is not necessarily the «HD» shown then.
  private reportVideoSize(width: number, height: number): void {
    this.videoSize = { width, height }
    const quality = this.xiaomiQuality
    const source = this.xiaomiSource
    if (quality && quality !== 'auto' && source && AppBackend.query(source, 'subtype') === quality) {
      const did = AppBackend.query(source, 'did')
      if (did) {
        const seen = `${width}x${height}`
        const all = this.settings.value.qualityResolutions
        if (all[did]?.[quality] !== seen) this.settings.update({ qualityResolutions: { ...all, [did]: { ...all[did], [quality]: seen } } })
      }
    }
    this.emit()
  }

  // MARK: - Xiaomi account and camera choice

  /// «Выйти из аккаунта Xiaomi»: go2rtc forgets the account's token, its cameras are removed from go2rtc, and when
  /// one of them was selected the app goes on without a camera.
  async signOutOfXiaomi(accountID: string): Promise<void> {
    await this.waitForServer()
    const client = this.client()
    if (!client) return
    await client.xiaomiLogout(accountID)
    log(`[xiaomi] signed out of account ${accountID}`)
    const prefix = `xiaomi://${accountID}:`
    const names = (await client.streams().catch(() => [])).map((stream) => stream.name)
    const sources = await client.configuredSourcesOf(names).catch(() => ({}) as Record<string, string[]>)
    let removedSelected = this.xiaomiSource?.startsWith(prefix) ?? false
    for (const [name, list] of Object.entries(sources)) {
      if (!list.some((source) => source.startsWith(prefix))) continue
      await client.deleteStream(name).catch(() => undefined)
      if (name === this.settings.value.streamName) removedSelected = true
    }
    const patch: Partial<Settings> = {}
    if (this.settings.value.xiaomiAccountID === accountID) patch.xiaomiAccountID = ''
    if (removedSelected) Object.assign(patch, { streamName: '', cameraTitle: '', withoutCamera: true })
    this.settings.update(patch)
    if (removedSelected) {
      this.xiaomiSource = null
      this.xiaomiQuality = null
      this.videoSize = null
      await this.cameraModes.load(null, null)
    }
    this.emit()
  }

  /// The camera chosen in the picker: settings, then quality and modes of the new camera.
  async selectStream(patch: Partial<Settings>): Promise<void> {
    this.settings.update({ ...patch, withoutCamera: false })
    this.videoSize = null
    this.playerGeneration += 1
    this.emit()
    await this.refreshCamera()
  }

  /// A request of the UI's go2rtc client (camera picker, Xiaomi sign-in, server setup) made from here: no CORS, no
  /// browser Origin. Only http(s) to the active server, loopback or a private network address.
  async go2rtcFetch(request: { url: string; method?: string; headers?: Record<string, string>; body?: string | Uint8Array }): Promise<{ status: number; statusText: string; headers: Record<string, string>; body: Uint8Array }> {
    const target = new URL(request.url)
    if (!/^https?:$/.test(target.protocol)) throw new Error('only http(s)')
    const server = this.server()
    const sameServer = server ? new URL(server.baseURL).host === target.host : false
    // Another host only for go2rtc's API (checking a server the user is typing in): local addresses, or `/api`.
    if (!sameServer && !isLocalHost(target.hostname) && !/\/api(\/|$)/.test(target.pathname)) throw new Error('only go2rtc servers')
    const headers = { ...(request.headers ?? {}) }
    const hasAuthorization = Object.keys(headers).some((name) => name.toLowerCase() === 'authorization')
    if (sameServer && server && Go2RTCServer.hasCredentials(server) && !hasAuthorization) {
      headers.Authorization = Go2RTCServer.authorizationHeader(server) ?? ''
    }
    const response = await fetch(target, {
      method: request.method ?? 'GET',
      headers,
      body: request.body as RequestInit['body'],
      signal: AbortSignal.timeout(25_000),
    })
    const body = new Uint8Array(await response.arrayBuffer())
    return { status: response.status, statusText: response.statusText, headers: Object.fromEntries(response.headers.entries()), body }
  }

  // MARK: - History

  async reloadHistory(): Promise<void> {
    try {
      this.history = await this.store.loadAll()
    } catch (error) {
      log(`[history] load failed: ${(error as Error).message}`)
      this.history = []
    }
    await this.reloadClips()
    this.historyRevision += 1
    this.emit()
  }

  private async reloadClips(): Promise<void> {
    const active = this.isRecordingLocally && this.currentRecordingPath ? basename(this.currentRecordingPath) : null
    this.clips = (await this.store.standaloneRecordings(this.history))
      .filter((name) => name !== active && !this.finalizingTemp(name))
      .map((name) => {
        const path = join(this.store.recordingsDirectory, name)
        const stat = safeStat(path)
        return { fileName: name, date: stat ? stat.birthtimeMs || stat.mtimeMs : 0, size: stat?.size ?? 0 }
      })
      .sort((a, b) => b.date - a.date)
  }

  private finalizingTemp(name: string): boolean {
    return name.includes('.finalizing-')
  }

  private async deleteRecord(id: string, includingRecording: boolean): Promise<void> {
    const record = this.history.find((item) => item.id === id)
    if (!record) return
    await this.store.delete(record, includingRecording)
    this.history = this.history.filter((item) => item.id !== id)
    if (this.lastRecord?.id === id) this.lastRecord = null
    await this.reloadClips()
    this.historyRevision += 1
    this.emit()
  }

  private deleteClip(fileName: string): void {
    removeQuietly(join(this.store.recordingsDirectory, basename(fileName)))
    this.clips = this.clips.filter((clip) => clip.fileName !== fileName)
    if (this.lastClip?.fileName === fileName) this.lastClip = null
    this.historyRevision += 1
    this.emit()
  }

  /// Removes every saved session with its log and video, and every standalone recording.
  private async deleteAll(): Promise<void> {
    for (const record of this.history) await this.store.delete(record, true)
    for (const clip of this.clips) removeQuietly(join(this.store.recordingsDirectory, clip.fileName))
    this.history = []
    this.clips = []
    this.lastRecord = null
    this.lastClip = null
    this.historyRevision += 1
    this.emit()
  }

  // MARK: - iPhone link

  private syncState() {
    const value = this.settings.value
    return {
      session: this.session?.snapshot ?? null,
      recordingSince: this.localRecordingStartedAt,
      cameraReady: this.isConfigured && (value.connectionMode === 'external' || this.go2rtc.isRunning),
      cameraTitle: value.cameraTitle || value.streamName,
      streamName: value.streamName,
      lastRecord: this.lastRecord,
      pendingPlan: this.session ? null : this.pendingPlan,
      cameraSource: this.xiaomiSource,
      streamRevision: this.playerGeneration,
    }
  }

  /// A button press from a linked iPhone.
  private applyRemote(command: {
    kind: string
    command?: string
    plan?: TrainingPlan | null
    at?: number | null
    quiet?: boolean
    since?: TrainingPlan | null
  }): void {
    switch (command.kind) {
      case 'session':
        if (command.command === 'finish') void this.finishSession()
        else if (command.command) this.sessionCommand(command.command, command.at ?? null)
        break
      case 'startSession':
        if (!this.session && command.plan) this.startSession(command.plan)
        break
      case 'setPendingPlan': {
        if (this.session) return
        const plan = command.plan ?? null
        // An edit of the same pasted text keeps «Как у тренера»; another text replaces both.
        if (plan && this.pendingPlan && this.pendingPlan.rawText === plan.rawText && plan.rawText) this.setPending(plan, true)
        else this.setPending(plan)
        break
      }
      case 'updateSessionPlan':
        if (command.plan) this.updateSessionPlan(command.plan, { quiet: command.quiet, changesSince: command.since })
        break
      case 'abandonSession':
        void this.abandonSession()
        break
      case 'startRecording':
        if (!this.isRecordingLocally) void this.startRecording()
        break
      case 'stopRecording':
        void this.stopRecording(false)
        break
    }
  }

  /// A forgotten iPhone must not keep watching the camera with the password it was given: new password, and the
  /// bundled go2rtc restarts with it (the players reconnect by themselves).
  private async rotateLanPassword(): Promise<void> {
    const password = this.settings.rotateLanPassword()
    if (this.settings.value.connectionMode === 'embedded' && this.go2rtc.lanEnabled) await this.go2rtc.restart(password)
    this.sync.refreshAccess()
  }

  private async setSharing(enabled: boolean): Promise<void> {
    this.settings.update({ shareWithIPhone: enabled })
    if (enabled) this.sync.start()
    else this.sync.stop()
    // The API listens on the LAN only while sharing is on.
    if (this.settings.value.connectionMode === 'embedded' && this.go2rtc.lanEnabled !== enabled) {
      await this.go2rtc.restart(enabled ? this.settings.lanPassword : null)
    }
    this.emit()
  }

  // MARK: - Diagnostics

  /// Every 10 s: frames go2rtc dropped because a viewer (the player, the recording, a linked iPhone) fell behind.
  private startStreamDiagnostics(): void {
    let last: Record<string, number> = {}
    setInterval(async () => {
      if (this.settings.value.connectionMode !== 'embedded' || !this.go2rtc.isRunning || !this.settings.value.streamName) return
      const client = this.client()
      if (!client) return
      try {
        const info = JSON.parse(await client.streamInfo(this.settings.value.streamName)) as { consumers?: Record<string, unknown>[] }
        const drops: Record<string, number> = {}
        for (const consumer of info.consumers ?? []) {
          const name = ['format_name', 'protocol', 'remote_addr'].map((key) => consumer[key]).filter((value) => typeof value === 'string').join(' ') || 'viewer'
          const senders = (consumer.senders as { drops?: number }[] | undefined) ?? []
          drops[name] = (drops[name] ?? 0) + senders.reduce((sum, sender) => sum + (sender.drops ?? 0), 0)
        }
        for (const [viewer, total] of Object.entries(drops).sort()) {
          if (total > (last[viewer] ?? 0)) log(`[go2rtc] ${clock()} ${viewer} fell behind: ${total - (last[viewer] ?? 0)} frames dropped in 10 s`)
        }
        last = drops
      } catch {
        // The stream may not exist yet.
      }
    }, 10_000)
  }

  private diagnostics() {
    return {
      logFile: currentLogFile(),
      go2rtcBinary: paths.go2rtcBinary,
      go2rtcConfig: paths.go2rtcConfig,
      electron: process.versions.electron,
      chrome: process.versions.chrome,
      node: process.versions.node,
      os: `${process.platform} ${process.getSystemVersion()}`,
    }
  }

  // MARK: - Methods for the UI

  async call(method: string, args: unknown[]): Promise<unknown> {
    const handler = (this.handlers as Record<string, (...args: never[]) => unknown>)[method]
    if (!handler) throw new Error(`unknown method ${method}`)
    return await handler(...(args as never[]))
  }

  private handlers = {
    'settings.update': (patch: Partial<Settings>) => {
      const previous = this.settings.value
      this.settings.update(patch)
      if (patch.autoFinishAfterLastBreak !== undefined && this.session) this.session.autoFinishAfterLastBreak = patch.autoFinishAfterLastBreak
      if (patch.shareWithIPhone !== undefined && patch.shareWithIPhone !== previous.shareWithIPhone) void this.setSharing(patch.shareWithIPhone)
      const serverChanged = ['connectionMode', 'serverURL', 'serverUsername', 'serverPassword', 'streamName'].some((key) => key in patch)
      if (serverChanged) {
        if (patch.connectionMode === 'embedded' && !this.go2rtc.isRunning) void this.go2rtc.start(this.settings.value.shareWithIPhone ? this.settings.lanPassword : null)
        this.playerGeneration += 1
        void this.refreshCamera()
      }
    },
    'session.start': (plan: TrainingPlan) => this.startSession(plan),
    'session.command': (command: string) => this.sessionCommand(command),
    'session.abandon': () => this.abandonSession(),
    'session.updatePlan': (plan: TrainingPlan, options?: { quiet?: boolean; changesSince?: TrainingPlan | null }) =>
      this.updateSessionPlan(plan, options),
    'pending.set': (plan: TrainingPlan | null, keepOriginal?: boolean) => this.setPending(plan, keepOriginal ?? false),
    'recording.toggle': () => this.toggleRecording(),
    'recording.start': () => this.startRecording(),
    'recording.stop': () => this.stopRecording(false),
    'history.list': () => ({ records: this.history, clips: this.clips }),
    'history.delete': (id: string, includingRecording: boolean) => this.deleteRecord(id, includingRecording),
    'history.deleteClip': (fileName: string) => this.deleteClip(fileName),
    'history.deleteAll': () => this.deleteAll(),
    'history.logText': (id: string) => {
      const record = this.history.find((item) => item.id === id)
      return record ? SessionLogFormatter.text(record) : ''
    },
    'history.finalize': (fileName: string) => this.finalizeRecording(join(this.store.recordingsDirectory, basename(fileName))),
    'state.dismissLastRecord': () => {
      this.lastRecord = null
      this.emit()
    },
    'state.dismissLastClip': () => {
      this.lastClip = null
      this.emit()
    },
    'state.dismissError': () => {
      this.errorMessage = null
      this.emit()
    },
    'camera.setQuality': (quality: XiaomiQuality) => this.setQuality(quality),
    'camera.reportVideoSize': (width: number, height: number) => this.reportVideoSize(width, height),
    'camera.reconnect': () => {
      this.videoSize = null
      this.playerGeneration += 1
      this.emit()
    },
    'camera.refresh': () => this.refreshCamera(),
    'camera.setMode': async (key: string, value: boolean | number) => {
      const error = await this.cameraModes.set(key, value)
      if (error) this.fail(error)
    },
    'camera.continueWithout': () => {
      this.settings.update({ withoutCamera: true })
      this.emit()
    },
    'go2rtc.restart': () => this.go2rtc.restart(this.settings.value.shareWithIPhone ? this.settings.lanPassword : null),
    'go2rtc.fetch': (request: { url: string; method?: string; headers?: Record<string, string>; body?: string | Uint8Array }) => this.go2rtcFetch(request),
    'xiaomi.logout': (accountID: string) => this.signOutOfXiaomi(accountID),
    'streams.select': (patch: Partial<Settings>) => this.selectStream(patch),
    'sync.setEnabled': (enabled: boolean) => this.setSharing(enabled),
    'sync.respond': (requestId: string, allow: boolean) => this.sync.respond(requestId, allow),
    'sync.forget': (deviceId: string) => this.sync.forget(deviceId),
    'shell.showItem': (kind: string, name?: string) => {
      const target =
        kind === 'recordings' ? this.store.recordingsDirectory
        : kind === 'sessions' ? this.store.sessionsDirectory
        : kind === 'logs' ? paths.logsDirectory
        : kind === 'documents' ? paths.documentsRoot
        : kind === 'recording' && name ? join(this.store.recordingsDirectory, basename(name))
        : kind === 'log' && name ? this.store.logPathFor(this.history.find((record) => record.id === name))
        : kind === 'go2rtcConfig' ? paths.go2rtcConfig
        : null
      if (!target) return
      const isFile = kind === 'recording' || kind === 'log' || kind === 'go2rtcConfig'
      if (!isFile) mkdirSync(target, { recursive: true })
      if (isFile) shell.showItemInFolder(target)
      else void shell.openPath(target)
    },
    'shell.openExternal': (url: string) => {
      if (/^https?:\/\//.test(url) || url.startsWith('mailto:')) void shell.openExternal(url)
    },
    'shell.openFirewall': () => {
      if (process.platform === 'win32') execFile('control.exe', ['/name', 'Microsoft.WindowsFirewall', '/page', 'pageConfigureApps'], { windowsHide: true }, () => undefined)
    },
    'shell.openFile': (fileName: string) => {
      const path = join(this.store.recordingsDirectory, basename(fileName))
      if (existsSync(path)) void shell.openPath(path)
    },
    'shell.copyFile': async (fileName: string) => {
      // Windows has no share sheet for desktop apps: the file goes to the clipboard as a file, ready to paste into
      // Telegram, WhatsApp or an Explorer window.
      const path = join(this.store.recordingsDirectory, basename(fileName))
      await this.finalizeRecording(path)
      await copyFileToClipboard(path)
    },
    'clipboard.readText': () => clipboard.readText(),
    'clipboard.writeText': (text: string) => clipboard.writeText(text),
    'app.legal': (kind: 'privacy' | 'licenses') => legalText(kind),
    'app.diagnostics': () => this.diagnostics(),
    'app.openLogFile': () => {
      const file = currentLogFile()
      if (file) shell.showItemInFolder(file)
    },
    'recordings.size': () => this.recordingsSize(),
  }

  private recordingsSize(): { files: number; bytes: number } {
    let files = 0
    let bytes = 0
    try {
      for (const name of readdirSync(this.store.recordingsDirectory)) {
        if (!name.endsWith('.mp4')) continue
        files += 1
        bytes += safeSize(join(this.store.recordingsDirectory, name))
      }
    } catch {
      // No folder yet.
    }
    return { files, bytes }
  }
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function removeQuietly(path: string): void {
  try {
    if (existsSync(path)) unlinkSync(path)
  } catch (error) {
    log(`[files] could not remove ${path}: ${(error as Error).message}`)
  }
}

function safeStat(path: string) {
  try {
    return statSync(path)
  } catch {
    return null
  }
}

function safeSize(path: string): number {
  return safeStat(path)?.size ?? 0
}

function isLocalHost(host: string): boolean {
  const name = host.replace(/^\[|\]$/g, '').toLowerCase()
  if (name === 'localhost' || name.endsWith('.local') || name === '::1') return true
  const parts = name.split('.').map(Number)
  if (parts.length !== 4 || parts.some((part) => Number.isNaN(part))) return false
  const [a, b] = parts
  return a === 127 || a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254) || (a === 100 && b >= 64 && b <= 127)
}

/// Puts a file on the Windows clipboard as a file (CF_HDROP), like Explorer's Copy: it pastes into Telegram, WhatsApp
/// or an Explorer window. Electron 44's clipboard writes raw formats through its `osclipboard` custom type; if that is
/// refused, PowerShell's Set-Clipboard does the same.
async function copyFileToClipboard(path: string): Promise<void> {
  if (process.platform !== 'win32') {
    await clipboard.writeText(path)
    return
  }
  // DROPFILES header (20 bytes) + double-null-terminated UTF-16 path list.
  const header = Buffer.alloc(20)
  header.writeUInt32LE(20, 0) // pFiles
  header.writeUInt32LE(1, 16) // fWide
  const data = Buffer.concat([header, Buffer.from(path + '\0\0', 'utf16le')])
  const format = 'electron application/osclipboard;format="CF_HDROP"'
  try {
    await clipboard.write([new ClipboardItem({ [format]: new Blob([data]) })])
    if (await clipboard.has(format)) return
  } catch (error) {
    log(`[clipboard] raw CF_HDROP refused: ${(error as Error).message}`)
  }
  await new Promise<void>((resolve, reject) => {
    execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', 'Set-Clipboard -LiteralPath $args[0]', path], { windowsHide: true }, (error) =>
      error ? reject(error) : resolve(),
    )
  })
}

export type { TrainingSessionSnapshot }
