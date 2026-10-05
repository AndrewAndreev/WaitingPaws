import { BrowserWindow, ipcMain } from 'electron'
import { closeSync, existsSync, fstatSync, openSync, readSync, renameSync, statSync, unlinkSync, writeSync } from 'node:fs'
import { join, normalize, sep } from 'node:path'
import { write as log } from './log'

/// Recordings are finalized (remuxed, sound → AAC, parts joined) in a hidden window: WebCodecs live in Chromium,
/// not in Node. See `renderer/src/media/finalizer.ts`. Files are touched only through the handlers below, and only
/// inside the allowed roots (the recordings folder and the temp folder).
export interface RecordingPart {
  path: string
  offset: number
}

type Job = { kind: 'check'; path: string } | { kind: 'write'; parts: RecordingPart[]; output: string }

export class MediaFinalizer {
  private window: BrowserWindow | null = null
  private ready: Promise<void> | null = null
  private nextId = 1
  private pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>()
  private handles = new Map<number, number>()
  private nextHandle = 1
  private idleTimer: NodeJS.Timeout | null = null

  constructor(
    private readonly roots: () => string[],
    private readonly load: (window: BrowserWindow) => Promise<void>,
    private readonly preload: string,
  ) {
    const allowed = (path: string) => {
      const full = normalize(path)
      return this.roots().some((root) => full.startsWith(normalize(root) + sep))
    }
    const check = (path: string) => {
      if (!allowed(path)) throw new Error(`not allowed: ${path}`)
      return path
    }
    ipcMain.handle('media:size', (_event, path: string) => statSync(check(path)).size)
    ipcMain.handle('media:read', (_event, path: string, start: number, end: number) => {
      const fd = openSync(check(path), 'r')
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
    ipcMain.handle('media:create', (_event, path: string) => {
      const fd = openSync(check(path), 'w')
      const handle = this.nextHandle++
      this.handles.set(handle, fd)
      return handle
    })
    ipcMain.handle('media:write', (_event, handle: number, position: number, data: Uint8Array) => {
      const fd = this.handles.get(handle)
      if (fd === undefined) throw new Error('closed')
      let done = 0
      while (done < data.byteLength) done += writeSync(fd, data, done, data.byteLength - done, position + done)
    })
    ipcMain.handle('media:close', (_event, handle: number) => {
      const fd = this.handles.get(handle)
      if (fd !== undefined) closeSync(fd)
      this.handles.delete(handle)
    })
    ipcMain.on('media:done', (_event, id: number, result: { ok: boolean; value?: unknown; error?: string }) => {
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

  /// Finalizes one file in place (parts = [itself at 0]) or joins parts into `output`. The result is written to a
  /// temporary file next to `output` first and replaces it only when complete.
  async write(parts: RecordingPart[], output: string): Promise<void> {
    const temp = output.replace(/\.mp4$/i, '') + `.finalizing-${Date.now()}.mp4`
    try {
      await this.run({ kind: 'write', parts, output: temp })
      if (!existsSync(temp) || statSync(temp).size === 0) throw new Error('пустой результат')
      if (existsSync(output)) unlinkSync(output)
      renameSync(temp, output)
    } catch (error) {
      try {
        if (existsSync(temp)) unlinkSync(temp)
      } catch {
        // Locked: removed on a later run.
      }
      throw error
    }
  }

  private async run(job: Job): Promise<unknown> {
    if (this.idleTimer) clearTimeout(this.idleTimer)
    await this.ensureWindow()
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject })
      this.window?.webContents.send('media:job', { id, ...job })
    })
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
