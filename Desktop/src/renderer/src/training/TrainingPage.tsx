import { useState } from 'react'
import { t } from '@shared/i18n'
import { effectivePlayerMode } from '@shared/settings'
import { call, useApp, useNow, useStore } from '../store'
import { isConfigured, isRecordingClip } from '../model'
import { CameraPlaceholder, CameraView } from '../player/CameraView'
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

function CameraArea() {
  const app = useApp()
  const showPerformance = useStore((store) => store.app?.settings.showPerformance)
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
  return (
    <CameraView
      baseURL={app.server.baseURL}
      stream={app.settings.streamName}
      mode={effectivePlayerMode(app.settings)}
      muted={!app.settings.audioEnabled}
      reloadToken={app.camera.playerGeneration}
      zoomable
      onVideoSize={(width, height) => void call('camera.reportVideoSize', width, height)}
      onDelay={(buffer, network) => setDelay({ buffer, network })}
    >
      {showPerformance && <DiagnosticsBar delay={delay} />}
    </CameraView>
  )
}
