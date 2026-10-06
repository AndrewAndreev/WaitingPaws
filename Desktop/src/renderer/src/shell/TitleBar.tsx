import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import logo from '../assets/logo.svg'
import { call, ui, useNow, useStore } from '../store'
import { cameraName, cameraOnline, formatTime, isConfigured, isRecording } from '../model'
import { FinishIcon, PhoneIcon, RecordIcon, SoundOffIcon, SoundOnIcon } from '../ui/icons'
import { Tooltip } from '../ui/kit'
import { CameraMenu } from '../training/CameraMenu'
import { finishTitle } from '../actions'

/// The window's title bar: identity on the left, the camera's status and the training's global commands on the
/// right, then the system caption buttons (drawn by Windows: Snap Layouts keep working).
export function TitleBar() {
  const app = useStore((store) => store.app)!
  const route = useStore((store) => store.route)
  const setUp = isConfigured(app.settings) || app.settings.withoutCamera
  const { title, subtitle } = titles(app, route)
  return (
    <header className="titlebar">
      <div className="titlebar__brand">
        <img className="titlebar__logo" src={logo} alt="" draggable={false} />
      </div>
      <div className="titlebar__title">
        <strong>{title}</strong>
        {subtitle && <span>{subtitle}</span>}
      </div>
      {setUp && route === 'training' && <TrainingCommands />}
    </header>
  )
}

function titles(app: NonNullable<ReturnType<typeof useStore.getState>['app']>, route: string): { title: string; subtitle: string } {
  if (route === 'history') return { title: t('История'), subtitle: 'Waiting Paws' }
  if (route === 'settings') return { title: t('Настройки'), subtitle: 'Waiting Paws' }
  if (!isConfigured(app.settings) && !app.settings.withoutCamera) return { title: 'Waiting Paws', subtitle: '' }
  const session = app.session
  if (session) {
    const trainers = session.plan.trainers ? `${session.plan.trainers} · ` : ''
    return { title: session.plan.title, subtitle: trainers + t('с %@', formatTime(session.startedAt)) }
  }
  if (app.pendingPlan) {
    const trainers = app.pendingPlan.trainers ? `${app.pendingPlan.trainers} · ` : ''
    return { title: app.pendingPlan.title, subtitle: trainers + t('перед стартом') }
  }
  const recordingClip = isRecording(app) && !app.session
  return {
    title: cameraName(app) || 'Waiting Paws',
    subtitle: recordingClip ? t('запись без тренировки') : t('новая тренировка'),
  }
}

function TrainingCommands() {
  const app = useStore((store) => store.app)!
  const configured = isConfigured(app.settings)
  const audio = app.settings.audioEnabled
  return (
    <div className="titlebar__commands">
      {configured && <CameraMenu />}
      {configured && <RecordButton />}
      {configured && (
        <Tooltip content={audio ? t('Выключить звук камеры в приложении (запись всегда со звуком)') : t('Включить звук камеры в приложении (запись всегда со звуком)')}>
          <button className="tb-btn" onClick={() => void call('settings.update', { audioEnabled: !audio })} aria-pressed={audio}>
            {audio ? <SoundOnIcon /> : <SoundOffIcon />}
            {t('Звук')}
          </button>
        </Tooltip>
      )}
      {app.sync.connectedDevices.length > 0 && (
        <Tooltip content={t('iPhone видит камеру и ведёт эту тренировку')}>
          <button className="tb-btn tb-btn--link" onClick={() => ui.set({ route: 'settings', settingsPane: 'iphone' })}>
            <PhoneIcon />
            <span className="ellipsis">{app.sync.connectedDevices.join(', ')}</span>
          </button>
        </Tooltip>
      )}
      {!cameraOnline(app) && configured && <span className="badge badge--warning">{t('go2rtc не запущен')}</span>}
      {app.session && (
        <Tooltip content={t('Завершить тренировку') + ' (Ctrl+E)'}>
          <button className="tb-btn" onClick={() => ui.set({ confirmFinish: true })}>
            <FinishIcon />
            {finishTitle(app)}
          </button>
        </Tooltip>
      )}
    </div>
  )
}

/// REC with the running time, or «Запись» to start one (Ctrl+R).
function RecordButton() {
  const app = useStore((store) => store.app)!
  const now = useNow(1000)
  const recording = isRecording(app)
  if (recording) {
    const since = app.recording.since
    return (
      <Tooltip content={t('Остановить запись') + ' (Ctrl+R)'}>
        <button className="tb-btn tb-btn--rec" onClick={() => void call('recording.toggle')}>
          <span className="dot dot--rec" />
          REC {since ? DurationText.clock((now - since) / 1000) : '…'}
        </button>
      </Tooltip>
    )
  }
  return (
    <Tooltip content={t('Записать видео') + ' (Ctrl+R)'}>
      <button className="tb-btn" onClick={() => void call('recording.toggle')}>
        <RecordIcon />
        {t('Запись')}
      </button>
    </Tooltip>
  )
}
