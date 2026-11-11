import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { t } from '@shared/i18n'
import { ui, useApp, useStore, type SettingsPane } from '../store'
import { cameraName, isConfigured } from '../model'
import { AppearanceIcon, ConnectionIcon, DiagnosticsIcon, FolderIcon, InfoIcon, PawIcon, PhoneIcon, SearchIcon, VideoIcon, VideoOffIcon } from '../ui/icons'
import { CameraPane } from './CameraPane'
import { ConnectionPane } from './ConnectionPane'
import { TrainingPane } from './TrainingPane'
import { RecordingPane } from './RecordingPane'
import { IPhonePane } from './IPhonePane'
import { AppearancePane } from './AppearancePane'
import { DiagnosticsPane } from './DiagnosticsPane'
import { AboutPane } from './AboutPane'
import { isXiaomiCamera, serverReady } from './cameraText'
import '../styles/settings.css'

interface PaneInfo {
  id: SettingsPane
  title: () => string
  icon: ReactNode
  /// What the search also finds the pane by, in both languages (the title is searched as shown).
  keywords: string[]
  /// Not in the web build (no camera, files or iPhone link there).
  desktopOnly?: boolean
}

const PANES: PaneInfo[] = [
  {
    id: 'camera',
    title: () => t('Camera'),
    icon: <VideoIcon />,
    keywords: ['xiaomi', 'mi home', 'аккаунт', 'качество', 'звук', 'плеер', 'mse', 'hls', 'webrtc', 'поток', '2k', 'hd', 'ночной', 'camera', 'account', 'quality', 'sound', 'audio', 'player', 'stream', 'night'],
  },
  {
    id: 'connection',
    title: () => t('Connection'),
    icon: <ConnectionIcon />,
    keywords: ['go2rtc', 'сервер', 'адрес', 'встроенный', 'сеть', 'логин', 'пароль', 'перезапустить', 'connection', 'server', 'address', 'embedded', 'built-in', 'network', 'login', 'username', 'password', 'restart'],
    desktopOnly: true,
  },
  {
    id: 'training',
    title: () => t('Training'),
    icon: <PawIcon />,
    keywords: ['запись', 'автоматически', 'завершать', 'выход', 'сон', 'спящий', 'экран', 'training', 'recording', 'record', 'automatically', 'finish', 'exit', 'sleep', 'awake', 'screen'],
  },
  {
    id: 'recording',
    title: () => t('Recording & Files'),
    icon: <FolderIcon />,
    keywords: ['папка', 'проводник', 'видео', 'запись', 'место', 'диск', 'удалить', 'история', 'files', 'folder', 'explorer', 'video', 'recording', 'storage', 'space', 'disk', 'delete', 'history'],
  },
  {
    id: 'iphone',
    title: () => 'iPhone',
    icon: <PhoneIcon />,
    keywords: ['телефон', 'устройства', 'забыть', 'связь', 'сеть', 'брандмауэр', 'phone', 'devices', 'forget', 'link', 'network', 'firewall', 'sync'],
    desktopOnly: true,
  },
  {
    id: 'appearance',
    title: () => t('Appearance'),
    icon: <AppearanceIcon />,
    keywords: ['тема', 'тёмная', 'темная', 'светлая', 'язык', 'русский', 'english', 'theme', 'dark', 'light', 'language', 'appearance'],
  },
  {
    id: 'diagnostics',
    title: () => t('Diagnostics'),
    icon: <DiagnosticsIcon />,
    keywords: ['задержка', 'нагрузка', 'журнал', 'логи', 'версия', 'diagnostics', 'delay', 'latency', 'performance', 'log', 'logs', 'version'],
    desktopOnly: true,
  },
  {
    id: 'about',
    title: () => t('About'),
    icon: <InfoIcon />,
    keywords: ['версия', 'политика', 'конфиденциальность', 'лицензии', 'поддержка', 'обновления', 'обновить', 'тестовые', 'version', 'privacy', 'licenses', 'about', 'policy', 'support', 'github', 'updates', 'update', 'nightly'],
  },
]

/// Настройки as a page of the main window, Windows 11 Settings style: the camera and a list of sections on the left,
/// one column of setting cards on the right. Every change applies at once.
export function SettingsPage() {
  const app = useApp()
  const current = useStore((store) => store.settingsPane)
  const [search, setSearch] = useState('')
  const content = useRef<HTMLDivElement>(null)
  const web = app.platform === 'web'

  const available = useMemo(() => PANES.filter((pane) => !(web && pane.desktopOnly)), [web])
  const query = search.trim().toLowerCase()
  const visible = query ? available.filter((pane) => [pane.title(), ...pane.keywords].some((word) => word.toLowerCase().includes(query))) : available
  const pane = available.some((item) => item.id === current) ? current : available[0].id

  const select = (id: SettingsPane) => ui.set({ settingsPane: id })

  // A new pane starts at its top.
  useEffect(() => {
    content.current?.scrollTo({ top: 0 })
  }, [pane])

  return (
    <div className="settings">
      <nav className="settings__nav" aria-label={t('Settings')}>
        <h1 className="h1 settings__title">{t('Settings')}</h1>
        <CameraHeader onClick={() => select('camera')} selected={pane === 'camera'} />
        <div className="settings__search">
          <SearchIcon />
          <input
            className="input"
            type="search"
            value={search}
            placeholder={t('Find a setting')}
            aria-label={t('Find a setting')}
            spellCheck={false}
            onChange={(event) => setSearch(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && visible[0]) select(visible[0].id)
              if (event.key === 'Escape') setSearch('')
            }}
          />
        </div>
        <div className="settings__list" role="list">
          {visible.map((item) => (
            <button key={item.id} role="listitem" className="snav__item" aria-current={item.id === pane ? 'page' : undefined} onClick={() => select(item.id)}>
              {item.icon}
              <span className="ellipsis">{item.title()}</span>
              {/* A new version waits (the app from GitHub): «О приложении» has «Перезапустить». */}
              {item.id === 'about' && app.updates?.pending && <span className="snav__badge">1</span>}
            </button>
          ))}
          {visible.length === 0 && <div className="snav__empty">{t('No Results')}</div>}
        </div>
      </nav>
      <div className="settings__content" ref={content}>
        <div className="spane" key={pane}>
          {pane === 'camera' ? (
            <CameraPane />
          ) : pane === 'connection' ? (
            <ConnectionPane />
          ) : pane === 'training' ? (
            <TrainingPane />
          ) : pane === 'recording' ? (
            <RecordingPane />
          ) : pane === 'iphone' ? (
            <IPhonePane />
          ) : pane === 'appearance' ? (
            <AppearancePane />
          ) : pane === 'diagnostics' ? (
            <DiagnosticsPane />
          ) : (
            <AboutPane />
          )}
        </div>
      </div>
    </div>
  )
}

/// Like the account card on top of Windows Settings: the camera the app is connected to, opens the Camera section.
function CameraHeader({ onClick, selected }: { onClick: () => void; selected: boolean }) {
  const app = useApp()
  const configured = isConfigured(app.settings)
  const ready = serverReady(app)
  const kind = isXiaomiCamera(app, null) ? t('Xiaomi Camera') : t('go2rtc stream')
  const subtitle = !configured
    ? t('Not selected')
    : !ready
      ? app.settings.connectionMode === 'embedded' && app.go2rtc.status === 'starting'
        ? t('%@ · starting go2rtc', kind)
        : t('%@ · go2rtc not running', kind)
      : app.camera.videoSize
        ? t('%@ · online', kind)
        : kind
  // Green once a player has had a picture from it, not merely because go2rtc runs.
  const online = configured && ready && app.camera.videoSize !== null
  return (
    <button className="scamera-header" aria-current={selected ? 'true' : undefined} onClick={onClick}>
      <span className={'scamera-header__avatar' + (configured ? '' : ' scamera-header__avatar--off')}>
        {configured ? <VideoIcon /> : <VideoOffIcon />}
        {configured && <span className={'scamera-header__status' + (online ? ' scamera-header__status--on' : '')} />}
      </span>
      <span className="col" style={{ gap: 0, minWidth: 0 }}>
        <span className="scamera-header__name ellipsis">{configured ? cameraName(app) : t('Camera')}</span>
        <span className="scamera-header__subtitle ellipsis">{subtitle}</span>
      </span>
    </button>
  )
}
