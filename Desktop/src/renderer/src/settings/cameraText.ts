import { t } from '@shared/i18n'
import type { AppState } from '@shared/api'
import type { XiaomiRegion } from '@shared/settings'
import { Go2RTCClient, Go2RTCServer } from '@core/go2rtcClient'
export { queryValue } from '@core/go2rtcClient'
import { bridgeFetch } from '../platform/bridge'

/// The go2rtc the app talks to is up (the bundled one running, or the user's server configured).
export function serverReady(app: AppState): boolean {
  if (!app.server) return false
  return app.settings.connectionMode === 'external' || app.go2rtc.status === 'running'
}

/// A client for the active go2rtc; the backend adds the server's credentials to its requests.
export function activeClient(app: AppState): Go2RTCClient | null {
  if (!app.server || !serverReady(app)) return null
  return new Go2RTCClient(Go2RTCServer.make(app.server.baseURL), { fetch: bridgeFetch })
}

/// "2304×1296"; a width that is a multiple of 16 with a height a few pixels off 16:9 is shown as 16:9.
export function pixels(width: number, height: number): string {
  const w = Math.round(width)
  let h = Math.round(height)
  if (w % 16 === 0 && Math.abs(h - (w * 9) / 16) <= 8) h = (w * 9) / 16
  return `${w}×${h}`
}

const vendors: Record<string, string> = { xiaomi: 'Xiaomi', mijia: 'Xiaomi', chuangmi: 'Xiaomi', isa: 'Xiaomi', xiaovv: 'Xiaovv', lumi: 'Aqara' }

/// "chuangmi.camera.039a01" → «Камера Xiaomi»; unknown makers are «Камера Mi Home».
export function cameraKind(model: string | null): string {
  const parts = (model ?? '').toLowerCase().split('.')
  const peephole = parts.length > 1 && parts[1] === 'cateye'
  const vendor = vendors[parts[0] ?? '']
  if (!vendor) return peephole ? t('Видеоглазок Mi Home') : t('Камера Mi Home')
  return peephole ? t('Видеоглазок %@', vendor) : t('Камера %@', vendor)
}

/// "rtsp://192.168.1.20:554/live" → "RTSP".
export function sourceBadge(source: string | null): string | null {
  if (!source || !source.includes(':')) return null
  const scheme = source.split(':')[0].toLowerCase()
  if (!scheme) return null
  switch (scheme) {
    case 'xiaomi':
      return 'Mi Home'
    case 'rtsp':
    case 'rtsps':
    case 'rtspx':
      return 'RTSP'
    case 'onvif':
      return 'ONVIF'
    case 'http':
    case 'https':
      return 'HTTP'
    case 'ffmpeg':
      return 'FFmpeg'
    case 'exec':
      return 'exec'
    case 'homekit':
      return 'HomeKit'
    default:
      return scheme.toUpperCase()
  }
}

export function sourceHost(source: string): string | null {
  try {
    return new URL(source).hostname || null
  } catch {
    return null
  }
}

/// A source URL without its password ("rtsp://admin:secret@…" → "rtsp://admin@…").
export function redacted(source: string): string {
  return source.replace(/^([a-z0-9+.-]+:\/\/[^:/@]+):[^@/]*@/i, '$1@')
}

export function regionTitle(region: XiaomiRegion): string {
  switch (region) {
    case 'ru':
      return t('Россия')
    case 'de':
      return t('Европа')
    case 'cn':
      return t('Китай')
    case 'us':
      return t('США')
    case 'sg':
      return t('Сингапур')
    case 'i2':
      return t('Индия')
  }
}

/// Whether the selected camera is a Mi Home one: its source settles it, then the quality go2rtc reported, then the
/// saved account (while go2rtc is not running).
export function isXiaomiCamera(app: AppState, source: string | null): boolean {
  if (source) return source.startsWith('xiaomi://')
  if (app.camera.xiaomiSource) return true
  if (serverReady(app)) return app.camera.xiaomiQuality !== null
  return app.settings.xiaomiAccountID !== ''
}

/// «работает, go2rtc 1.9.14», «запускается…», «ошибка: …» — the bundled go2rtc.
export function go2rtcStatusText(app: AppState): string {
  switch (app.go2rtc.status) {
    case 'running':
      return t('работает, go2rtc %@', app.go2rtc.version ?? '')
    case 'starting':
      return t('запускается…')
    case 'failed':
      return t('ошибка: %@', app.go2rtc.message ?? '')
    case 'unavailable':
      return t('go2rtc.exe не найден')
    case 'idle':
      return t('не запущен')
  }
}
