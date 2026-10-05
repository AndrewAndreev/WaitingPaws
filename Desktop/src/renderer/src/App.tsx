import { useEffect, useMemo, useState } from 'react'
import { language, setLanguage, systemLanguage, t } from '@shared/i18n'
import { setCoreLanguage, setCoreRegion } from '@core/localization'
import { ui, useStore } from './store'
import { TooltipProvider } from './ui/kit'
import { TitleBar } from './shell/TitleBar'
import { NavRail } from './shell/NavRail'
import { Toasts } from './shell/Toasts'
import { GlobalDialogs } from './shell/GlobalDialogs'
import { useGlobalShortcuts } from './shell/shortcuts'
import { TrainingPage } from './training/TrainingPage'
import { HistoryPage } from './history/HistoryPage'
import { SettingsPage } from './settings/SettingsPage'
import { WelcomePage } from './onboarding/WelcomePage'
import { isSetUp } from './model'

export function App() {
  const app = useStore((store) => store.app)
  const route = useStore((store) => store.route)
  const [, setLanguageTick] = useState(0)

  useEffect(() => window.wp.onState((state) => ui.set({ app: state })), [])

  // Language: the user's choice, or the system's; core texts (log, durations) follow too.
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
    if (next !== language()) {
      setLanguage(next)
      setCoreLanguage(next)
      document.documentElement.lang = next
      setLanguageTick((tick) => tick + 1)
    }
  }, [preference, systemLocale])

  // Theme: light/dark tokens follow the system unless the user picked one.
  const theme = app?.settings.theme ?? 'system'
  useEffect(() => {
    if (theme === 'system') delete document.documentElement.dataset.theme
    else document.documentElement.dataset.theme = theme
  }, [theme])

  useEffect(() => {
    const onBlur = () => document.documentElement.classList.add('window-inactive')
    const onFocus = () => document.documentElement.classList.remove('window-inactive')
    window.addEventListener('blur', onBlur)
    window.addEventListener('focus', onFocus)
    return () => {
      window.removeEventListener('blur', onBlur)
      window.removeEventListener('focus', onFocus)
    }
  }, [])

  useGlobalShortcuts()

  const setUp = useMemo(() => (app ? isSetUp(app.settings) : false), [app])

  if (!app || !app.ready) {
    return (
      <div className="splash">
        <span className="spinner spinner--lg" aria-label={t('Загрузка')} />
      </div>
    )
  }

  return (
    <TooltipProvider>
      <div className={'app' + (setUp ? '' : ' app--no-rail')} key={language()}>
        <TitleBar />
        {setUp && <NavRail />}
        <main className="page">
          {!setUp ? <WelcomePage /> : route === 'history' ? <HistoryPage /> : route === 'settings' ? <SettingsPage /> : <TrainingPage />}
        </main>
      </div>
      {setUp && <GlobalDialogs />}
      <Toasts />
    </TooltipProvider>
  )
}
