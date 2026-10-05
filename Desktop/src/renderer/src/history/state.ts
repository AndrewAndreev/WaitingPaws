// State of the History page that its parts share (the Mac app's `MacHistoryController` and `MacHistoryPlayer`):
// filter, search, sort, chart period, the inspector, pending deletes and the inspector's video player.
// The selection itself lives in the app store (`historySelection`) so other pages can open a row.
import { create } from 'zustand'
import { defaultSort, type HistoryRow, type Period, type Scope, type Sort } from './logic'

export interface PendingDelete {
  row: HistoryRow
  /// `null` lets the dialog offer both ways (training with a video, Delete key).
  onlyLog: boolean | null
}

interface HistoryUI {
  scope: Scope
  search: string
  sort: Sort
  period: Period
  showsInspector: boolean
  inspectorWidth: number
  pendingDelete: PendingDelete | null
  confirmDeleteAll: boolean
  /// Row whose log was just copied (the button says «Скопировано» for a moment).
  copiedKey: string | null
  /// Bumped when the table must bring the selection into view (chart click, a row opened from elsewhere).
  scrollRequest: number
  /// Inspector sections the user folded («Итоги», «Лог», «Видео»).
  collapsed: string[]
  set: (patch: Partial<Omit<HistoryUI, 'set'>>) => void
}

const WIDTH_KEY = 'wp.history.inspectorWidth'
const INSPECTOR_KEY = 'wp.history.showsInspector'

export const INSPECTOR_MIN = 300
export const INSPECTOR_MAX = 560

function readNumber(key: string, fallback: number): number {
  try {
    const value = Number(localStorage.getItem(key))
    return Number.isFinite(value) && value > 0 ? value : fallback
  } catch {
    return fallback
  }
}

function readFlag(key: string, fallback: boolean): boolean {
  try {
    const value = localStorage.getItem(key)
    return value === null ? fallback : value === '1'
  } catch {
    return fallback
  }
}

export function remember(key: 'width' | 'inspector', value: number | boolean): void {
  try {
    localStorage.setItem(key === 'width' ? WIDTH_KEY : INSPECTOR_KEY, typeof value === 'boolean' ? (value ? '1' : '0') : String(Math.round(value)))
  } catch {
    // A preference, not worth an error.
  }
}

export const useHistoryUI = create<HistoryUI>((set) => ({
  scope: 'all',
  search: '',
  sort: defaultSort,
  period: 'fourWeeks',
  showsInspector: readFlag(INSPECTOR_KEY, true),
  inspectorWidth: Math.min(INSPECTOR_MAX, Math.max(INSPECTOR_MIN, readNumber(WIDTH_KEY, 360))),
  pendingDelete: null,
  confirmDeleteAll: false,
  copiedKey: null,
  scrollRequest: 0,
  collapsed: [],
  set: (patch) => set(patch),
}))

export const historyUI = {
  get: () => useHistoryUI.getState(),
  set: (patch: Partial<Omit<HistoryUI, 'set'>>) => useHistoryUI.getState().set(patch),
}

// MARK: - Player

interface PlayerState {
  /// The inspector's <video>, while it is on screen.
  element: HTMLVideoElement | null
  /// The file the element has loaded (ready to seek and play).
  loaded: string | null
  /// Seconds into the loaded video.
  time: number
  playing: boolean
  /// «Воспроизвести» asked for a file that is still loading (or being finalized).
  playWhenLoaded: string | null
}

export const usePlayer = create<PlayerState>(() => ({ element: null, loaded: null, time: 0, playing: false, playWhenLoaded: null }))

export const player = {
  /// Plays `fileName` once the inspector has loaded it (right away if it already has).
  play(fileName: string): void {
    const state = usePlayer.getState()
    if (state.loaded === fileName && state.element) {
      void state.element.play().catch(() => undefined)
      usePlayer.setState({ playWhenLoaded: null })
    } else {
      usePlayer.setState({ playWhenLoaded: fileName })
    }
  },
  toggle(fileName: string): void {
    const state = usePlayer.getState()
    if (state.loaded !== fileName || !state.element) return player.play(fileName)
    if (state.element.paused) void state.element.play().catch(() => undefined)
    else state.element.pause()
  },
  pause(): void {
    usePlayer.getState().element?.pause()
  },
  seek(seconds: number): void {
    const { element } = usePlayer.getState()
    if (!element) return
    const duration = Number.isFinite(element.duration) ? element.duration : Infinity
    const target = Math.max(0, Math.min(seconds, duration))
    element.currentTime = target
    usePlayer.setState({ time: target })
  },
}
