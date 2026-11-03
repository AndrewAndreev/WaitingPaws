import { useEffect, useState } from 'react'
import { create } from 'zustand'
import type { AppState, MethodArgs, MethodName, MethodResult } from '@shared/api'

/// The backend's state as last pushed, plus window-level UI state that menus, the title bar and panels share
/// (the Mac app's `MacUIState`).
export type Route = 'training' | 'history' | 'settings'
export type CameraSlot = 'main' | 'second'
export type SettingsPane = 'camera' | 'connection' | 'training' | 'recording' | 'iphone' | 'appearance' | 'diagnostics' | 'about'

interface UIStore {
  app: AppState | null
  route: Route
  settingsPane: SettingsPane
  /// «Расписание разобрано» dialog over the waiting schedule.
  reviewingPlan: boolean
  /// The running training's schedule open for edits.
  editingSessionPlan: boolean
  showCameraPicker: boolean
  /// The camera on screen when there is a second one (Ctrl+1 / Ctrl+2). Both players stay connected.
  camera: CameraSlot
  /// Which players show a picture (the dot «на связи» on the hidden camera).
  cameraLive: Record<CameraSlot, boolean>
  /// «Переподключить» with the second camera on screen reconnects it too.
  secondCameraReload: number
  showXiaomiSignIn: boolean
  showServerSetup: boolean
  confirmFinish: boolean
  /// «Остановить запись?»: a stop by mistake (Ctrl+R, REC in the title bar) cut many recordings short.
  confirmStopRecording: boolean
  /// History: the record or clip selected in the table (opened from the summary dialog, "jump to exit"…).
  historySelection: { kind: 'record' | 'clip'; id: string } | null
  /// Seek request for the history player (seconds into the selected recording).
  historySeek: { time: number; token: number } | null
  toasts: Toast[]
  set: (patch: Partial<Omit<UIStore, 'set'>>) => void
}

export interface Toast {
  id: number
  title: string
  detail?: string
  kind?: 'info' | 'success' | 'warning' | 'danger'
}

export const useStore = create<UIStore>((set) => ({
  app: null,
  route: 'training',
  settingsPane: 'camera',
  reviewingPlan: false,
  editingSessionPlan: false,
  showCameraPicker: false,
  camera: 'main',
  cameraLive: { main: false, second: false },
  secondCameraReload: 0,
  showXiaomiSignIn: false,
  showServerSetup: false,
  confirmFinish: false,
  confirmStopRecording: false,
  historySelection: null,
  historySeek: null,
  toasts: [],
  set: (patch) => set(patch),
}))

export function useApp(): AppState {
  const app = useStore((store) => store.app)
  if (!app) throw new Error('App state is not loaded yet')
  return app
}

export const ui = {
  get: () => useStore.getState(),
  set: (patch: Partial<Omit<UIStore, 'set'>>) => useStore.getState().set(patch),
}

// For checks and screenshots (`--eval=__wpUI.set({route:'history'})`).
;(window as unknown as { __wpUI: typeof ui }).__wpUI = ui

/// Calls a backend method; errors become a toast instead of an unhandled rejection.
export async function call<M extends MethodName>(method: M, ...args: MethodArgs<M>): Promise<Awaited<MethodResult<M>> | undefined> {
  try {
    return await window.wp.call(method, ...args)
  } catch (error) {
    toast({ title: String((error as Error)?.message ?? error).replace(/^Error invoking remote method '[^']+': (Error: )?/, ''), kind: 'danger' })
    return undefined
  }
}

/// Like `call`, but lets the caller handle the error.
export function callStrict<M extends MethodName>(method: M, ...args: MethodArgs<M>): Promise<Awaited<MethodResult<M>>> {
  return window.wp.call(method, ...args).catch((error: Error) => {
    throw new Error(String(error?.message ?? error).replace(/^Error invoking remote method '[^']+': (Error: )?/, ''))
  })
}

let toastId = 0
export function toast(toast: Omit<Toast, 'id'>, duration = 5000): void {
  const id = ++toastId
  ui.set({ toasts: [...ui.get().toasts, { ...toast, id }] })
  setTimeout(() => ui.set({ toasts: ui.get().toasts.filter((item) => item.id !== id) }), duration)
}

/// The current time, refreshed every `interval` ms (timers, clocks, timelines).
export function useNow(interval = 500): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), interval)
    return () => window.clearInterval(id)
  }, [interval])
  return now
}
