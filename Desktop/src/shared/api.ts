/// The contract between the UI (renderer) and the backend (Electron main process today; a small Node server
/// next to go2rtc in a web build). The UI never touches files, go2rtc's process or the network beyond the
/// camera player: it gets `AppState` snapshots and calls `BackendMethods` through `window.wp.call`.
import type { Settings } from './settings'

/// Core types travel as plain JSON (dates as epoch milliseconds, durations in seconds).
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Json = any
export type TrainingPlanJSON = Json
export type SessionSnapshotJSON = Json
export type TrainingRecordJSON = Json

export type Go2RTCStatusKind = 'idle' | 'starting' | 'running' | 'failed' | 'unavailable'

export interface ServerInfo {
  /// http://127.0.0.1:11984/ for the bundled go2rtc, the user's server otherwise.
  baseURL: string
  /// Basic auth is added by the backend (header rewriting); the UI never sees the password.
  hasCredentials: boolean
}

export interface RecordingClip {
  fileName: string
  /// Epoch ms.
  date: number
  size: number
}

export type XiaomiQuality = 'auto' | '1' | '2' | '3'

export interface PairingRequest {
  id: string
  deviceName: string
  /// From the iPhone's hello ("iphone", "iPhone 16"); missing from older builds.
  platform?: string | null
  model?: string | null
}

export interface PairedDeviceInfo {
  id: string
  name: string
  platform?: string | null
  model?: string | null
  /// Epoch ms of the last connection.
  lastSeen?: number | null
  connected?: boolean
}

export interface CameraModeOptionJSON {
  [key: string]: Json
}

export interface AppState {
  ready: boolean
  version: string
  platform: string
  /// The OS regional format ("ru-RU", "en-US"): 24-hour clock, date order.
  systemLocale: string
  settings: Settings
  go2rtc: { status: Go2RTCStatusKind; message: string | null; version: string | null; port: number; lanEnabled: boolean }
  /// go2rtc the player talks to (null: no camera configured).
  server: ServerInfo | null
  session: SessionSnapshotJSON | null
  pendingPlan: TrainingPlanJSON | null
  pendingOriginal: TrainingPlanJSON | null
  recording: {
    /// When the recording in progress started (its first part), epoch ms.
    since: number | null
    /// The camera stream broke off: waiting for it to write the next part.
    resuming: boolean
  }
  lastRecord: TrainingRecordJSON | null
  lastClip: RecordingClip | null
  /// Bumped whenever history or clips change; the UI fetches them with `history.list`.
  historyRevision: number
  /// Recordings being joined/finalized right now (file names).
  finalizing: string[]
  camera: {
    xiaomiQuality: XiaomiQuality | null
    xiaomiSource: string | null
    videoSize: { width: number; height: number } | null
    /// Bumped when every player must reconnect (quality changed, go2rtc restarted).
    playerGeneration: number
  }
  cameraModes: Json
  sync: {
    enabled: boolean
    connectedDevices: string[]
    pairedDevices: PairedDeviceInfo[]
    pairingRequests: PairingRequest[]
    error: string | null
    /// The name iPhones see (Bonjour, `welcome.hostName`).
    hostName?: string
  }
  errorMessage: string | null
  /// Paths for "Show in Explorer" texts.
  paths: { documents: string; recordings: string; sessions: string; logs: string }
}

export interface HistoryList {
  records: TrainingRecordJSON[]
  clips: RecordingClip[]
}

/// Methods the UI may call. Arguments and results are JSON.
export interface Go2RTCFetchRequest {
  url: string
  method?: string
  headers?: Record<string, string>
  body?: string | Uint8Array
}

export interface Go2RTCFetchResponse {
  status: number
  statusText: string
  headers: Record<string, string>
  body: Uint8Array
}

/// Methods the UI may call. Arguments and results are structured-clone data.
export interface BackendMethods {
  'settings.update'(patch: Partial<Settings>): void
  'session.start'(plan: TrainingPlanJSON): void
  'session.command'(command: 'startExit' | 'markBehindDoor' | 'endExit' | 'resetExit' | 'finish'): void
  'session.abandon'(): void
  'pending.set'(plan: TrainingPlanJSON | null, keepOriginal?: boolean): void
  'recording.toggle'(): void
  'recording.start'(): void
  'recording.stop'(): void
  'history.list'(): HistoryList
  'history.delete'(recordId: string, includingRecording: boolean): void
  'history.deleteClip'(fileName: string): void
  'history.deleteAll'(): void
  'history.logText'(recordId: string): string
  'history.finalize'(fileName: string): void
  'state.dismissLastRecord'(): void
  'state.dismissLastClip'(): void
  'state.dismissError'(): void
  'camera.setQuality'(quality: XiaomiQuality): void
  'camera.reportVideoSize'(width: number, height: number): void
  'camera.reconnect'(): void
  'camera.refresh'(): void
  'camera.setMode'(key: string, value: boolean | number): void
  'camera.continueWithout'(): void
  'go2rtc.restart'(): void
  /// A go2rtc API request made by the backend (the UI's Go2RTCClient uses it as its `fetch`).
  'go2rtc.fetch'(request: Go2RTCFetchRequest): Go2RTCFetchResponse
  'xiaomi.logout'(accountID: string): void
  /// The chosen camera: stream name, title, Xiaomi account and region.
  'streams.select'(patch: Partial<Settings>): void
  'sync.setEnabled'(enabled: boolean): void
  'sync.respond'(requestId: string, allow: boolean): void
  'sync.forget'(deviceId: string): void
  'shell.showItem'(kind: 'recordings' | 'sessions' | 'logs' | 'documents' | 'recording' | 'log' | 'go2rtcConfig', name?: string): void
  'shell.openExternal'(url: string): void
  'shell.openFile'(fileName: string): void
  /// Windows: «Разрешить взаимодействие с приложением через брандмауэр».
  'shell.openFirewall'(): void
  /// Puts the (finalized) recording on the clipboard as a file, ready to paste into a messenger.
  'shell.copyFile'(fileName: string): void
  'clipboard.readText'(): string
  'clipboard.writeText'(text: string): void
  'app.legal'(kind: 'privacy' | 'licenses'): string
  'app.diagnostics'(): Json
  'app.openLogFile'(): void
  'recordings.size'(): { files: number; bytes: number }
  /// Brings the main window back (from the compact strip).
  'window.restore'(): void
}

export type MethodName = keyof BackendMethods
export type MethodArgs<M extends MethodName> = Parameters<BackendMethods[M]>
export type MethodResult<M extends MethodName> = ReturnType<BackendMethods[M]>

/// What the preload script exposes as `window.wp` (and a web build implements over WebSocket/HTTP).
export interface PlatformBridge {
  platform: string
  call<M extends MethodName>(method: M, ...args: MethodArgs<M>): Promise<Awaited<MethodResult<M>>>
  onState(listener: (state: AppState) => void): () => void
  /// Log lines from the player go to the backend's log file.
  log(line: string): void
  /// URL of a user file the <video>/<img> elements can load (range requests supported).
  mediaURL(kind: 'recordings' | 'thumbnails', fileName: string): string
}

declare global {
  interface Window {
    wp: PlatformBridge
  }
}
