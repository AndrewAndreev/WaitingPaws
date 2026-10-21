import type { AppState } from '@shared/api'
import type { CameraSlot } from './store'
import type { Settings } from '@shared/settings'
import { cameraDisplayName } from '@shared/settings'
import { coreLocale } from '@core/localization'

/// A camera is selected (the stream of a reachable go2rtc).
export function isConfigured(settings: Settings): boolean {
  if (!settings.streamName) return false
  return settings.connectionMode === 'embedded' || settings.serverURL.trim() !== ''
}

/// Past the first-launch setup: with a camera, or explicitly without one.
export function isSetUp(settings: Settings): boolean {
  return isConfigured(settings) || settings.withoutCamera
}

export function cameraName(app: AppState): string {
  return cameraDisplayName(app.settings)
}

/// A second camera to switch to: set, and the main one too (it only comes with a main camera).
export function hasSecondCamera(settings: Settings): boolean {
  return isConfigured(settings) && settings.secondStreamName !== '' && settings.secondStreamName !== settings.streamName
}

/// The camera on screen: the second one only while it exists.
export function visibleCamera(settings: Settings, chosen: CameraSlot): CameraSlot {
  return chosen === 'second' && hasSecondCamera(settings) ? 'second' : 'main'
}

export function isRecording(app: AppState): boolean {
  return app.recording.since !== null || app.recording.resuming
}

/// Recording without a training: the picture takes the whole window, the clock floats over it.
export function isRecordingClip(app: AppState): boolean {
  return isRecording(app) && app.session === null
}

export function cameraOnline(app: AppState): boolean {
  return app.settings.connectionMode === 'external' || app.go2rtc.status === 'running'
}

/// "12:03" in the app's language with the computer's regional clock (24 h in Russia, 12 h in the US).
export function formatTime(ms: number, seconds = false): string {
  const locale = coreLocale()
  // "00:05" rather than "0:05" with a 24-hour clock (it would read as a duration); "12:05 AM" stays as is.
  const h23 = new Intl.DateTimeFormat(locale, { hour: 'numeric' }).resolvedOptions().hourCycle !== 'h12'
  return new Date(ms).toLocaleTimeString(locale, { hour: h23 ? '2-digit' : 'numeric', minute: '2-digit', ...(seconds ? { second: '2-digit' } : {}) })
}

/// "4 окт." / "Oct 4".
export function formatShortDate(ms: number): string {
  return new Date(ms).toLocaleDateString(coreLocale(), { day: 'numeric', month: 'short' })
}
