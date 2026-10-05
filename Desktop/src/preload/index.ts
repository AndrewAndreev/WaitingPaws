import { contextBridge, ipcRenderer } from 'electron'
import type { AppState, PlatformBridge } from '../shared/api'

/// `window.wp`: the only door from the UI to the backend (see `shared/api.ts`). No Node APIs reach the page.
const bridge: PlatformBridge = {
  platform: process.platform,
  call: (method, ...args) => ipcRenderer.invoke('wp:call', method, args),
  onState(listener) {
    const handler = (_event: unknown, state: AppState) => listener(state)
    ipcRenderer.on('wp:state', handler)
    ipcRenderer.send('wp:subscribe')
    return () => ipcRenderer.removeListener('wp:state', handler)
  },
  log(line) {
    ipcRenderer.send('wp:log', line)
  },
  mediaURL(kind, fileName) {
    return `wp-media://${kind}/${encodeURIComponent(fileName)}`
  },
}

contextBridge.exposeInMainWorld('wp', bridge)
