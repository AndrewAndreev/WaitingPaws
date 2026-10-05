import { useEffect, useState } from 'react'
import { language, setLanguage, systemLanguage } from '@shared/i18n'
import { coreLanguage, setCoreLanguage, setCoreRegion } from '@core/localization'
import type { AppState } from '@shared/api'

/// Language and theme of a window from the settings (the main window and the compact strip): the UI strings, the
/// core's texts (log, durations) and the regional clock follow the user's choice or the system's.
/// Returns a counter that changes with the language, for remounting what caches texts.
export function useAppearance(app: AppState | null): number {
  const [tick, setTick] = useState(0)
  const preference = app?.settings.language ?? 'system'
  const systemLocale = app?.systemLocale
  useEffect(() => {
    if (systemLocale) {
      try {
        setCoreRegion(new Intl.Locale(systemLocale).region ?? null)
      } catch {
        // Keep the browser's.
      }
    }
    const next = preference === 'system' ? systemLanguage() : preference
    if (next !== language() || next !== coreLanguage()) {
      setLanguage(next)
      setCoreLanguage(next)
      document.documentElement.lang = next
      setTick((value) => value + 1)
    }
  }, [preference, systemLocale])

  // Theme: light/dark tokens follow the system unless the user picked one.
  const theme = app?.settings.theme ?? 'system'
  useEffect(() => {
    if (theme === 'system') delete document.documentElement.dataset.theme
    else document.documentElement.dataset.theme = theme
  }, [theme])
  return tick
}
