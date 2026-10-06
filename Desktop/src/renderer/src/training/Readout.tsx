import { Fragment, useLayoutEffect, useRef, type ReactNode } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { TrainingPlan } from '@core/models'
import { SessionPhase } from '@core/trainingSession'
import { call, ui } from '../store'
import { formatTime } from '../model'
import { CheckIcon, EditIcon, FalseStartIcon, FinishIcon, NoteIcon, OutsideIcon, StandIcon } from '../ui/icons'
import { Button, Kbd } from '../ui/kit'
import type { LiveSession } from './live'

/// Right panel during a session — the Mac's and the iPhone's readout: the exit strip, the phase, a big ring timer,
/// what the plan says about this moment and the same two buttons ("Вышли" / "Вернулись" and "Фальстарт"). The
/// numbers of the whole training sit below, with «Завершить».
export function Readout({ live }: { live: LiveSession }) {
  return (
    <div className="readout">
      <div className={`readout__card tint-${live.tint}`}>
        <ExitStrip live={live} />
        <div className="readout__title">
          <span>{live.title}</span>
          {live.session.attempt > 1 && !live.isBreak && <span className="readout__attempt">{t('попытка %lld', live.session.attempt)}</span>}
        </div>
        <TimerRing progress={live.isAway || live.isBreak ? live.progress : null}>
          <span className={'ring__digits tabular' + (live.overdue ? ' ring__digits--over' : '')}>{live.timerText}</span>
          <span className={'ring__caption' + (live.overdue ? ' ring__digits--over' : '')}>{live.timerCaption}</span>
        </TimerRing>
        <Info live={live} />
        <Transport live={live} />
      </div>

      <div className="spacer" />
      <div className="readout__stats">
        <Stat value={t('%lld из %lld', live.completedExits, live.plan.exits.length)} label={t('выходов')} />
        <Stat value={String(live.falseStarts)} label={t('фальстартов')} warn={live.falseStarts > 0} />
        <Stat value={DurationText.clock((live.now - live.session.startedAt) / 1000)} label={t('идёт тренировка')} />
        <Stat value={`≈ ${formatTime(live.eta)}`} label={t('конец по плану')} />
      </div>
      <div className="readout__footer">
        <Button icon={<EditIcon />} onClick={() => ui.set({ editingSessionPlan: true })} title={t('Поправить выходы и перерывы прямо во время тренировки')}>
          {t('Расписание')}
        </Button>
        <Button icon={<FinishIcon />} shortcut="Ctrl+E" onClick={() => ui.set({ confirmFinish: true })}>
          {t('Завершить')}
        </Button>
      </div>
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

function TimerRing({ progress, children }: { progress: number | null; children: ReactNode }) {
  const radius = 46
  const length = 2 * Math.PI * radius
  return (
    <div className="ring">
      <svg viewBox="0 0 100 100" aria-hidden>
        <circle className="ring__track" cx="50" cy="50" r={radius} />
        {progress !== null && (
          <circle className="ring__bar" cx="50" cy="50" r={radius} strokeDasharray={length} strokeDashoffset={length * (1 - Math.min(1, Math.max(0, progress)))} transform="rotate(-90 50 50)" />
        )}
      </svg>
      <div className="ring__center">{children}</div>
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

function Stat({ value, label, warn }: { value: string; label: string; warn?: boolean }) {
  return (
    <div className="stat">
      <div className="stat__value tabular" style={warn ? { color: 'var(--warning)' } : undefined}>
        {value}
      </div>
      <div className="stat__label">{label}</div>
    </div>
  )
}

/// Always the same two buttons: the next step (Space) and the false start (Backspace, ⌫ on the button).
function Transport({ live }: { live: LiveSession }) {
  const phase = live.phase
  return (
    <div className="transport">
      {phase.kind === 'away' ? (
        <Step icon={<CheckIcon />} title={t('Вернулись')} keys="Пробел" tone="done" onClick={() => void call('session.command', 'endExit')} />
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

function Step({ icon, title, keys, hint, tone, onClick }: { icon: ReactNode; title: string; keys: string; hint?: string; tone: 'primary' | 'done' | 'warn'; onClick: () => void }) {
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
