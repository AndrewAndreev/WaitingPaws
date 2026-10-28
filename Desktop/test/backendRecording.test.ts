// The backend's recording around a training (AppBackend with Electron stubbed out), against a fake go2rtc stream:
// overlapping stops and starts, a start overtaken by a stop, the video name of a finished training, joining parts
// by the time their video began, finalizing from the history during a join, the server kept during a recording,
// quitting during a save and Windows ending the session.
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer, type Server, type ServerResponse } from 'node:http'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { PlannedExit, TrainingPlan, setCoreLanguage } from '@core/index'
import type { AppBackend as Backend } from '../src/main/backend'
import type { MediaFinalizer, RecordingPart } from '../src/main/finalizer'

vi.mock('electron', () => ({
  app: {
    isPackaged: false,
    getAppPath: () => process.cwd(),
    getPath: () => tmpdir(),
    getLocale: () => 'ru-RU',
    getPreferredSystemLanguages: () => ['ru-RU'],
    getSystemLocale: () => 'ru-RU',
  },
  clipboard: {},
  ClipboardItem: class {},
  shell: {},
  safeStorage: { isEncryptionAvailable: () => false },
  BrowserWindow: class {},
  ipcMain: { handle: () => undefined, on: () => undefined },
}))

function box(type: string, body: number): Uint8Array {
  const data = new Uint8Array(8 + body)
  new DataView(data.buffer).setUint32(0, 8 + body)
  data.set(new TextEncoder().encode(type), 4)
  return data
}

function until(condition: () => boolean, timeout = 4000): Promise<void> {
  const start = Date.now()
  return new Promise((resolve, reject) => {
    const check = () => {
      if (condition()) return resolve()
      if (Date.now() - start > timeout) return reject(new Error('timed out'))
      setTimeout(check, 10)
    }
    check()
  })
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

/// go2rtc's `/api/stream.mp4`: the init segment at once, then a fragment every 30 ms (`silent`: nothing at all).
class FakeCamera {
  silent = false
  /// Delay before the first fragment of each request (the camera's next keyframe).
  keyframeDelay = 0
  readonly responses: ServerResponse[] = []
  private readonly server: Server
  private timers: NodeJS.Timeout[] = []

  constructor() {
    this.server = createServer((_request, response) => {
      response.writeHead(200, { 'Content-Type': 'video/mp4' })
      this.responses.push(response)
      if (this.silent) return
      response.write(Buffer.concat([box('ftyp', 16), box('moov', 200)]))
      const timer = setTimeout(() => {
        const repeat = setInterval(() => {
          if (!response.writableEnded) response.write(Buffer.concat([box('moof', 40), box('mdat', 400)]))
        }, 30)
        this.timers.push(repeat)
        if (!response.writableEnded) response.write(Buffer.concat([box('moof', 40), box('mdat', 400)]))
      }, this.keyframeDelay)
      this.timers.push(timer)
    })
  }

  async start(): Promise<string> {
    await new Promise<void>((resolve) => this.server.listen(0, '127.0.0.1', resolve))
    const address = this.server.address()
    return `http://127.0.0.1:${typeof address === 'object' && address ? address.port : 0}/`
  }

  /// The camera drops out: the open stream ends.
  dropOut(): void {
    for (const response of this.responses) if (!response.writableEnded) response.end()
  }

  close(): void {
    for (const timer of this.timers) clearTimeout(timer), clearInterval(timer)
    this.server.closeAllConnections()
    this.server.close()
  }
}

const root = mkdtempSync(join(tmpdir(), 'wp-backend-'))
const recordings = join(root, 'Documents', 'Waiting Paws', 'Recordings')
const sessions = join(root, 'Documents', 'Waiting Paws', 'Sessions')
const plan = TrainingPlan.make({ title: 'Тест', exits: [PlannedExit.make({ number: 1, duration: 60 })] })

describe('AppBackend recording', () => {
  let AppBackend: typeof Backend
  let SettingsStore: typeof import('../src/main/settings').SettingsStore
  let camera: FakeCamera
  let backend: Backend
  let writes: { parts: RecordingPart[]; output: string }[]
  /// Which of the parts the fake finalizer says it used (all by default).
  let usedParts: (parts: RecordingPart[]) => string[]
  /// A write finishes when this does (a file held open delays putting the result in place).
  let writeDone: Promise<void>
  let needsFinalizing: boolean

  beforeAll(async () => {
    process.argv.push(`--data-dir=${root}`)
    ;({ AppBackend } = await import('../src/main/backend'))
    ;({ SettingsStore } = await import('../src/main/settings'))
  })

  afterAll(() => {
    process.argv = process.argv.filter((arg) => !arg.startsWith('--data-dir='))
    rmSync(root, { recursive: true, force: true })
  })

  beforeEach(async () => {
    setCoreLanguage('ru')
    rmSync(recordings, { recursive: true, force: true })
    rmSync(sessions, { recursive: true, force: true })
    mkdirSync(recordings, { recursive: true })
    camera = new FakeCamera()
    const serverURL = await camera.start()
    const settings = new SettingsStore(join(root, `settings-${Date.now()}.json`))
    settings.update({ connectionMode: 'external', serverURL, streamName: 'cam', autoRecord: true })
    writes = []
    usedParts = (parts) => parts.map((part) => part.path)
    writeDone = Promise.resolve()
    needsFinalizing = false
    const finalizer = {
      write: async (parts: RecordingPart[], output: string) => {
        writes.push({ parts, output })
        await writeDone
        // The result goes in place whether or not the file is still there, as `replaceFile` does.
        writeFileSync(output, 'joined')
        return usedParts(parts)
      },
      needsFinalizing: async () => needsFinalizing,
    } as unknown as MediaFinalizer
    backend = new AppBackend(settings, finalizer)
  })

  afterEach(async () => {
    await backend.shutdown()
    camera.close()
  })

  const files = () => readdirSync(recordings).filter((name) => name.endsWith('.mp4'))
  const recordingNow = () => backend.recorder.isRecording && backend.recorder.bytesWritten > 0

  it('keeps the recording when two stops overlap', async () => {
    await backend.startRecording()
    await until(recordingNow)
    const name = backend.recorder.filePath!.split(/[\\/]/).pop()!
    await Promise.all([backend.stopRecording(false), backend.stopRecording(false)])
    expect(files()).toEqual([name])
    expect(backend.state().lastClip?.fileName).toBe(name)
  })

  it('stop then start (Ctrl+R twice): the new recording does not take the stopped one for its own', async () => {
    await backend.startRecording()
    await until(recordingNow)
    const first = backend.recorder.filePath!
    // Two key presses: two calls from the window, the second while the first stop is still closing the file.
    const stop = backend.toggleRecording()
    await new Promise((resolve) => setImmediate(resolve))
    await Promise.all([stop, backend.toggleRecording()])
    const second = backend.recorder.filePath!
    expect(second).not.toBe(first)
    expect(backend.isRecordingLocally).toBe(true)
    await until(recordingNow)
    await backend.stopRecording(false)
    expect(existsSync(first)).toBe(true)
    expect(existsSync(second)).toBe(true)
  })

  it('a start still waiting does not begin after the training was dropped', async () => {
    backend.startSession(plan)
    await backend.abandonSession()
    await sleep(100)
    expect(backend.isRecordingLocally).toBe(false)
    expect(files()).toEqual([])
    // Nothing to drop any more: a late «abandon» leaves a recording made since alone.
    await backend.startRecording()
    await until(recordingNow)
    await backend.abandonSession()
    expect(backend.isRecordingLocally).toBe(true)
  })

  it('a finished training does not name a recording that got nothing', async () => {
    camera.silent = true
    backend.startSession(plan)
    await until(() => backend.recorder.isRecording && camera.responses.length > 0)
    await backend.finishSession()
    expect(backend.state().lastRecord?.recordingFileName).toBeNull()
    expect(files()).toEqual([])
  })

  it('joins the parts by when their video began, and deletes only the parts used', async () => {
    camera.keyframeDelay = 150
    await backend.startRecording()
    await until(recordingNow)
    const main = backend.recorder.filePath!
    await until(() => backend.recorder.firstFragmentAt !== null)
    await sleep(100)
    camera.dropOut()
    // The next part is asked for 2 s later.
    await until(() => backend.recorder.isRecording && backend.recorder.filePath !== main, 5000)
    await until(() => backend.recorder.firstFragmentAt !== null)
    await sleep(100)
    usedParts = (parts) => [parts[0].path]
    await backend.stopRecording(false)
    await until(() => writes.length === 1)
    await sleep(50)

    const [{ parts, output }] = writes
    expect(output).toBe(main)
    expect(parts).toHaveLength(2)
    // Placed at its first frame, not at its request: the camera's keyframe came 150 ms after it.
    expect(parts[0].offset).toBeGreaterThanOrEqual(0.12)
    expect(parts[1].offset - parts[0].offset).toBeGreaterThan(2)
    // The finalizer left the second part out: it stays in `.parts`.
    expect(existsSync(parts[1].path)).toBe(true)
  })

  it('finalizing a recording from the history waits for its join instead of writing it alongside', async () => {
    await backend.startRecording()
    await until(recordingNow)
    const main = backend.recorder.filePath!
    camera.dropOut()
    await until(() => backend.recorder.isRecording && backend.recorder.filePath !== main, 5000)
    await until(() => backend.recorder.bytesWritten > 0)
    // The joined file waits to replace the first part (a player or the antivirus holds it); the first part itself
    // is still go2rtc's fragmented MP4.
    let release = () => {}
    writeDone = new Promise((resolve) => (release = resolve))
    needsFinalizing = true
    await backend.stopRecording(false)
    await until(() => writes.length === 1)
    const name = basename(main)
    expect(backend.state().finalizing).toEqual([name])
    // The history opens it meanwhile.
    let finalized = false
    const finalize = backend.call('history.finalize', [name]).then(() => (finalized = true))
    await sleep(100)
    expect(writes).toHaveLength(1)
    expect(finalized).toBe(false)
    release()
    await finalize
    expect(writes).toHaveLength(1)
    expect(writes[0].parts).toHaveLength(2)
    expect(backend.state().finalizing).toEqual([])
  })

  it('a recording deleted during its join does not come back', async () => {
    await backend.startRecording()
    await until(recordingNow)
    const main = backend.recorder.filePath!
    camera.dropOut()
    await until(() => backend.recorder.isRecording && backend.recorder.filePath !== main, 5000)
    await until(() => backend.recorder.bytesWritten > 0)
    let release = () => {}
    writeDone = new Promise((resolve) => (release = resolve))
    await backend.stopRecording(false)
    await until(() => writes.length === 1)
    await backend.call('history.deleteClip', [basename(main)])
    expect(existsSync(main)).toBe(false)
    release()
    await until(() => backend.state().finalizing.length === 0)
    await sleep(50)
    expect(existsSync(main)).toBe(false)
  })

  it('keeps the server while a recording runs', async () => {
    const server = backend.settings.value.serverURL
    await backend.startRecording()
    await until(recordingNow)
    await backend.call('settings.update', [{ connectionMode: 'embedded', serverURL: 'http://127.0.0.1:9/', keepAwake: false }])
    expect(backend.settings.value.connectionMode).toBe('external')
    expect(backend.settings.value.serverURL).toBe(server)
    // The rest of the change applies.
    expect(backend.settings.value.keepAwake).toBe(false)
    await backend.stopRecording(false)
    await backend.call('settings.update', [{ serverURL: 'http://127.0.0.1:9/' }])
    expect(backend.settings.value.serverURL).toBe('http://127.0.0.1:9/')
  })

  it('quitting waits for a training being saved', async () => {
    backend.startSession(plan)
    await until(recordingNow)
    void backend.finishSession()
    await backend.shutdown()
    const saved = readdirSync(sessions).filter((name) => name.endsWith('.json'))
    expect(saved).toHaveLength(1)
    expect(JSON.parse(readFileSync(join(sessions, saved[0]), 'utf8')).recordingFileName).toBe(files()[0])
  })

  it('saves the training synchronously when Windows ends the session', async () => {
    backend.startSession(plan)
    await until(recordingNow)
    const name = backend.recorder.filePath!.split(/[\\/]/).pop()
    backend.saveBeforeSessionEnd()
    const saved = readdirSync(sessions).filter((name) => name.endsWith('.json'))
    expect(saved).toHaveLength(1)
    expect(JSON.parse(readFileSync(join(sessions, saved[0]), 'utf8')).recordingFileName).toBe(name)
    expect(readdirSync(sessions).filter((name) => name.endsWith('.txt'))).toHaveLength(1)
    // Nothing starts recording any more.
    await backend.startRecording()
    expect(backend.isRecordingLocally).toBe(false)
  })
})
