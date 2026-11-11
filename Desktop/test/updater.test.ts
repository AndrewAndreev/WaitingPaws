// Updates of the Windows app (src/main/updater.ts) with electron-updater faked: which feed wins (a release, the
// nightly, the newer of the two), the modes, a background download that shows only when done, «Загрузить и
// установить», a restart that waits for a training, and switching «Тестовые сборки».
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { compareVersions, feedVersion, NIGHTLY_FEED, releaseFeed, STABLE_FEED, updateNotes, type UpdateMode } from '@shared/updates'
import type { AppUpdater as Updater, UpdateEngine, UpdateInfoLike } from '../src/main/updater'

vi.mock('electron', () => ({ app: { isPackaged: false, getVersion: () => '0.0.0' }, net: {} }))

describe('versions and notes', () => {
  it('orders releases and nightlies as Sparkle orders the Mac builds', () => {
    const sorted = ['1.7.21', '1.7.20', '1.7.21-nightly.2611111459', '1.7.21-nightly.2611120930', '1.8.0', '1.7.9']
    sorted.sort((a, b) => compareVersions(a, b)!)
    expect(sorted).toEqual(['1.7.9', '1.7.20', '1.7.21-nightly.2611111459', '1.7.21-nightly.2611120930', '1.7.21', '1.8.0'])
    expect(compareVersions('v1.7.20', '1.7.20')).toBe(0)
    expect(compareVersions('dev', '1.7.20')).toBeNull()
  })

  it('reads the version of a latest.yml', () => {
    expect(feedVersion("version: 1.7.21\nfiles:\n  - url: WaitingPaws-1.7.21-Setup.exe\n")).toBe('1.7.21')
    expect(feedVersion("version: '1.7.21-nightly.2611111459'\n")).toBe('1.7.21-nightly.2611111459')
    expect(feedVersion('files: []')).toBeNull()
  })

  it('takes the first lines of what is new', () => {
    expect(updateNotes('Intro\n- One\n* Two **bold**\n• Three &amp; more\n- Four\n- Five')).toEqual(['One', 'Two **bold**', 'Three & more', 'Four'])
    expect(updateNotes('<ul><li>One</li><li><b>Two</b></li></ul>')).toEqual(['One', 'Two'])
    expect(updateNotes([{ version: '1.7.21', note: '- New' }])).toEqual(['New'])
    expect(updateNotes(null)).toEqual([])
  })
})

class FakeEngine implements UpdateEngine {
  autoDownload = false
  autoInstallOnAppQuit = false
  feed: string | null = null
  checks = 0
  downloads = 0
  installs = 0
  /// What the feed set last offers.
  offers = new Map<string, string>()
  private listeners = new Map<string, ((value: never) => void)[]>()

  setFeedURL(url: string): void {
    this.feed = url
  }
  async checkForUpdates() {
    this.checks += 1
    const version = this.offers.get(this.feed!)!
    this.emit('update-available', { version, releaseNotes: '- What is new' })
    if (this.autoDownload) void this.downloadUpdate()
    return { isUpdateAvailable: true, updateInfo: { version } }
  }
  async downloadUpdate() {
    this.downloads += 1
  }
  quitAndInstall(): void {
    this.installs += 1
  }
  on(event: string, listener: (value: never) => void): void {
    this.listeners.set(event, [...(this.listeners.get(event) ?? []), listener])
  }
  emit(event: string, value: unknown): void {
    for (const listener of this.listeners.get(event) ?? []) listener(value as never)
  }
  finishDownload(version: string): void {
    this.emit('download-progress', { percent: 100 })
    this.emit('update-downloaded', { version } satisfies UpdateInfoLike)
  }
}

describe('AppUpdater', () => {
  let AppUpdater: typeof Updater
  let dir: string
  let engine: FakeEngine
  let feeds: Record<string, string>
  let settings: { updateMode: UpdateMode; updateNightly: boolean }
  let busy: boolean
  let changes: number
  let updater: Updater

  beforeEach(async () => {
    AppUpdater = (await import('../src/main/updater')).AppUpdater
    dir = mkdtempSync(join(tmpdir(), 'wp-updates-'))
    engine = new FakeEngine()
    feeds = { [STABLE_FEED]: '1.7.21', [NIGHTLY_FEED]: '1.7.22-nightly.2611111459' }
    engine.offers.set(releaseFeed('1.7.21'), '1.7.21')
    engine.offers.set(NIGHTLY_FEED, '1.7.22-nightly.2611111459')
    settings = { updateMode: 'automatic', updateNightly: false }
    busy = false
    changes = 0
    updater = make('1.7.20')
  })

  afterEach(() => {
    updater.stop()
    vi.useRealTimers()
    rmSync(dir, { recursive: true, force: true })
  })

  function make(currentVersion: string): Updater {
    return new AppUpdater({
      currentVersion,
      unavailable: null,
      settings: () => settings,
      isBusy: () => busy,
      onChange: () => (changes += 1),
      stateFile: join(dir, 'updates.json'),
      log: () => undefined,
      engine: async () => engine,
      fetchText: async (url) => {
        const base = url.replace(/\/latest\.yml$/, '')
        if (!(base in feeds)) throw new Error(`${url}: HTTP 404`)
        return `version: ${feeds[base]}\n`
      },
    })
  }

  it('downloads a release in the background and shows it only once downloaded', async () => {
    const result = await updater.check(false)
    expect(result).toEqual({ found: true, newest: '1.7.21' })
    // The release's own folder: electron-updater finds v1.7.20's blockmap next door for a smaller download.
    expect(engine.feed).toBe(releaseFeed('1.7.21'))
    expect(engine.autoDownload).toBe(true)
    expect(updater.view().pending).toBeNull()
    expect(updater.view().lastCheck).not.toBeNull()
    engine.finishDownload('1.7.21')
    expect(updater.view().pending).toMatchObject({ version: '1.7.21', downloaded: true, notes: ['What is new'] })
    expect(engine.autoInstallOnAppQuit).toBe(true)
    // Checked again: nothing new to ask electron-updater.
    await updater.check(true)
    expect(engine.checks).toBe(1)
  })

  it('shows a download the user asked for while it runs', async () => {
    await updater.check(true)
    expect(updater.view().pending).toMatchObject({ version: '1.7.21', downloaded: false, progress: 0 })
    engine.emit('download-progress', { percent: 42.7 })
    expect(updater.view().pending?.progress).toBe(42)
  })

  it('only finds a version in «Только сообщать», then downloads and installs it on request', async () => {
    settings.updateMode = 'notify'
    await updater.check(false)
    expect(engine.autoDownload).toBe(false)
    expect(updater.view().pending).toMatchObject({ version: '1.7.21', downloaded: false, progress: null })
    updater.install()
    expect(engine.downloads).toBe(1)
    expect(updater.view().pending).toMatchObject({ installing: true, progress: 0 })
    engine.finishDownload('1.7.21')
    expect(engine.installs).toBe(1)
  })

  it('waits for the training before restarting into the new version', async () => {
    vi.useFakeTimers()
    await updater.check(false)
    engine.finishDownload('1.7.21')
    busy = true
    updater.install()
    expect(engine.installs).toBe(0)
    vi.advanceTimersByTime(10_000)
    expect(engine.installs).toBe(0)
    busy = false
    vi.advanceTimersByTime(5000)
    expect(engine.installs).toBe(1)
  })

  it('has no background check during a training and none in «Не проверять»', async () => {
    busy = true
    expect(await updater.check(false)).toEqual({ found: false, newest: null })
    busy = false
    vi.useFakeTimers()
    settings.updateMode = 'manual'
    updater.start()
    vi.advanceTimersByTime(2 * 60 * 60 * 1000)
    expect(updater.view().lastCheck).toBeNull()
    // «Проверить сейчас» still checks.
    vi.useRealTimers()
    expect((await updater.check(true)).found).toBe(true)
  })

  it('takes the nightly with «Тестовые сборки», and a release once it is newer', async () => {
    settings.updateNightly = true
    expect(await updater.check(true)).toEqual({ found: true, newest: '1.7.22-nightly.2611111459' })
    expect(engine.feed).toBe(NIGHTLY_FEED)

    const tester = make('1.7.22-nightly.2611111459')
    feeds[STABLE_FEED] = '1.7.22'
    engine.offers.set(releaseFeed('1.7.22'), '1.7.22')
    expect(await tester.check(true)).toEqual({ found: true, newest: '1.7.22' })
    expect(engine.feed).toBe(releaseFeed('1.7.22'))
    tester.stop()
  })

  it('keeps the nightly after «Тестовые сборки» is turned off, until the next release', async () => {
    const tester = make('1.7.22-nightly.2611111459')
    expect(await tester.check(true)).toEqual({ found: false, newest: '1.7.21' })
    tester.stop()
  })

  it('still checks the releases when the nightly has no Windows files', async () => {
    settings.updateNightly = true
    delete feeds[NIGHTLY_FEED]
    expect(await updater.check(true)).toEqual({ found: true, newest: '1.7.21' })
  })

  it('reports a check that reaches no feed', async () => {
    feeds = {}
    await expect(updater.check(true)).rejects.toThrow('HTTP 404')
    expect(updater.view().error).toContain('HTTP 404')
    expect(updater.view().checking).toBe(false)
  })

  it('drops a version from the other feed when «Тестовые сборки» changes', async () => {
    await updater.check(false)
    engine.finishDownload('1.7.21')
    const previous = { ...settings }
    settings.updateNightly = true
    updater.settingsChanged(previous)
    expect(updater.view().pending).toBeNull()
    expect(engine.autoInstallOnAppQuit).toBe(false)
  })

  it('checks once a day in the background', async () => {
    vi.useFakeTimers()
    updater.start()
    await vi.advanceTimersByTimeAsync(31_000)
    expect(engine.checks).toBe(1)
    const first = updater.view().lastCheck
    await vi.advanceTimersByTimeAsync(60 * 60 * 1000)
    expect(updater.view().lastCheck).toBe(first)
    // A new launch reads the last check: not due yet.
    const again = make('1.7.20')
    expect(again.view().lastCheck).toBe(first)
    again.stop()
  })

  it('does nothing in a development or portable copy', async () => {
    const portable = new AppUpdater({
      currentVersion: '1.7.20',
      unavailable: 'portable',
      settings: () => settings,
      isBusy: () => false,
      onChange: () => undefined,
      stateFile: join(dir, 'updates.json'),
      log: () => undefined,
      engine: async () => {
        throw new Error('no engine in a portable copy')
      },
    })
    expect(await portable.check(true)).toEqual({ found: false, newest: null })
    expect(portable.view()).toMatchObject({ unavailable: 'portable', pending: null })
  })
})
