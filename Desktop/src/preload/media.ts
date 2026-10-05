import { contextBridge, ipcRenderer } from 'electron'

/// File access for the hidden media window (and nothing else): range reads of a recording and positioned writes
/// of the finalized file, all through the main process, which only accepts paths inside the recordings folder.
contextBridge.exposeInMainWorld('media', {
  size: (path: string) => ipcRenderer.invoke('media:size', path),
  read: (path: string, start: number, end: number) => ipcRenderer.invoke('media:read', path, start, end),
  create: (path: string) => ipcRenderer.invoke('media:create', path),
  write: (handle: number, position: number, data: Uint8Array) => ipcRenderer.invoke('media:write', handle, position, data),
  close: (handle: number) => ipcRenderer.invoke('media:close', handle),
  log: (line: string) => ipcRenderer.send('wp:log', line),
  onJob: (handler: (job: unknown) => void) => ipcRenderer.on('media:job', (_event, job) => handler(job)),
  done: (id: number, result: unknown) => ipcRenderer.send('media:done', id, result),
})
