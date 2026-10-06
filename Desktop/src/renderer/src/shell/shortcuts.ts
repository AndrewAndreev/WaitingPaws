import { useEffect } from 'react'
import { call, ui } from '../store'
import { falseStart, pasteSchedule, primaryStep, startPending } from '../actions'
import { isConfigured, isRecording } from '../model'

/// Keyboard shortcuts of the window (Windows conventions: Ctrl, not ⌘; F11 full screen is handled by the main
/// process). Space and Backspace drive the training only on the training page and never inside text fields.
export function useGlobalShortcuts(): void {
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const store = ui.get()
      const app = store.app
      if (!app) return
      const target = event.target as HTMLElement | null
      const typing = !!target && (target.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName))
      const dialogOpen = !!document.querySelector('[role="dialog"]')
      const key = event.key.toLowerCase()
      const ctrl = event.ctrlKey || event.metaKey

      if (ctrl && !event.shiftKey && !event.altKey) {
        switch (key) {
          case '1':
            event.preventDefault()
            return ui.set({ route: 'training' })
          case '2':
          case 'h':
            event.preventDefault()
            return ui.set({ route: 'history' })
          case ',':
            event.preventDefault()
            return ui.set({ route: 'settings' })
          case 'r':
            event.preventDefault()
            if (isRecording(app) || isConfigured(app.settings)) void call('recording.toggle')
            return
          case 'enter':
            if (dialogOpen && !store.reviewingPlan) return
            event.preventDefault()
            return void startPending()
          case 'e':
            if (!app.session) return
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
