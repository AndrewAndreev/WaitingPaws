import { Fragment, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { EarlyEntry, PlannedExit, TrainingPlan, type PlanRule } from '@core/models'
import { SessionPhase } from '@core/trainingSession'
import { call } from '../store'
import { ChevronDownIcon, DoNotEnterIcon, EarlyEntryIcon, ExitNoteIcon, FalseStartIcon, FinishIcon, StandIcon, TriggerIcon } from '../ui/icons'
import { Kbd } from '../ui/kit'
import type { LiveSession } from './live'
import { TrainerText } from './TrainerText'

/// Right panel during a session (the Mac's «Пульт»): under the exit strip, what this exit (or break) is; then the
/// timer — big digits in the phase's colour over a progress line, the focus of the window — and the same two buttons
/// as on the iPhone, with their keys. Under the buttons, what goes with the exit: outside, when to come back early
/// and its note; in a break, what to prepare for the next one. Then the trainer's text with that exit marked. The
/// numbers of the whole training live in the timeline's header, «Завершить» in the title bar.
export function Readout({ live }: { live: LiveSession }) {
  const neutral = live.isReady || live.isLeaving
  const brief = exitBrief(live)
  return (
    <div className="readout">
      <div className={`readout__card tint-${live.tint}`}>
        <ExitStrip live={live} />
        <div className="readout__about">
          <div className="readout__title">
            <span>{live.title}</span>
            {live.session.attempt > 1 && !live.isBreak && <span className="readout__attempt">{t('попытка %lld', live.session.attempt)}</span>}
            {brief && <ExitCluster plan={live.plan} exit={brief.exit} />}
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
      {brief?.mode === 'outside' && <OutsideBrief key={brief.exit.id} plan={live.plan} exit={brief.exit} />}
      {brief?.mode === 'prepare' && <PrepareBrief plan={live.plan} exit={brief.exit} />}
      <TrainerText plan={live.plan} exitIndex={brief?.index ?? (live.isFinished ? live.plan.exits.length : null)} />
    </div>
  )
}

/// The exit the panel is about: the current one outside, the next one in a break (and the first before it starts).
function exitBrief(live: LiveSession): { exit: PlannedExit; index: number; mode: 'outside' | 'prepare' } | null {
  const phase = live.phase
  switch (phase.kind) {
    case 'leaving':
    case 'away':
      return live.plan.exits[phase.exitIndex] ? { exit: live.plan.exits[phase.exitIndex], index: phase.exitIndex, mode: 'outside' } : null
    case 'ready':
      return live.plan.exits[phase.exitIndex] ? { exit: live.plan.exits[phase.exitIndex], index: phase.exitIndex, mode: 'prepare' } : null
    case 'breakTime':
      return phase.nextExitIndex !== null && live.plan.exits[phase.nextExitIndex]
        ? { exit: live.plan.exits[phase.nextExitIndex], index: phase.nextExitIndex, mode: 'prepare' }
        : null
    case 'finished':
      return null
  }
}

/// ⚡2 🏃2 📝 next to «Выход 8»: what goes with the exit, at a glance. An exit with none of it shows nothing.
function ExitCluster({ plan, exit }: { plan: TrainingPlan; exit: PlannedExit }) {
  const triggers = exit.triggers.length
  const entries = TrainingPlan.earlyEntries(plan, exit).length
  const note = PlannedExit.noteText(exit) !== null
  if (!triggers && !entries && !note) return null
  return (
    <span className="readout__cluster" aria-label={t('Триггеров: %lld, условий раннего входа: %lld', triggers, entries)}>
      <span className={'cluster-badge' + (triggers ? '' : ' is-empty')}>
        <TriggerIcon />
        {triggers > 0 && triggers}
      </span>
      <span className={'cluster-badge' + (entries ? '' : ' is-empty')}>
        <EarlyEntryIcon />
        {entries > 0 && entries}
      </span>
      <span className={'cluster-badge' + (note ? '' : ' is-empty')}>
        <ExitNoteIcon />
      </span>
    </span>
  )
}

/// Outside: «Ранний вход» — a plate per condition (the trainer's colour, what the dog does, «через 2:00» large), the
/// «не входить» rule in red, then the exit's note folded to one line.
function OutsideBrief({ plan, exit }: { plan: TrainingPlan; exit: PlannedExit }) {
  const entries = TrainingPlan.earlyEntries(plan, exit)
  const stop = TrainingPlan.doNotEnterRule(plan)
  const note = PlannedExit.noteText(exit)
  return (
    <>
      {entries.length > 0 && (
        <section className="brief">
          <h4 className="brief__title">
            <EarlyEntryIcon />
            {t('Ранний вход')}
          </h4>
          {entries.map((entry) => (
            <EntryPlate key={entry.id} entry={entry} />
          ))}
          {stop && <StopPlate rule={stop} />}
        </section>
      )}
      {note && <NotePlate note={note} />}
    </>
  )
}

function EntryPlate({ entry }: { entry: EarlyEntry }) {
  const soon = entry.delay !== null && entry.delay > 0
  const standing = entry.id === EarlyEntry.untilStanding().id
  return (
    <div className="plate">
      {standing ? <StandIcon className="plate__lead" /> : <span className={`tone-dot tone-dot--${entry.tone}`} />}
      <span className="plate__what">
        <span className="plate__event ellipsis">{entry.event}</span>
        {entry.detail && (
          <span className="plate__detail ellipsis" title={entry.detail}>
            {entry.detail}
          </span>
        )}
      </span>
      {soon ? (
        <span className="plate__then tabular">
          <small>{t('через')}</small>
          {DurationText.clock(entry.delay ?? 0)}
        </span>
      ) : (
        <span className="plate__then plate__then--now">{t('сразу')}</span>
      )}
    </div>
  )
}

function StopPlate({ rule }: { rule: PlanRule }) {
  return (
    <div className="plate plate--stop">
      <DoNotEnterIcon className="plate__lead" />
      <span className="plate__what">
        <span className="plate__event ellipsis">{rule.title}</span>
        {rule.detail && (
          <span className="plate__detail ellipsis" title={rule.detail}>
            {rule.detail}
          </span>
        )}
      </span>
      <span className="plate__then plate__then--stop">{t('не входить')}</span>
    </div>
  )
}

/// «Заметка к выходу», one line until clicked.
function NotePlate({ note }: { note: string }) {
  const [open, setOpen] = useState(false)
  return (
    <button type="button" className={'brief brief--note' + (open ? ' is-open' : '')} aria-expanded={open} onClick={() => setOpen(!open)}>
      <span className="brief__title">
        <ExitNoteIcon />
        {t('Заметка к выходу')}
        <span className="spacer" />
        <ChevronDownIcon className="brief__chevron" />
      </span>
      <span className={'brief__note' + (open ? '' : ' ellipsis')}>{note}</span>
    </button>
  )
}

/// In a break (and before the first exit): «Подготовить к выходу 7» — the next exit's triggers, then its conditions in
/// one dimmed line.
function PrepareBrief({ plan, exit }: { plan: TrainingPlan; exit: PlannedExit }) {
  const entries = TrainingPlan.earlyEntries(plan, exit)
  if (!exit.triggers.length && !entries.length) return null
  return (
    <section className="brief">
      <h4 className="brief__title">
        <TriggerIcon />
        {t('Подготовить к выходу %lld', exit.number)}
      </h4>
      {exit.triggers.map((trigger, index) => (
        <div key={index} className="plate plate--trigger">
          <TriggerIcon className="plate__lead" />
          <span className="plate__event">{capitalized(trigger)}</span>
        </div>
      ))}
      {entries.length > 0 && (
        <div className="brief__then">
          <EarlyEntryIcon />
          <span className="ellipsis">{t('На выходе: %@', entries.map(EarlyEntry.summary).join(' · '))}</span>
        </div>
      )}
    </section>
  )
}

function capitalized(text: string): string {
  const [first = '', ...rest] = Array.from(text)
  return first.toUpperCase() + rest.join('')
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

/// Only what matters now. Outside: the plan of this exit (its conditions and note are under the buttons). In a break:
/// the next exit.
function Info({ live }: { live: LiveSession }) {
  const exit = live.currentExit
  if (live.isBreak) return <div className="readout__info">{live.subtitle}</div>
  if (!exit || live.isFinished) return null
  return (
    <div className="readout__info">
      <span>{t('План %@', live.exitDescription)}</span>
    </div>
  )
}

/// Always the same two buttons: the next step (Space) and the false start (Backspace, ⌫ on the button).
function Transport({ live }: { live: LiveSession }) {
  const phase = live.phase
  return (
    <div className="transport">
      {phase.kind === 'away' ? (
        <Step icon={<DoorStepIcon entering />} title={t('Вернулись')} keys="Пробел" tone="rest" onClick={() => void call('session.command', 'endExit')} />
      ) : SessionPhase.canGoOutside(phase) ? (
        <Step icon={<DoorStepIcon />} title={t('Вышли')} keys="Пробел" tone="primary" onClick={() => void call('session.command', 'markBehindDoor')} />
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

/// «Вышли» / «Вернулись»: a door open on its right side with an arrow out of it or back into it — the same drawing as
/// the Mac's and the iPhone's `DoorArrowShape` (a 24 px grid).
export function DoorStepIcon({ entering = false }: { entering?: boolean }) {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M14 9V5.5Q14 3 11.5 3H6.5Q4 3 4 5.5V18.5Q4 21 6.5 21H11.5Q14 21 14 18.5V15" />
      <path d={entering ? 'M21 12H9M13 8L9 12L13 16' : 'M9 12H21M17 8L21 12L17 16'} />
    </svg>
  )
}
