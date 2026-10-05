import { app } from 'electron'
import { existsSync } from 'node:fs'
import { join } from 'node:path'

/// Where Waiting Paws keeps things on Windows (same layout as the Mac app where the user sees it):
///   Documents\Waiting Paws\Recordings\*.mp4, Documents\Waiting Paws\Sessions\*.txt|json — the user's files;
///   %APPDATA%\Waiting Paws\ — settings, go2rtc config (with Mi Home tokens), caches and logs.
/// `--ui-preview` keeps everything in a temporary folder (UI checks next to a real copy of the app).
export const isUIPreview = process.argv.includes('--ui-preview')

/// `--data-dir=<folder>`: everything (settings, go2rtc config, history, recordings, logs) in that folder instead of
/// the user's — checks and screenshots next to a real installation.
export function argValue(name: string): string | null {
  const prefix = `--${name}=`
  const match = process.argv.find((arg) => arg.startsWith(prefix))
  return match ? match.slice(prefix.length) : null
}
const dataDir = argValue('data-dir')

export const paths = {
  get documentsRoot(): string {
    if (dataDir) return join(dataDir, 'Documents', 'Waiting Paws')
    if (isUIPreview) return join(app.getPath('temp'), 'WaitingPawsPreview')
    return join(app.getPath('documents'), 'Waiting Paws')
  },
  get userData(): string {
    if (dataDir) return join(dataDir, 'AppData')
    if (isUIPreview) return join(app.getPath('temp'), 'WaitingPawsPreview', 'AppData')
    return app.getPath('userData')
  },
  get settingsFile(): string {
    return join(this.userData, 'settings.json')
  },
  get go2rtcConfig(): string {
    return join(this.userData, 'go2rtc', 'go2rtc.yaml')
  },
  get logsDirectory(): string {
    return join(this.userData, 'Logs')
  },
  get cacheDirectory(): string {
    return join(this.userData, 'Cache')
  },
  /// The bundled go2rtc.exe: `resources\bin` next to the app when packaged, `Desktop\resources\bin` in development.
  get go2rtcBinary(): string {
    const exe = process.platform === 'win32' ? 'go2rtc.exe' : 'go2rtc'
    if (app.isPackaged) return join(process.resourcesPath, 'bin', exe)
    // Development: next to package.json — the app path, or the working folder when a build in another folder
    // (`WP_OUT_DIR=out-x`) is started as `electron out-x/main/index.js`.
    const candidates = [join(app.getAppPath(), 'resources', 'bin', exe), join(process.cwd(), 'resources', 'bin', exe)]
    return candidates.find((path) => existsSync(path)) ?? candidates[0]
  },
}
