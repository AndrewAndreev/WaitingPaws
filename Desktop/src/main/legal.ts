import { app } from 'electron'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { coreLanguage } from '@core/localization'

/// Privacy policy and open-source licenses: the Mac app's `App/Resources/Legal` files (copied next to the app by
/// electron-builder) plus the notices of what the Windows build adds (Electron, the UI libraries).
function legalDirectory(): string {
  return app.isPackaged ? join(process.resourcesPath, 'legal') : join(app.getAppPath(), '..', 'App', 'Resources', 'Legal')
}

function read(path: string): string {
  try {
    return existsSync(path) ? readFileSync(path, 'utf8') : ''
  } catch {
    return ''
  }
}

export function legalText(kind: 'privacy' | 'licenses'): string {
  const directory = legalDirectory()
  if (kind === 'privacy') return read(join(directory, coreLanguage() === 'ru' ? 'PrivacyPolicy-ru.md' : 'PrivacyPolicy-en.md'))
  const desktop = app.isPackaged ? join(process.resourcesPath, 'legal', 'ThirdPartyNotices-desktop.txt') : join(app.getAppPath(), 'build', 'ThirdPartyNotices-desktop.txt')
  return [read(join(directory, 'Acknowledgements.txt')), read(desktop)].filter(Boolean).join('\n\n')
}
