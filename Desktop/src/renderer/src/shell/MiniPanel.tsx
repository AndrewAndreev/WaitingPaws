import { useEffect, useState } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { call, ui, useNow, useStore } from '../store'
import { isRecording } from '../model'
import { falseStart, primaryStep, primaryStepTitle } from '../actions'
import { LiveSession } from '../training/live'
import { useAppearance } from './appearance'
import { FalseStartIcon, PawFilledIcon, RecordIcon, RestoreIcon, StopFilledIcon } from '../ui/icons'

/// While the main window is minimized during a training or a recording, a compact always-on-top strip with the timer
/// and the next step floats at the bottom of the screen (the Mac app's minimized panel, Windows Clock's compact
/// overlay). It lives in its own small window (`index.html#mini`), driven by the same state.
export function MiniPanel() {
  const app = useStore((store) => store.app)
  const now = useNow(500)
  // «Остановить» asks right in the strip: «Продолжить» takes its place and «Остановить» moves to its right, so a
  // double click lands on the safe one. The question goes away by itself after a few seconds.
  const [askingStop, setAskingStop] = useState(false)
  useEffect(() => {
    if (!askingStop) return
    const timer = setTimeout(() => setAskingStop(false), 5000)
    return () => clearTimeout(timer)
  }, [askingStop])
  useEffect(() => window.wp.onState((state) => ui.set({ app: state })), [])
  useAppearance(app ?? null)
  useEffect(() => {
    document.documentElement.classList.add('mini')
  }, [])
  if (!app) return null
  const session = app.session
  const live = session ? new LiveSession(session, now, app.recording.since) : null
  const recording = isRecording(app)
  return (
    <div className="mini" style={{ WebkitAppRegion: 'drag' } as React.CSSProperties}>
      <span className="mini__paw">
        <PawFilledIcon />
      </span>
      {recording && (
        <span className="mini__rec tabular">
          <span className="dot dot--rec" />
          REC {app.recording.since ? DurationText.clock((now - app.recording.since) / 1000) : '…'}
        </span>
      )}
      {live && session ? (
        <>
          <span className="mini__sep" />
          <span className={`mini__ring tint-${live.tint}`} style={{ ['--progress' as string]: `${Math.round(live.progress * 100)}%` }}>
            {live.currentExit?.number ?? '✓'}
          </span>
          <div className="mini__text">
            <strong className="ellipsis">{`${live.title} · ${live.phaseName}`}</strong>
            <span className="ellipsis">{live.subtitle}</span>
          </div>
          <span className={`mini__timer tabular tint-${live.tint}`}>{live.timerText}</span>
          <span className="mini__sep" />
          {!live.isFinished && (
            <button className={'mini__btn mini__btn--primary' + (live.isAway ? ' mini__btn--rest' : '')} onClick={() => void primaryStep()}>
              {primaryStepTitle(session)}
            </button>
          )}
          {live.canFalseStart && (
            <button className="mini__btn" onClick={() => falseStart()} title={t('Фальстарт')}>
              <FalseStartIcon />
            </button>
          )}
        </>
      ) : (
        <>
          <span className="mini__text">
            <strong>{askingStop ? t('Остановить запись?') : t('Запись без тренировки')}</strong>
          </span>
          {askingStop ? (
            <>
              <button className="mini__btn" onClick={() => setAskingStop(false)}>
                <RecordIcon />
                {t('Продолжить')}
              </button>
              <button
                className="mini__btn mini__btn--stop"
                onClick={() => {
                  setAskingStop(false)
                  void call('recording.stop')
                }}
              >
                <StopFilledIcon />
                {t('Остановить')}
              </button>
            </>
          ) : (
            <button className="mini__btn mini__btn--stop" onClick={() => setAskingStop(true)}>
              <StopFilledIcon />
              {t('Остановить')}
            </button>
          )}
        </>
      )}
      <button className="mini__btn mini__btn--round" onClick={() => void call('window.restore')} title={t('Развернуть окно тренировки')}>
        <RestoreIcon />
      </button>
    </div>
  )
}
