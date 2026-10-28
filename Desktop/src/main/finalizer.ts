import { BrowserWindow, ipcMain, type IpcMainEvent, type IpcMainInvokeEvent, type WebContents } from 'electron'
import { closeSync, existsSync, fstatSync, openSync, readSync, statSync, unlinkSync, writeSync } from 'node:fs'
import { join, normalize, sep } from 'node:path'
import { replaceFile } from './files'
import { write as log } from './log'

/// Recordings are finalized (remuxed, sound → AAC, parts joined) in a hidden window: WebCodecs live in Chromium,
/// not in Node. See `renderer/src/media/finalizer.ts`. Files are touched only through the handlers below, only by
/// that window, only inside the allowed roots (the recordings folder and the temp folder), and only the files of the
/// jobs under way: the parts it reads, the temporary file it writes.
export interface RecordingPart {
  path: string
  /// Seconds from the start of the recording to the part's first frame (see `writeRecording`).
  offset: number
}

type Job = { kind: 'check'; path: string } | { kind: 'write'; parts: RecordingPart[]; output: string; replacing: string }

export class MediaFinalizer {
  private window: BrowserWindow | null = null
  private ready: Promise<void> | null = null
  private nextId = 1
  private pending = new Map<number, { job: Job; resolve: (value: unknown) => void; reject: (error: Error) => void }>()
  private handles = new Map<number, number>()
  private nextHandle = 1
  private idleTimer: NodeJS.Timeout | null = null

  constructor(
    private readonly roots: () => string[],
    private readonly load: (window: BrowserWindow) => Promise<void>,
    private readonly preload: string,
  ) {
    const allowed = (path: string, writing: boolean) => {
      const full = normalize(path)
      if (!this.roots().some((root) => full.startsWith(normalize(root) + sep))) return false
      return [...this.pending.values()].some(({ job }) => {
        if (job.kind === 'check') return !writing && normalize(job.path) === full
        if (writing) return normalize(job.output) === full
        return job.parts.some((part) => normalize(part.path) === full)
      })
    }
    const check = (event: IpcMainInvokeEvent, path: string, writing = false) => {
      this.checkSender(event)
      if (!allowed(path, writing)) throw new Error(`not allowed: ${path}`)
      return path
    }
    ipcMain.handle('media:size', (event, path: string) => statSync(check(event, path)).size)
    ipcMain.handle('media:read', (event, path: string, start: number, end: number) => {
      const fd = openSync(check(event, path), 'r')
      try {
        const length = Math.max(0, Math.min(end, fstatSync(fd).size) - start)
        const buffer = Buffer.alloc(length)
        let done = 0
        while (done < length) {
          const read = readSync(fd, buffer, done, length - done, start + done)
          if (read <= 0) break
          done += read
        }
        return new Uint8Array(buffer.buffer, buffer.byteOffset, done)
      } finally {
        closeSync(fd)
      }
    })
    ipcMain.handle('media:create', (event, path: string) => {
      const fd = openSync(check(event, path, true), 'w')
      const handle = this.nextHandle++
      this.handles.set(handle, fd)
      return handle
    })
    ipcMain.handle('media:write', (event, handle: number, position: number, data: Uint8Array) => {
      this.checkSender(event)
      const fd = this.handles.get(handle)
      if (fd === undefined) throw new Error('closed')
      let done = 0
      while (done < data.byteLength) done += writeSync(fd, data, done, data.byteLength - done, position + done)
    })
    ipcMain.handle('media:close', (event, handle: number) => {
      this.checkSender(event)
      const fd = this.handles.get(handle)
      if (fd !== undefined) closeSync(fd)
      this.handles.delete(handle)
    })
    ipcMain.on('media:done', (event, id: number, result: { ok: boolean; value?: unknown; error?: string }) => {
      if (!this.isMediaWindow(event)) return
      const pending = this.pending.get(id)
      if (!pending) return
      this.pending.delete(id)
      if (result.ok) pending.resolve(result.value)
      else pending.reject(new Error(result.error))
      this.scheduleIdle()
    })
  }

  /// Whether `path` is still go2rtc's fragmented MP4 or has non-AAC sound.
  async needsFinalizing(path: string): Promise<boolean> {
    return (await this.run({ kind: 'check', path })) as boolean
  }

  /// Finalizes one file in place (parts = [itself at 0]) or joins parts into `output`; returns the parts that went
  /// into it (one without video or unreadable is left out; `output` itself unreadable fails the write). The result
  /// is written to a temporary file next to `output` first and replaces it only when complete. If it can't (the file
  /// is held open for too long), the finished temporary file is kept next to it rather than lost, and goes in place at
  /// the next launch (`restoreKeptFiles`).
  async write(parts: RecordingPart[], output: string): Promise<string[]> {
    const temp = output.replace(/\.mp4$/i, '') + `.finalizing-${Date.now()}.mp4`
    let used: string[]
    try {
      used = ((await this.run({ kind: 'write', parts, output: temp, replacing: output })) as { used: string[] }).used
      if (!existsSync(temp) || statSync(temp).size === 0) throw new Error('empty result')
    } catch (error) {
      try {
        if (existsSync(temp)) unlinkSync(temp)
      } catch {
        // Locked: removed at the next launch (`restoreKeptFiles`).
      }
      throw error
    }
    try {
      await replaceFile(temp, output)
    } catch (error) {
      log(`[rec] kept the finalized file as ${temp}: ${(error as Error).message}`)
      throw error
    }
    return used
  }

  private async run(job: Job): Promise<unknown> {
    if (this.idleTimer) clearTimeout(this.idleTimer)
    await this.ensureWindow()
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      this.pending.set(id, { job, resolve, reject })
      this.window?.webContents.send('media:job', { id, ...job })
    })
  }

  /// Whether `sender` is the hidden media window (its log lines are taken too, see `main/index.ts`).
  isMediaSender(sender: WebContents): boolean {
    return !!this.window && !this.window.isDestroyed() && sender === this.window.webContents
  }

  private isMediaWindow(event: IpcMainEvent | IpcMainInvokeEvent): boolean {
    return this.isMediaSender(event.sender)
  }

  /// The file handlers serve the hidden media window only, never a page of the app's other windows.
  private checkSender(event: IpcMainInvokeEvent): void {
    if (!this.isMediaWindow(event)) throw new Error('not allowed')
  }

  private ensureWindow(): Promise<void> {
    if (this.window && !this.window.isDestroyed() && this.ready) return this.ready
    const window = new BrowserWindow({
      show: false,
      webPreferences: { preload: this.preload, sandbox: true, contextIsolation: true, backgroundThrottling: false },
    })
    this.window = window
    window.webContents.on('render-process-gone', (_event, details) => {
      log(`[rec] media window gone: ${details.reason}`)
      for (const pending of this.pending.values()) pending.reject(new Error('media window crashed'))
      this.pending.clear()
      this.window = null
      this.ready = null
    })
    window.webContents.on('console-message', (event) => {
      const message = (event as unknown as { message?: string }).message
      if (message) log(`[media] ${message}`)
    })
    this.ready = this.load(window)
    return this.ready
  }

  /// The window is closed after a minute without work (it holds a renderer process).
  private scheduleIdle(): void {
    if (this.pending.size) return
    if (this.idleTimer) clearTimeout(this.idleTimer)
    this.idleTimer = setTimeout(() => this.dispose(), 60_000)
  }

  dispose(): void {
    if (this.window && !this.window.isDestroyed()) this.window.destroy()
    this.window = null
    this.ready = null
  }
}

export function tempPartPath(directory: string, name: string): string {
  return join(directory, name)
}
