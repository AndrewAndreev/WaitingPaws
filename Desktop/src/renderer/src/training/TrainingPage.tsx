import { useState } from 'react'
import { t } from '@shared/i18n'
import { effectivePlayerMode } from '@shared/settings'
import { call, useApp, useNow, useStore, type CameraSlot } from '../store'
import { hasSecondCamera, isConfigured, isRecordingClip, visibleCamera } from '../model'
import { CameraPlaceholder, CameraView } from '../player/CameraView'
import type { PlayerPhase } from '../player/CameraPlayer'
import { Button } from '../ui/kit'
import { CameraAddIcon } from '../ui/icons'
import { ui } from '../store'
import { Readout } from './Readout'
import { NewTrainingPanel } from './NewTrainingPanel'
import { SessionTimeline, EmptyTimeline } from './SessionTimeline'
import { PlanTimelineEditor } from './PlanTimelineEditor'
import { ClipRecordingHUD } from './ClipRecordingHUD'
import { DiagnosticsBar } from './DiagnosticsBar'
import { LiveSession } from './live'

/// The training page («Пульт»): camera and the readout on top, the timeline below. Before the start the right panel
/// offers paste / repeat / record-only and the timeline shows the pasted plan (editable with the mouse); during the
/// session it is the plan-and-actual timeline. Recording without a training: the picture takes the whole page.
export function TrainingPage() {
  const app = useApp()
  const clipMode = isRecordingClip(app)
  return (
    <div className={'console' + (clipMode ? ' console--clip' : '')}>
      <div className="console__camera">
        <CameraArea />
        {clipMode && <ClipRecordingHUD />}
      </div>
      {!clipMode && <aside className="console__panel">{app.session ? <LiveReadout /> : <NewTrainingPanel />}</aside>}
      {!clipMode && (
        <section className="console__timeline">
          {app.session ? <LiveTimeline /> : app.pendingPlan ? <PlanTimelineEditor /> : <EmptyTimeline />}
        </section>
      )}
    </div>
  )
}

function LiveReadout() {
  const app = useApp()
  const now = useNow(250)
  if (!app.session) return null
  return <Readout live={new LiveSession(app.session, now, app.recording.since)} />
}

function LiveTimeline() {
  const app = useApp()
  const now = useNow(1000)
  if (!app.session) return null
  return <SessionTimeline live={new LiveSession(app.session, now, app.recording.since)} />
}

/// The main camera and, when there is one, the second: both players stay connected, the switcher in the title bar
/// only changes which one is seen (the other is transparent, muted and lets the mouse through).
function CameraArea() {
  const app = useApp()
  const showPerformance = useStore((store) => store.app?.settings.showPerformance)
  const chosen = useStore((store) => store.camera)
  const secondReload = useStore((store) => store.secondCameraReload)
  const [delay, setDelay] = useState<{ buffer: number; network: number | null } | null>(null)
  if (!isConfigured(app.settings) || !app.server) {
    return (
      <CameraPlaceholder text={t('Без камеры: таймер, расписание и лог')}>
        <Button icon={<CameraAddIcon />} onClick={() => ui.set({ showCameraPicker: true })}>
          {t('Подключить камеру…')}
        </Button>
      </CameraPlaceholder>
    )
  }
  if (app.settings.connectionMode === 'embedded' && app.go2rtc.status !== 'running') {
    const failed = app.go2rtc.status === 'failed' || app.go2rtc.status === 'unavailable'
    return (
      <CameraPlaceholder text={failed ? app.go2rtc.message ?? t('go2rtc не запустился') : t('Запускаем go2rtc…')}>
        {failed && <Button onClick={() => void call('go2rtc.restart')}>{t('Перезапустить')}</Button>}
      </CameraPlaceholder>
    )
  }
  const shown = visibleCamera(app.settings, chosen)
  const live = (slot: CameraSlot) => (phase: PlayerPhase) => {
    const playing = phase.kind === 'playing' || phase.kind === 'stalled'
    if (ui.get().cameraLive[slot] !== playing) ui.set({ cameraLive: { ...ui.get().cameraLive, [slot]: playing } })
  }
  return (
    <div className="camera-stack">
      <div className={'camera-stack__layer' + (shown === 'main' ? '' : ' is-hidden')} aria-hidden={shown !== 'main'}>
        <CameraView
          baseURL={app.server.baseURL}
          stream={app.settings.streamName}
          mode={effectivePlayerMode(app.settings)}
          muted={!app.settings.audioEnabled || shown !== 'main'}
          reloadToken={app.camera.playerGeneration}
          zoomable
          onVideoSize={(width, height) => void call('camera.reportVideoSize', width, height)}
          onDelay={(buffer, network) => setDelay({ buffer, network })}
          onPhase={live('main')}
        >
          {showPerformance && <DiagnosticsBar delay={delay} />}
        </CameraView>
      </div>
      {hasSecondCamera(app.settings) && (
        <div className={'camera-stack__layer' + (shown === 'second' ? '' : ' is-hidden')} aria-hidden={shown !== 'second'}>
          <CameraView
            baseURL={app.server.baseURL}
            stream={app.settings.secondStreamName}
            mode={effectivePlayerMode(app.settings)}
            muted={!app.settings.audioEnabled || shown !== 'second'}
            reloadToken={secondReload}
            zoomable
            onPhase={live('second')}
          />
        </div>
      )}
    </div>
  )
}
