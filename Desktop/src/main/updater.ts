import { app, net } from 'electron'
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import {
  NIGHTLY_FEED,
  RELEASES_PAGE,
  STABLE_FEED,
  compareVersions,
  feedVersion,
  releaseFeed,
  updateNotes,
  type PendingUpdate,
  type UpdateMode,
  type UpdatesState,
} from '@shared/updates'

/// Updates of the Windows app installed from GitHub through electron-updater: the Mac's `AppUpdater` (Sparkle).
///
/// - The feeds are the `latest.yml` of the Latest release and, with «Тестовые сборки», of the «nightly» pre-release.
///   The newer of the two wins, so a tester still gets a release that is newer than the last nightly (on the Mac the
///   nightly appcast lists that release too). Turned off, the nightly stays until the next release: no downgrades.
/// - A version found in the background never opens a window. Downloaded («Устанавливать автоматически») or found
///   («Только сообщать»), it shows as «Обновление» in the title bar outside a training or a recording, and in
///   Settings → About.
/// - No background check during a training, a recording or while a video is being finished; a restart into a new
///   version waits until they end.
/// - It installs when the app quits, or at once with «Перезапустить». The installer is for all users: Windows asks
///   for administrator rights (UAC) each time.

/// What the updater needs of electron-updater's `autoUpdater` (a fake in the tests).
export interface UpdateEngine {
  autoDownload: boolean
  autoInstallOnAppQuit: boolean
  setFeedURL(url: string): void
  checkForUpdates(): Promise<{ isUpdateAvailable: boolean; updateInfo: { version: string } } | null>
  downloadUpdate(): Promise<unknown>
  /// Quits, installs silently and starts the new version.
  quitAndInstall(): void
  on(event: 'update-available' | 'update-downloaded', listener: (info: UpdateInfoLike) => void): void
  on(event: 'download-progress', listener: (progress: { percent: number }) => void): void
  on(event: 'error', listener: (error: Error) => void): void
}

export interface UpdateInfoLike {
  version: string
  releaseNotes?: unknown
}

export interface UpdaterOptions {
  /// package.json's version: the tag's in a release, 0.0.0 in any other build.
  currentVersion: string
  unavailable: UpdatesState['unavailable']
  settings: () => { updateMode: UpdateMode; updateNightly: boolean }
  /// A training, a recording or a video being finished.
  isBusy: () => boolean
  onChange: () => void
  /// Remembers the last check (`%APPDATA%\Waiting Paws\updates.json`).
  stateFile: string
  log: (line: string) => void
  /// The electron-updater side, made on the first check (never in a development or portable copy).
  engine?: () => Promise<UpdateEngine>
  fetchText?: (url: string) => Promise<string>
  now?: () => number
  /// `--demo-update [found]`: a waiting 1.7.21 without GitHub (downloaded, or with `found` only found).
  demo?: 'downloaded' | 'found' | null
}

export interface UpdateCheckResult {
  found: boolean
  /// The newest version on GitHub (null if none could be read).
  newest: string | null
}

const DAY = 24 * 60 * 60 * 1000
const HOUR = 60 * 60 * 1000

export class AppUpdater {
  private readonly options: UpdaterOptions
  private readonly now: () => number
  private engine: UpdateEngine | null = null
  private enginePromise: Promise<UpdateEngine> | null = null
  /// The version electron-updater has found (and maybe downloaded).
  private candidate: PendingUpdate | null = null
  /// The user asked (a check, «Загрузить и установить»): the candidate shows while it downloads too. A background
  /// download in «Устанавливать автоматически» shows only once it is done, as on the Mac.
  private shownWhileDownloading = false
  private checkRun: Promise<UpdateCheckResult> | null = null
  private lastCheck: number | null = null
  private error: string | null = null
  private timer: NodeJS.Timeout | null = null
  private firstTimer: NodeJS.Timeout | null = null
  private installTimer: NodeJS.Timeout | null = null
  private demoTimer: NodeJS.Timeout | null = null

  constructor(options: UpdaterOptions) {
    this.options = options
    this.now = options.now ?? Date.now
    this.lastCheck = readLastCheck(options.stateFile)
    if (options.demo) {
      this.candidate = {
        version: '1.7.21',
        notes: updateNotes('- Обновления прямо из приложения\n- Камера быстрее подключается после перезапуска\n- Недоделанная ночная запись больше не грузит процессор'),
        downloaded: options.demo === 'downloaded',
        progress: null,
        installing: false,
        releasePage: RELEASES_PAGE,
      }
      this.shownWhileDownloading = true
    }
  }

  get unavailable(): UpdatesState['unavailable'] {
    return this.options.demo ? null : this.options.unavailable
  }

  view(): UpdatesState {
    const candidate = this.candidate
    const downloadingQuietly = candidate && !candidate.downloaded && !candidate.installing && candidate.progress !== null && !this.shownWhileDownloading
    const shown = candidate && !downloadingQuietly ? { ...candidate } : null
    return { unavailable: this.unavailable, checking: this.checkRun !== null, lastCheck: this.lastCheck, pending: shown, error: this.error }
  }

  /// Background checks: the first a little after the launch, then once an hour whether a day has passed.
  start(): void {
    if (this.unavailable || this.options.demo) return
    this.firstTimer = setTimeout(() => this.checkIfDue(), 30_000)
    this.timer = setInterval(() => this.checkIfDue(), HOUR)
    this.timer.unref?.()
  }

  stop(): void {
    for (const timer of [this.firstTimer, this.demoTimer]) if (timer) clearTimeout(timer)
    for (const timer of [this.timer, this.installTimer]) if (timer) clearInterval(timer)
    this.firstTimer = this.timer = this.installTimer = this.demoTimer = null
  }

  /// Settings → About changed the mode or «Тестовые сборки».
  settingsChanged(previous: { updateMode: UpdateMode; updateNightly: boolean }): void {
    const settings = this.options.settings()
    if (this.unavailable || this.options.demo) return
    if (settings.updateNightly !== previous.updateNightly) {
      // Another feed: what was found in the old one goes, and a version downloaded from it is not installed on quit.
      this.candidate = null
      this.shownWhileDownloading = false
      this.cancelInstallWait()
      if (this.engine) this.engine.autoInstallOnAppQuit = false
      this.options.onChange()
    }
    if (this.engine) this.engine.autoDownload = settings.updateMode === 'automatic'
    if (settings.updateMode !== 'manual' && (settings.updateNightly !== previous.updateNightly || settings.updateMode !== previous.updateMode)) {
      void this.check(false).catch(() => undefined)
    }
  }

  private checkIfDue(): void {
    if (this.options.settings().updateMode === 'manual' || this.options.isBusy() || this.checkRun) return
    if (this.lastCheck !== null && this.now() - this.lastCheck < DAY) return
    void this.check(false).catch(() => undefined)
  }

  /// «Проверить сейчас» (`manual`), or a background check. A check under way is joined.
  check(manual: boolean): Promise<UpdateCheckResult> {
    if (this.options.demo) return Promise.resolve({ found: this.candidate !== null, newest: this.candidate?.version ?? null })
    if (this.unavailable) return Promise.resolve({ found: false, newest: null })
    if (!manual && this.options.isBusy()) return Promise.resolve({ found: false, newest: null })
    if (manual) this.shownWhileDownloading = true
    if (this.checkRun) return this.checkRun
    if (!manual && !this.candidate) this.shownWhileDownloading = false
    const run = this.runCheck(manual).finally(() => {
      this.checkRun = null
      this.options.onChange()
    })
    this.checkRun = run
    this.options.onChange()
    return run
  }

  private async runCheck(manual: boolean): Promise<UpdateCheckResult> {
    const settings = this.options.settings()
    const feeds = [{ nightly: false, url: STABLE_FEED }, ...(settings.updateNightly ? [{ nightly: true, url: NIGHTLY_FEED }] : [])]
    const fetchText = this.options.fetchText ?? defaultFetchText
    try {
      const read = await Promise.allSettled(
        feeds.map(async (feed) => {
          const version = feedVersion(await fetchText(`${feed.url}/latest.yml`))
          if (!version || compareVersions(version, version) === null) throw new Error(`no version in ${feed.url}/latest.yml`)
          return { ...feed, version }
        }),
      )
      const versions = read.flatMap((result) => (result.status === 'fulfilled' ? [result.value] : []))
      for (const result of read) if (result.status === 'rejected') this.options.log(`[updates] ${errorText(result.reason)}`)
      if (!versions.length) throw (read[0] as PromiseRejectedResult).reason
      const newest = versions.reduce((best, next) => ((compareVersions(next.version, best.version) ?? 0) > 0 ? next : best))
      this.lastCheck = this.now()
      writeLastCheck(this.options.stateFile, this.lastCheck)
      this.error = null
      const current = this.options.currentVersion
      this.options.log(`[updates] ${manual ? 'check' : 'background check'}: ${versions.map((item) => `${item.nightly ? 'nightly' : 'release'} ${item.version}`).join(', ')}; this is ${current}`)
      if ((compareVersions(newest.version, current) ?? 0) <= 0) return { found: false, newest: newest.version }
      // Already found (and maybe downloaded or downloading): nothing to ask electron-updater again.
      if (this.candidate?.version === newest.version) return { found: true, newest: newest.version }
      const engine = await this.ensureEngine()
      engine.autoDownload = this.options.settings().updateMode === 'automatic'
      engine.setFeedURL(newest.nightly ? NIGHTLY_FEED : releaseFeed(newest.version))
      const result = await engine.checkForUpdates()
      return { found: Boolean(result?.isUpdateAvailable), newest: newest.version }
    } catch (error) {
      this.error = errorText(error)
      this.options.log(`[updates] check failed: ${this.error}`)
      throw new Error(this.error)
    }
  }

  /// «Перезапустить» (downloaded) or «Загрузить и установить» (only found: downloads, then installs). During a training,
  /// a recording or while a video is being finished, the restart waits until they end.
  install(): void {
    const candidate = this.candidate
    if (!candidate) return
    candidate.installing = true
    this.shownWhileDownloading = true
    this.options.onChange()
    if (this.options.demo) return this.demoInstall(candidate)
    if (candidate.downloaded) return this.installWhenFree()
    if (candidate.progress === null) {
      candidate.progress = 0
      this.options.onChange()
      void this.engine?.downloadUpdate().catch(() => undefined)
    }
    // Downloading already: `update-downloaded` installs it.
  }

  private installWhenFree(): void {
    if (!this.options.isBusy()) {
      this.options.log(`[updates] installing ${this.candidate?.version} and restarting`)
      this.engine?.quitAndInstall()
      return
    }
    if (this.installTimer) return
    this.options.log('[updates] the restart waits for the training, the recording or a video being finished')
    this.installTimer = setInterval(() => {
      if (this.options.isBusy()) return
      this.cancelInstallWait()
      this.installWhenFree()
    }, 5000)
  }

  private cancelInstallWait(): void {
    if (this.installTimer) clearInterval(this.installTimer)
    this.installTimer = null
  }

  private ensureEngine(): Promise<UpdateEngine> {
    if (!this.enginePromise) {
      const make = this.options.engine ?? (() => electronEngine(this.options.log))
      this.enginePromise = make().then((engine) => {
        this.engine = engine
        engine.autoInstallOnAppQuit = true
        engine.on('update-available', (info) => this.found(info))
        engine.on('download-progress', (progress) => this.progress(progress.percent))
        engine.on('update-downloaded', (info) => this.downloaded(info))
        engine.on('error', (error) => this.failed(error))
        return engine
      })
    }
    return this.enginePromise
  }

  private found(info: UpdateInfoLike): void {
    const automatic = this.options.settings().updateMode === 'automatic'
    this.candidate = {
      version: info.version,
      notes: updateNotes(info.releaseNotes),
      downloaded: false,
      progress: automatic ? 0 : null,
      installing: false,
      releasePage: RELEASES_PAGE,
    }
    this.options.log(`[updates] found ${info.version}${automatic ? ', downloading' : ''}`)
    this.options.onChange()
  }

  private progress(percent: number): void {
    const candidate = this.candidate
    if (!candidate || candidate.downloaded) return
    const rounded = Math.max(0, Math.min(100, Math.floor(percent)))
    if (rounded === candidate.progress) return
    candidate.progress = rounded
    this.options.onChange()
  }

  private downloaded(info: UpdateInfoLike): void {
    const candidate = this.candidate
    if (!candidate || candidate.version !== info.version) {
      // From the feed before «Тестовые сборки» was switched: not installed on quit.
      this.options.log(`[updates] downloaded ${info.version}, no longer wanted`)
      if (this.engine) this.engine.autoInstallOnAppQuit = false
      return
    }
    candidate.downloaded = true
    candidate.progress = null
    if (this.engine) this.engine.autoInstallOnAppQuit = true
    this.options.log(`[updates] downloaded ${info.version}: installs on quit`)
    this.options.onChange()
    if (candidate.installing) this.installWhenFree()
  }

  private failed(error: Error): void {
    this.error = errorText(error)
    this.options.log(`[updates] error: ${this.error}`)
    const candidate = this.candidate
    if (candidate && !candidate.downloaded) {
      candidate.progress = null
      candidate.installing = false
    }
    this.options.onChange()
  }

  /// `--demo-update found` + «Загрузить и установить»: a download in three seconds; then «Перезапустить» only logs.
  private demoInstall(candidate: PendingUpdate): void {
    if (candidate.downloaded) {
      this.options.log(`[updates] demo: would install ${candidate.version} and restart`)
      candidate.installing = false
      this.options.onChange()
      return
    }
    candidate.progress = 0
    const step = () => {
      candidate.progress = Math.min(100, (candidate.progress ?? 0) + 10)
      if (candidate.progress >= 100) {
        candidate.downloaded = true
        candidate.progress = null
        candidate.installing = false
      } else {
        this.demoTimer = setTimeout(step, 300)
      }
      this.options.onChange()
    }
    this.demoTimer = setTimeout(step, 300)
  }
}

/// Why this copy can't update itself: a development build (not packaged, version 0.0.0) or one unpacked from the zip
/// (no NSIS uninstaller next to the program: the installer would put a second copy into Program Files).
export function updatesAvailability(currentVersion: string): UpdatesState['unavailable'] {
  if (!app.isPackaged || currentVersion === '0.0.0' || process.platform !== 'win32') return 'dev'
  try {
    const installed = readdirSync(dirname(process.execPath)).some((name) => /^Uninstall .+\.exe$/i.test(name))
    return installed ? null : 'portable'
  } catch {
    return 'portable'
  }
}

async function electronEngine(log: (line: string) => void): Promise<UpdateEngine> {
  const { autoUpdater } = await import('electron-updater')
  autoUpdater.logger = {
    info: (message?: unknown) => log(`[updates] ${String(message)}`),
    warn: (message?: unknown) => log(`[updates] warning: ${String(message)}`),
    error: (message?: unknown) => log(`[updates] error: ${String(message)}`),
  }
  autoUpdater.autoDownload = false
  // Turned off, «Тестовые сборки» keep the nightly until the next release (Sparkle never downgrades either).
  autoUpdater.allowDowngrade = false
  return {
    get autoDownload() {
      return autoUpdater.autoDownload
    },
    set autoDownload(value: boolean) {
      autoUpdater.autoDownload = value
    },
    get autoInstallOnAppQuit() {
      return autoUpdater.autoInstallOnAppQuit
    },
    set autoInstallOnAppQuit(value: boolean) {
      autoUpdater.autoInstallOnAppQuit = value
    },
    setFeedURL: (url) => autoUpdater.setFeedURL({ provider: 'generic', url }),
    checkForUpdates: async () => {
      const result = await autoUpdater.checkForUpdates()
      // A failed background download is reported by the `error` event: its promise must not be left unhandled.
      void result?.downloadPromise?.catch(() => undefined)
      return result
    },
    downloadUpdate: () => autoUpdater.downloadUpdate(),
    // Silent (the installer's pages don't show), then the new version starts.
    quitAndInstall: () => autoUpdater.quitAndInstall(true, true),
    on: (event: string, listener: (...args: never[]) => void) => {
      autoUpdater.on(event as 'error', listener as (error: Error) => void)
    },
  } as UpdateEngine
}

async function defaultFetchText(url: string): Promise<string> {
  const response = await net.fetch(url, { cache: 'no-store', headers: { 'User-Agent': `WaitingPaws/${app.getVersion()}` } })
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`)
  return response.text()
}

function errorText(error: unknown): string {
  const text = String((error as Error)?.message ?? error)
  // electron-updater appends the whole HTTP response; the first line says what failed.
  return text.split('\n')[0].slice(0, 300)
}

function readLastCheck(file: string): number | null {
  try {
    const value = JSON.parse(readFileSync(file, 'utf8')).lastCheck
    return typeof value === 'number' ? value : null
  } catch {
    return null
  }
}

function writeLastCheck(file: string, time: number): void {
  try {
    if (!existsSync(dirname(file))) mkdirSync(dirname(file), { recursive: true })
    writeFileSync(file, JSON.stringify({ lastCheck: time }))
  } catch {
    // Not worth an error: the next launch checks again a little earlier.
  }
}
