import { useEffect, useMemo } from 'react'
import { language, t } from '@shared/i18n'
import { ui, useStore } from './store'
import { TooltipProvider } from './ui/kit'
import { TitleBar } from './shell/TitleBar'
import { NavRail } from './shell/NavRail'
import { Toasts } from './shell/Toasts'
import { GlobalDialogs } from './shell/GlobalDialogs'
import { useGlobalShortcuts } from './shell/shortcuts'
import { useAppearance } from './shell/appearance'
import { TrainingPage } from './training/TrainingPage'
import { HistoryPage } from './history/HistoryPage'
import { SettingsPage } from './settings/SettingsPage'
import { WelcomePage } from './onboarding/WelcomePage'
import { isSetUp } from './model'

export function App() {
  const app = useStore((store) => store.app)
  const route = useStore((store) => store.route)

  // A training finished elsewhere (on the iPhone) takes its «Завершить тренировку?» and schedule dialogs with it —
  // left set, they would pop up again at the next training.
  useEffect(() => window.wp.onState((state) => ui.set(state.session ? { app: state } : { app: state, confirmFinish: false, editingSessionPlan: false })), [])

  useAppearance(app)

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
        <span className="spinner spinner--lg" aria-label={t('Loading')} />
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
