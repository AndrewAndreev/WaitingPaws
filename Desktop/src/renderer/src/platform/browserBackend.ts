// The backend for the UI opened in a plain browser: the web preview of the app. Everything that needs no files and
// no camera works for real — the schedule parser, the training engine, the log, history (kept in localStorage).
// A web deployment next to a go2rtc server would replace this with calls to a small server (same `BackendMethods`).
import type { AppState, BackendMethods, HistoryList, MethodName, PlatformBridge } from '@shared/api'
import { defaultSettings, type Settings } from '@shared/settings'
import { TrainingSession } from '@core/trainingSession'
import { TrainingPlan } from '@core/models'
import { SessionLogFormatter, TrainingRecord } from '@core/sessionLog'
import { DISK_DATES } from '@core/codable'

const SETTINGS_KEY = 'wp.settings'
const HISTORY_KEY = 'wp.history'

export function createBrowserBridge(): PlatformBridge {
  const listeners = new Set<(state: AppState) => void>()
  let settings: Settings = { ...defaultSettings, ...readJSON<Partial<Settings>>(SETTINGS_KEY, {}) }
  let history: TrainingRecord[] = readHistory()
  let session: TrainingSession | null = null
  let pendingPlan: TrainingPlan | null = null
  let pendingOriginal: TrainingPlan | null = null
  let lastRecord: TrainingRecord | null = null
  let errorMessage: string | null = null
  let historyRevision = 1
  let tick: number | null = null

  const state = (): AppState => ({
    ready: true,
    version: 'web',
    platform: 'web',
    systemLocale: navigator.language,
    settings,
    go2rtc: { status: 'unavailable', message: null, version: null, port: 0, lanEnabled: false },
    server: null,
    session: session?.snapshot ?? null,
    pendingPlan,
    pendingOriginal,
    recording: { since: null, resuming: false },
    lastRecord,
    lastClip: null,
    historyRevision,
    finalizing: [],
    camera: { xiaomiQuality: null, xiaomiSource: null, videoSize: null, playerGeneration: 0 },
    cameraModes: { state: 'none', reason: null, error: null, options: [] },
    sync: { enabled: false, connectedDevices: [], pairedDevices: [], pairingRequests: [], error: null },
    errorMessage,
    paths: { documents: '', recordings: '', sessions: '', logs: '' },
  })

  const emit = () => {
    const snapshot = state()
    for (const listener of listeners) listener(snapshot)
  }

  const saveHistory = () => {
    localStorage.setItem(HISTORY_KEY, JSON.stringify(history.map((record) => TrainingRecord.encode(record, DISK_DATES))))
    historyRevision += 1
  }

  const complete = () => {
    if (!session || !session.isFinished) return
    const record = session.makeRecord(null)
    history = [record, ...history]
    saveHistory()
    lastRecord = record
    session = null
    if (tick) window.clearInterval(tick)
    tick = null
  }

  const methods: Partial<{ [M in MethodName]: (...args: Parameters<BackendMethods[M]>) => unknown }> = {
    'settings.update': (patch) => {
      settings = { ...settings, ...patch }
      localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings))
    },
    'session.start': (plan) => {
      session = new TrainingSession(TrainingPlan.renumbered(plan as TrainingPlan))
      session.subscribe(() => emit())
      pendingPlan = null
      pendingOriginal = null
      lastRecord = null
      tick = window.setInterval(() => {
        session?.tick()
        complete()
        emit()
      }, 500)
    },
    'session.command': (command) => {
      if (!session) return
      if (command === 'finish') session.finish()
      else session[command]()
      complete()
    },
    'session.updatePlan': (plan, options) =>
      session?.updatePlan(plan as TrainingPlan, { quiet: options?.quiet, changesSince: (options?.changesSince as TrainingPlan | null) ?? null }) ?? false,
    'session.abandon': () => {
      session = null
      if (tick) window.clearInterval(tick)
    },
    'pending.set': (plan, keepOriginal) => {
      pendingPlan = (plan as TrainingPlan | null) ?? null
      if (!keepOriginal) pendingOriginal = pendingPlan
    },
    'history.list': (): HistoryList => ({ records: history, clips: [] }),
    'history.delete': (id) => {
      history = history.filter((record) => record.id !== id)
      if (lastRecord?.id === id) lastRecord = null
      saveHistory()
    },
    'history.deleteAll': () => {
      history = []
      lastRecord = null
      saveHistory()
    },
    'history.logText': (id) => {
      const record = history.find((item) => item.id === id)
      return record ? SessionLogFormatter.text(record) : ''
    },
    'state.dismissLastRecord': () => {
      lastRecord = null
    },
    'state.dismissError': () => {
      errorMessage = null
    },
    'camera.continueWithout': () => {
      settings = { ...settings, withoutCamera: true }
      localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings))
    },
    'clipboard.readText': () => navigator.clipboard.readText(),
    'clipboard.writeText': (text) => navigator.clipboard.writeText(text),
    'shell.openExternal': (url) => {
      window.open(url, '_blank', 'noopener')
    },
    'app.legal': () => '',
    'recordings.size': () => ({ files: 0, bytes: 0 }),
  }

  return {
    platform: 'web',
    async call(method, ...args) {
      const handler = methods[method] as ((...args: unknown[]) => unknown) | undefined
      if (!handler) {
        errorMessage = 'Недоступно в веб-версии без сервера'
        emit()
        throw new Error(errorMessage)
      }
      const result = await handler(...args)
      emit()
      return result as never
    },
    onState(listener) {
      listeners.add(listener)
      listener(state())
      return () => listeners.delete(listener)
    },
    log(line) {
      console.info(line)
    },
    mediaURL(_kind, fileName) {
      return fileName
    },
  }
}

function readJSON<T>(key: string, fallback: T): T {
  try {
    const text = localStorage.getItem(key)
    return text ? (JSON.parse(text) as T) : fallback
  } catch {
    return fallback
  }
}

function readHistory(): TrainingRecord[] {
  const list = readJSON<unknown[]>(HISTORY_KEY, [])
  const records: TrainingRecord[] = []
  for (const item of list) {
    try {
      records.push(TrainingRecord.decode(item, DISK_DATES))
    } catch {
      // A record from an older build: skipped.
    }
  }
  return records
}
