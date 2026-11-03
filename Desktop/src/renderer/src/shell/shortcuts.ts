import { useEffect } from 'react'
import { ui } from '../store'
import { falseStart, pasteSchedule, primaryStep, startPending, toggleRecording } from '../actions'
import { hasSecondCamera, isConfigured, isRecording } from '../model'

/// Keyboard shortcuts of the window: the Mac app's (`MacCommands`) with Ctrl for ⌘ — Ctrl+E edits the running
/// schedule, Ctrl+. finishes, Ctrl+1 / Ctrl+2 pick the camera; history is Ctrl+H (Ctrl+Y is Redo on Windows), F11
/// full screen is handled by the main process. Space and Backspace drive the training only on the training page and
/// never inside text fields.
export function useGlobalShortcuts(): void {
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const store = ui.get()
      const app = store.app
      if (!app) return
      const target = event.target as HTMLElement | null
      const typing = !!target && (target.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName))
      const dialogOpen = !!document.querySelector('[role="dialog"]')
      const key = latinKey(event)
      const ctrl = event.ctrlKey || event.metaKey

      if (ctrl && !event.shiftKey && !event.altKey) {
        switch (key) {
          // Ctrl+1: the training page with the main camera; Ctrl+2: the second camera, when there is one.
          case '1':
            event.preventDefault()
            return ui.set({ route: 'training', camera: 'main' })
          case '2':
            event.preventDefault()
            if (hasSecondCamera(app.settings)) ui.set({ route: 'training', camera: 'second' })
            return
          case 'h':
            event.preventDefault()
            return ui.set({ route: 'history' })
          case ',':
            event.preventDefault()
            return ui.set({ route: 'settings' })
          case 'r':
            event.preventDefault()
            if (isRecording(app) || isConfigured(app.settings)) toggleRecording(app)
            return
          case 'enter':
            if (dialogOpen && !store.reviewingPlan) return
            event.preventDefault()
            return void startPending()
          case 'e':
            if (!app.session || dialogOpen) return
            event.preventDefault()
            return ui.set({ editingSessionPlan: true })
          case '.':
            if (!app.session || dialogOpen) return
            event.preventDefault()
            return ui.set({ confirmFinish: true })
        }
      }
      if (ctrl && event.shiftKey && !event.altKey) {
        if (key === 'v' && !typing) {
          event.preventDefault()
          return void pasteSchedule()
        }
      }
      if (ctrl || event.altKey || typing || dialogOpen || store.route !== 'training') return
      if (event.key === ' ' && (app.session || app.pendingPlan)) {
        event.preventDefault()
        if (!event.repeat) void primaryStep()
      } else if (event.key === 'Backspace' && app.session) {
        event.preventDefault()
        falseStart()
      }
    }
    window.addEventListener('keydown', onKey)
    // A schedule pasted anywhere on the training page (Ctrl+V outside text fields) is a schedule.
    const onPaste = (event: ClipboardEvent) => {
      const target = event.target as HTMLElement | null
      if (target && (target.isContentEditable || ['INPUT', 'TEXTAREA'].includes(target.tagName))) return
      if (ui.get().route !== 'training' || document.querySelector('[role="dialog"]')) return
      const text = event.clipboardData?.getData('text/plain')
      if (text) {
        event.preventDefault()
        void pasteSchedule(text)
      }
    }
    window.addEventListener('paste', onPaste)
    return () => {
      window.removeEventListener('keydown', onKey)
      window.removeEventListener('paste', onPaste)
    }
  }, [])
}

/// `event.key`, or with a non-Latin layout (Russian: «у» for Ctrl+E, «б» for Ctrl+,) the key's US character — as the
/// Mac does for its menu shortcuts.
function latinKey(event: KeyboardEvent): string {
  const key = event.key.toLowerCase()
  if (key.length !== 1 || /[ -~]/.test(key)) return key
  if (event.code.startsWith('Key')) return event.code.slice(3).toLowerCase()
  if (event.code.startsWith('Digit')) return event.code.slice(5)
  return ({ Comma: ',', Period: '.' } as Record<string, string>)[event.code] ?? key
}
