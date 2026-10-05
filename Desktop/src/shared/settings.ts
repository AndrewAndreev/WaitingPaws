/// User preferences shared by the backend (Electron main, or a server in a web build) and the UI.
/// Same keys and defaults as the Mac app's `AppSettings`.

export type PlayerMode = 'webrtc' | 'mse' | 'hls'
export type ConnectionMode = 'embedded' | 'external'
export type XiaomiRegion = 'cn' | 'ru' | 'de' | 'us' | 'sg' | 'i2'
export type ThemePreference = 'system' | 'dark' | 'light'
export type LanguagePreference = 'system' | 'ru' | 'en'

export interface Settings {
  connectionMode: ConnectionMode
  serverURL: string
  serverUsername: string
  /// Kept encrypted on disk (Electron safeStorage); the UI only sees whether one is set.
  serverPassword: string
  streamName: string
  cameraTitle: string
  xiaomiAccountID: string
  xiaomiRegion: XiaomiRegion
  /// Explicit player choice; null means the best default for the connection mode.
  playerMode: PlayerMode | null
  audioEnabled: boolean
  autoRecord: boolean
  autoFinishAfterLastBreak: boolean
  showPerformance: boolean
  lastPlanText: string
  /// Let iPhones on the same network find this computer, watch its camera and drive its training.
  shareWithIPhone: boolean
  /// The user chose «Продолжить без камеры»: timer, schedule and log only.
  withoutCamera: boolean
  /// What each quality level of a Mi Home camera really sent ("848x480"), by `did` and `subtype`.
  qualityResolutions: Record<string, Record<string, string>>
  theme: ThemePreference
  language: LanguagePreference
  /// Windows only: keep the computer awake while a training or a recording runs.
  keepAwake: boolean
}

export const defaultSettings: Settings = {
  connectionMode: 'embedded',
  serverURL: '',
  serverUsername: '',
  serverPassword: '',
  streamName: '',
  cameraTitle: '',
  xiaomiAccountID: '',
  xiaomiRegion: 'de',
  playerMode: null,
  audioEnabled: false,
  autoRecord: true,
  autoFinishAfterLastBreak: true,
  showPerformance: false,
  lastPlanText: '',
  // Off by default on Windows: opening go2rtc to the LAN brings up the firewall prompt, which only makes sense once
  // the user asks for the iPhone link (Settings → iPhone).
  shareWithIPhone: false,
  withoutCamera: false,
  qualityResolutions: {},
  theme: 'system',
  language: 'system',
  keepAwake: true,
}

/// MSE is the safe default for the bundled go2rtc; WebRTC gives the lowest latency with a real server.
export function effectivePlayerMode(settings: Settings): PlayerMode {
  const mode = settings.playerMode ?? (settings.connectionMode === 'embedded' ? 'mse' : 'webrtc')
  return mode
}

export function availablePlayerModes(settings: Settings): PlayerMode[] {
  return settings.connectionMode === 'embedded' ? ['mse', 'webrtc', 'hls'] : ['webrtc', 'mse', 'hls']
}

/// Mode string understood by go2rtc's `video-rtc.js`.
export function go2rtcModes(mode: PlayerMode): string {
  switch (mode) {
    case 'webrtc':
      return 'webrtc,mse,hls,mjpeg'
    case 'mse':
      return 'mse,hls,mjpeg'
    case 'hls':
      return 'hls,mjpeg'
  }
}

export function cameraDisplayName(settings: Settings): string {
  return settings.cameraTitle || settings.streamName
}
