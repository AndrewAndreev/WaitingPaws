import { app, BrowserWindow, ipcMain, Menu, nativeTheme, powerSaveBlocker, screen, session, shell } from 'electron'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { release } from 'node:os'
import { argValue, isUIPreview, paths } from './paths'
import { startLog, write as log } from './log'
import { SettingsStore } from './settings'
import { handleMediaScheme, registerMediaScheme } from './media-protocol'
import { AppBackend } from './backend'
import { MediaFinalizer } from './finalizer'
import type { ThemePreference } from '@shared/settings'

/// Waiting Paws for Windows: one window (training, history and settings are pages of it), the bundled go2rtc as a
/// child process, recordings finalized in a hidden window. See README «Windows».

registerMediaScheme()
app.setAppUserModelId('su.comrade.waitingpaws')

// A separate data folder is a separate instance (and keeps Chromium's profile apart too).
if (argValue('data-dir')) app.setPath('userData', join(argValue('data-dir')!, 'AppData'))

if (!app.requestSingleInstanceLock() && !isUIPreview && !argValue('data-dir')) {
  app.quit()
} else {
  void start()
}

let mainWindow: BrowserWindow | null = null
let backend: AppBackend | null = null

/// Windows 11 22H2+ (build 22621) draws Mica behind the window; earlier systems get a solid background.
const supportsMica =
  process.platform === 'win32' && Number(release().split('.')[2] ?? 0) >= 22621 && !process.argv.some((arg) => arg.startsWith('--capture='))

function load(window: BrowserWindow, page: 'index' | 'media'): Promise<void> {
  const devServer = process.env.ELECTRON_RENDERER_URL
  if (!app.isPackaged && devServer) return window.loadURL(`${devServer}/${page}.html`)
  return window.loadFile(join(__dirname, `../renderer/${page}.html`))
}

async function start(): Promise<void> {
  await app.whenReady()
  startLog(paths.logsDirectory)
  log(`[app] Waiting Paws ${app.getVersion()} on ${process.platform} ${release()} (Electron ${process.versions.electron})`)
  Menu.setApplicationMenu(null)

  const settings = new SettingsStore(paths.settingsFile)
  applyTheme(settings.value.theme)
  settings.onChange((value) => applyTheme(value.theme))

  handleMediaScheme(() => ({
    recordings: join(paths.documentsRoot, 'Recordings'),
    thumbnails: join(paths.cacheDirectory, 'Thumbnails'),
  }))

  const finalizer = new MediaFinalizer(
    () => [paths.documentsRoot, app.getPath('temp')],
    (window) => load(window, 'media'),
    join(__dirname, '../preload/media.js'),
  )
  backend = new AppBackend(settings, finalizer)
  backend.onState((state) => mainWindow?.webContents.send('wp:state', state))

  installNetworkRules(backend)

  ipcMain.handle('wp:call', (_event, method: string, args: unknown[]) => backend!.call(method, args))
  ipcMain.on('wp:subscribe', (event) => event.sender.send('wp:state', backend!.state()))
  ipcMain.on('wp:log', (_event, line: string) => log(line))

  createWindow()
  await backend.start()

  // Keep the computer awake while a training or a recording runs.
  let blocker: number | null = null
  backend.onState((state) => {
    const busy = state.settings.keepAwake && (state.session !== null || state.recording.since !== null || state.recording.resuming)
    if (busy && blocker === null) blocker = powerSaveBlocker.start('prevent-display-sleep')
    if (!busy && blocker !== null) {
      powerSaveBlocker.stop(blocker)
      blocker = null
    }
  })

  app.on('second-instance', () => {
    if (!mainWindow) return
    if (mainWindow.isMinimized()) mainWindow.restore()
    mainWindow.focus()
  })
  app.on('window-all-closed', () => app.quit())
  let quitting = false
  app.on('before-quit', (event) => {
    if (quitting || !backend) return
    event.preventDefault()
    quitting = true
    void backend.shutdown().finally(() => {
      finalizer.dispose()
      app.quit()
    })
  })
}

function applyTheme(theme: ThemePreference): void {
  nativeTheme.themeSource = theme
  updateTitleBarOverlay()
}

function titleBarOverlay(): Electron.TitleBarOverlay {
  const dark = nativeTheme.shouldUseDarkColors
  return { color: '#00000000', symbolColor: dark ? '#ffffff' : '#1b1a1a', height: 48 }
}

function updateTitleBarOverlay(): void {
  if (mainWindow && !mainWindow.isDestroyed() && process.platform === 'win32') mainWindow.setTitleBarOverlay(titleBarOverlay())
}
nativeTheme.on('updated', updateTitleBarOverlay)

interface WindowState {
  x?: number
  y?: number
  width: number
  height: number
  maximized: boolean
}

function loadWindowState(): WindowState {
  try {
    const state = JSON.parse(readFileSync(join(paths.userData, 'window.json'), 'utf8')) as WindowState
    // Only if it is still on a connected display.
    const visible = screen.getAllDisplays().some((display) => {
      const area = display.workArea
      return state.x !== undefined && state.y !== undefined && state.x < area.x + area.width - 100 && state.x + state.width > area.x + 100 && state.y >= area.y - 20 && state.y < area.y + area.height - 100
    })
    return visible ? state : { width: state.width, height: state.height, maximized: state.maximized }
  } catch {
    return { width: 1360, height: 860, maximized: false }
  }
}

function saveWindowState(window: BrowserWindow): void {
  try {
    const bounds = window.getNormalBounds()
    const state: WindowState = { ...bounds, maximized: window.isMaximized() }
    writeFileSync(join(paths.userData, 'window.json'), JSON.stringify(state))
  } catch {
    // Not worth an error.
  }
}

function createWindow(): void {
  const state = loadWindowState()
  const dark = nativeTheme.shouldUseDarkColors
  const window = new BrowserWindow({
    x: state.x,
    y: state.y,
    width: state.width,
    height: state.height,
    minWidth: 980,
    minHeight: 640,
    show: false,
    title: 'Waiting Paws',
    icon: app.isPackaged ? join(process.resourcesPath, 'icon.png') : join(app.getAppPath(), 'resources', 'icon.png'),
    backgroundColor: supportsMica ? '#00000000' : dark ? '#181617' : '#eceaea',
    ...(supportsMica ? { backgroundMaterial: 'mica' as const } : {}),
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'hidden',
    ...(process.platform !== 'darwin' ? { titleBarOverlay: titleBarOverlay() } : {}),
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      sandbox: true,
      contextIsolation: true,
      // The camera player must keep reading its WebSocket when the window is covered: a throttled page falls
      // behind and go2rtc drops frames for it (a freeze until the next keyframe).
      backgroundThrottling: false,
      spellcheck: false,
    },
  })
  mainWindow = window
  if (state.maximized) window.maximize()
  window.once('ready-to-show', () => window.show())
  window.on('close', () => saveWindowState(window))
  window.on('closed', () => {
    mainWindow = null
  })
  // Links open in the browser, never inside the app.
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) void shell.openExternal(url)
    return { action: 'deny' }
  })
  window.webContents.on('will-navigate', (event, url) => {
    const devServer = process.env.ELECTRON_RENDERER_URL
    if (devServer && url.startsWith(devServer)) return
    event.preventDefault()
  })
  window.webContents.on('before-input-event', (event, input) => {
    if (input.type !== 'keyDown') return
    if (input.key === 'F11') {
      window.setFullScreen(!window.isFullScreen())
      event.preventDefault()
    } else if (input.key === 'F12' || (input.control && input.shift && input.key.toLowerCase() === 'i')) {
      window.webContents.toggleDevTools()
      event.preventDefault()
    }
  })
  if (supportsMica) void window.webContents.executeJavaScript(`document.documentElement.classList.add('mica')`).catch(() => undefined)
  window.webContents.on('did-finish-load', () => {
    if (supportsMica) void window.webContents.executeJavaScript(`document.documentElement.classList.add('mica')`).catch(() => undefined)
  })
  void load(window, 'index').then(() => runDebugArguments(window))
}

/// Development helpers for checks and screenshots:
///   --eval=<js>            run in the page once it is loaded (e.g. `__wpUI.set({route:'history'})`)
///   --capture=<file.png>   save a picture of the window after --capture-delay=<ms> (default 4000)
///   --quit-after-capture   then quit
function runDebugArguments(window: BrowserWindow): void {
  const script = argValue('eval')
  const capture = argValue('capture')
  const size = argValue('window-size')
  if (size) {
    const [width, height] = size.split('x').map(Number)
    if (width && height) window.setSize(width, height)
  }
  if (script) setTimeout(() => void window.webContents.executeJavaScript(script).catch((error) => log(`[debug] eval: ${error}`)), 1500)
  if (!capture) return
  setTimeout(async () => {
    try {
      const image = await window.webContents.capturePage()
      writeFileSync(capture, image.toPNG())
      log(`[debug] captured ${capture}`)
    } catch (error) {
      log(`[debug] capture failed: ${error}`)
    }
    if (process.argv.includes('--quit-after-capture')) app.quit()
  }, Number(argValue('capture-delay') ?? 4000))
}

/// The app's own requests to go2rtc: no browser Origin (go2rtc's guard refuses foreign origins, which protects it
/// from web pages in the user's browser, not from us) and Basic auth for a user's server with a password.
function installNetworkRules(backend: AppBackend): void {
  const filter = { urls: ['http://*/*', 'ws://*/*', 'https://*/*', 'wss://*/*'] }
  session.defaultSession.webRequest.onBeforeSendHeaders(filter, (details, callback) => {
    const headers = { ...details.requestHeaders }
    const server = backend.serverForRequest(details.url)
    if (server) {
      delete headers.Origin
      delete headers.origin
      if (server.authorization) headers.Authorization = server.authorization
    }
    callback({ requestHeaders: headers })
  })
  session.defaultSession.webRequest.onHeadersReceived(filter, (details, callback) => {
    if (!backend.serverForRequest(details.url)) return callback({})
    const headers = { ...(details.responseHeaders ?? {}) }
    headers['Access-Control-Allow-Origin'] = ['*']
    callback({ responseHeaders: headers })
  })
}
