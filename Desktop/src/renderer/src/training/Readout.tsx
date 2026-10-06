import { Fragment, useLayoutEffect, useRef, type ReactNode } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { TrainingPlan } from '@core/models'
import { SessionPhase } from '@core/trainingSession'
import { call } from '../store'
import { CheckIcon, FalseStartIcon, FinishIcon, NoteIcon, OutsideIcon, StandIcon } from '../ui/icons'
import { Kbd } from '../ui/kit'
import type { LiveSession } from './live'

/// Right panel during a session (the Mac's «Пульт»): under the exit strip, what this exit (or break) is; then the
/// timer — big digits in the phase's colour over a progress line, the focus of the window — and the same two buttons
/// as on the iPhone, with their keys. The numbers of the whole training live in the timeline's header, «Завершить»
/// in the title bar.
export function Readout({ live }: { live: LiveSession }) {
  const neutral = live.isReady || live.isLeaving
  return (
    <div className="readout">
      <div className={`readout__card tint-${live.tint}`}>
        <ExitStrip live={live} />
        <div className="readout__about">
          <div className="readout__title">
            <span>{live.title}</span>
            {live.session.attempt > 1 && !live.isBreak && <span className="readout__attempt">{t('попытка %lld', live.session.attempt)}</span>}
          </div>
          <Info live={live} />
        </div>
        <div className="readout__timer">
          <div className={'readout__digits tabular' + (neutral ? ' readout__digits--neutral' : '')}>{live.timerText}</div>
          <div className="readout__line">
            <div className="readout__line-bar" style={{ width: `${Math.min(100, Math.max(0, (live.isAway || live.isBreak ? live.progress : 0) * 100))}%` }} />
          </div>
          <div className={'readout__caption' + (live.overdue ? ' readout__caption--over' : '')}>{live.timerCaption}</div>
        </div>
      </div>
      <Transport live={live} />
    </div>
  )
}

/// One chip per exit: done ones dimmed, the current one highlighted, breaks as thin gaps (the iPhone's strip).
function ExitStrip({ live }: { live: LiveSession }) {
  const ref = useRef<HTMLDivElement>(null)
  const current = live.currentExitIndex
  const phase = live.phase
  const breakAfter = phase.kind === 'breakTime' ? phase.afterExitIndex : null
  useLayoutEffect(() => {
    const strip = ref.current
    const chip = strip?.querySelector<HTMLElement>('.exit-chip--current')
    if (!strip || !chip) return
    strip.scrollTo({ left: chip.offsetLeft - strip.clientWidth / 2 + chip.offsetWidth / 2, behavior: 'smooth' })
  }, [current])
  const exits = live.plan.exits
  return (
    <div className="exit-strip" ref={ref}>
      {exits.map((exit, index) => {
        const state = current === null || index < current ? 'done' : index === current ? 'current' : 'upcoming'
        const pause = TrainingPlan.breakAfter(live.plan, index)
        return (
          <Fragment key={exit.id}>
            <span className={`exit-chip exit-chip--${state} tabular`}>
              {DurationText.compact(exit.duration)}
              {exit.untilStanding && <StandIcon />}
            </span>
            {index < exits.length - 1 && (
              <span className={'exit-strip__gap' + (breakAfter === index ? ' exit-strip__gap--active' : '')} style={{ width: Math.max(6, Math.min(28, pause / 20)) }} />
            )}
          </Fragment>
        )
      })}
    </div>
  )
}

/// Only what matters now. Outside: the plan of this exit and its "или до вставания" rule. In a break: the next exit.
function Info({ live }: { live: LiveSession }) {
  const exit = live.currentExit
  if (live.isBreak) return <div className="readout__info">{live.subtitle}</div>
  if (!exit || live.isFinished) return null
  return (
    <div className="readout__info">
      <span>{t('План %@', live.exitDescription)}</span>
      {exit.untilStanding && (
        <span className="readout__rule">
          <StandIcon />
          {TrainingPlan.standingRule(live.plan)}
        </span>
      )}
      {exit.note && (
        <span className="readout__note">
          <NoteIcon />
          {exit.note}
        </span>
      )}
    </div>
  )
}

/// Always the same two buttons: the next step (Space) and the false start (Backspace, ⌫ on the button).
function Transport({ live }: { live: LiveSession }) {
  const phase = live.phase
  return (
    <div className="transport">
      {phase.kind === 'away' ? (
        <Step icon={<CheckIcon />} title={t('Вернулись')} keys="Пробел" tone="rest" onClick={() => void call('session.command', 'endExit')} />
      ) : SessionPhase.canGoOutside(phase) ? (
        <Step icon={<OutsideIcon />} title={t('Вышли')} keys="Пробел" tone="primary" onClick={() => void call('session.command', 'markBehindDoor')} />
      ) : phase.kind === 'breakTime' ? (
        <Step icon={<FinishIcon />} title={t('Завершить')} keys="Пробел" tone="primary" onClick={() => void call('session.command', 'finish')} />
      ) : null}
      {SessionPhase.canFalseStart(phase) && (
        <Step icon={<FalseStartIcon />} title={t('Фальстарт')} keys="⌫" hint="Backspace" tone="warn" onClick={() => void call('session.command', 'resetExit')} />
      )}
    </div>
  )
}

/// Pink toward an exit, blue toward a break («Вернулись»), the false start quiet.
function Step({ icon, title, keys, hint, tone, onClick }: { icon: ReactNode; title: string; keys: string; hint?: string; tone: 'primary' | 'rest' | 'warn'; onClick: () => void }) {
  return (
    <button className={`step step--${tone}`} onClick={onClick} title={`${title} (${t(hint ?? keys)})`}>
      <span className="step__label">
        {icon}
        <span className="ellipsis">{title}</span>
      </span>
      <Kbd keys={keys} />
    </button>
  )
}
