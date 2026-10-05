import type { ReactNode } from 'react'
import { t } from '@shared/i18n'
import { ui, useStore, type Route } from '../store'
import { HistoryFilledIcon, HistoryIcon, SettingsFilledIcon, SettingsIcon, TimerFilledIcon, TimerIcon } from '../ui/icons'
import { Tooltip } from '../ui/kit'

/// Left navigation rail (Teams / Discord / VS Code): the Mac app's separate windows — training, history,
/// settings — are pages of one window here.
export function NavRail() {
  const route = useStore((store) => store.route)
  const recording = useStore((store) => store.app?.recording.since !== null || store.app?.recording.resuming)
  const sessionRunning = useStore((store) => store.app?.session !== null)
  return (
    <nav className="rail" aria-label={t('Навигация')}>
      <RailItem route="training" current={route} label={t('Тренировка')} shortcut="Ctrl+1" icon={<TimerIcon />} activeIcon={<TimerFilledIcon />} badge={route !== 'training' && (recording || sessionRunning)} />
      <RailItem route="history" current={route} label={t('История')} shortcut="Ctrl+H" icon={<HistoryIcon />} activeIcon={<HistoryFilledIcon />} />
      <div className="rail__spacer" />
      <RailItem route="settings" current={route} label={t('Настройки')} shortcut="Ctrl+," icon={<SettingsIcon />} activeIcon={<SettingsFilledIcon />} />
    </nav>
  )
}

function RailItem({ route, current, label, shortcut, icon, activeIcon, badge }: { route: Route; current: Route; label: string; shortcut: string; icon: ReactNode; activeIcon: ReactNode; badge?: boolean }) {
  const active = route === current
  return (
    <Tooltip content={`${label} (${shortcut})`} side="right">
      <button className="rail__item" aria-current={active ? 'page' : undefined} onClick={() => ui.set({ route })}>
        {active ? activeIcon : icon}
        <span>{label}</span>
        {badge && <span className="rail__badge" aria-label={t('Идёт тренировка или запись')} />}
      </button>
    </Tooltip>
  )
}
