import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { PlannedExit, TrainingPlan } from '@core/models'
import { SessionPhase, TrainingSession, type TrainingSessionSnapshot } from '@core/trainingSession'
import { SessionEventKind, type ExitResult } from '@core/sessionLog'

/// Everything the training page shows, derived from a session snapshot at a moment (the Mac app's
/// `LiveSessionModel`). Recomputed twice a second.
export type Tint = 'outside' | 'break' | 'over' | 'break-over' | 'done' | 'neutral'

export class LiveSession {
  constructor(
    readonly session: TrainingSessionSnapshot,
    readonly now: number,
    readonly recordingSince: number | null,
  ) {}

  get plan(): TrainingPlan {
    return this.session.plan
  }
  get phase(): SessionPhase {
    return this.session.phase
  }
  get isBreak(): boolean {
    return this.phase.kind === 'breakTime'
  }
  get isAway(): boolean {
    return this.phase.kind === 'away'
  }
  get isLeaving(): boolean {
    return this.phase.kind === 'leaving'
  }
  get isReady(): boolean {
    return this.phase.kind === 'ready'
  }
  get isFinished(): boolean {
    return this.phase.kind === 'finished'
  }
  get currentExit(): PlannedExit | null {
    return TrainingSession.currentExit(this.session)
  }
  get currentExitIndex(): number | null {
    return TrainingSession.currentExitIndex(this.session)
  }
  get remaining(): number | null {
    return TrainingSession.remaining(this.session, this.now)
  }
  get elapsed(): number {
    return TrainingSession.elapsed(this.session, this.now)
  }
  get overdue(): boolean {
    return (this.remaining ?? 0) < 0
  }
  get progress(): number {
    return TrainingSession.progress(this.session, this.now) ?? 0
  }
  get completedExits(): number {
    return TrainingSession.completedExitsCount(this.session)
  }
  get falseStarts(): number {
    return TrainingSession.falseStartsCount(this.session)
  }

  /// Outside on an extra exit («Ещё выход»): no plan, the timer counts up.
  get isOpenExit(): boolean {
    return isOpenExit(this.session)
  }

  /// Outside, with a false-start window in the schedule: seconds of it still left (0 once it has passed). Null in a
  /// break, before the door, or with no window (the button stays the whole exit).
  get falseStartLeft(): number | null {
    return falseStartLeft(this.session, this.now)
  }

  /// The schedule's false-start window, seconds.
  get falseStartWindow(): number | null {
    return TrainingPlan.falseStartWindow(this.plan)
  }

  /// «Фальстарт» means something now (and is on screen): not outside past the schedule's window.
  get canFalseStart(): boolean {
    return canFalseStartNow(this.session, this.now)
  }

  /// An exit past its plan is a warning; a break past its plan is time lost, in red.
  get tint(): Tint {
    if (this.overdue) return this.isBreak ? 'break-over' : 'over'
    if (this.isBreak) return 'break'
    if (this.isFinished) return 'done'
    return 'outside'
  }

  /// Big readout: countdown (counting up past the plan with a "+"), or elapsed time on the way to the door and on an
  /// extra exit.
  get timerText(): string {
    switch (this.phase.kind) {
      case 'ready':
        return DurationText.clock(this.currentExit?.duration ?? 0)
      case 'leaving':
        return DurationText.clock(this.elapsed)
      case 'away':
      case 'breakTime': {
        if (this.isOpenExit) return DurationText.clock(this.elapsed)
        const r = this.remaining ?? 0
        return r < 0 ? '+' + DurationText.clock(-r) : DurationText.clock(r)
      }
      case 'finished':
        return DurationText.clock(this.elapsed)
    }
  }

  get timerCaption(): string {
    switch (this.phase.kind) {
      case 'ready':
        return t('plan')
      case 'leaving':
        return t('to the door')
      case 'away':
      case 'breakTime':
        if (this.isOpenExit) return t('elapsed')
        return this.overdue ? t('over plan') : t('left')
      case 'finished':
        return t('total')
    }
  }

  get title(): string {
    const phase = this.phase
    switch (phase.kind) {
      case 'ready':
      case 'leaving':
      case 'away':
        return t('Exit %lld', this.currentExit?.number ?? 0)
      case 'breakTime':
        return phase.nextExitIndex === null ? t('Last Break') : t('Break')
      case 'finished':
        return t('Training Complete')
    }
  }

  /// "за дверью", "сверх плана"…: what the timer is doing, next to the title.
  get phaseName(): string {
    if (this.overdue) return t('over plan')
    switch (this.phase.kind) {
      case 'ready':
        return t('before the exit')
      case 'leaving':
        return t('to the door')
      case 'away':
        return t('outside')
      case 'breakTime':
        return t('left')
      case 'finished':
        return t('done')
    }
  }

  /// "30 с или до вставания" of the current exit.
  get exitDescription(): string {
    return this.currentExit ? PlannedExit.durationDescription(this.currentExit) : ''
  }

  /// Outside: the plan of this exit. In a break: the next exit — the same lines as the Mac and the iPhone.
  get subtitle(): string {
    const phase = this.phase
    const attempt = this.session.attempt
    switch (phase.kind) {
      case 'ready':
      case 'leaving':
      case 'away': {
        const exit = this.currentExit
        const parts = [exit?.isOpen ? t('An exit with no set time — come back when you need to') : t('Plan %@', this.exitDescription)]
        if (attempt > 1) parts.push(t('attempt %lld', attempt))
        return parts.join(' · ')
      }
      case 'breakTime':
        if (phase.nextExitIndex !== null) {
          const next = this.plan.exits[phase.nextExitIndex]
          const description = PlannedExit.durationDescription(next)
          return attempt > 1
            ? t('Next: exit %lld — %@ · attempt %lld', next.number, description, attempt)
            : t('Next: exit %lld — %@', next.number, description)
        }
        return t('No exits left: “Another Exit” or “Finish”')
      case 'finished':
        return t('exits: %lld of %lld · false starts: %lld', this.completedExits, this.plan.exits.length, this.falseStarts)
    }
  }

  /// Rough finish time: what is left of the plan from now.
  get eta(): number {
    const index = this.currentExitIndex
    if (index === null) return this.now
    let left = Math.max(0, this.remaining ?? 0)
    for (let i = index; i < this.plan.exits.length; i++) {
      if (i > index || this.isBreak || this.isReady) left += this.plan.exits[i].duration
      if (i < this.plan.exits.length - 1) left += TrainingPlan.breakAfter(this.plan, i)
    }
    return this.now + left * 1000
  }

  /// Where the current exit's walk started (leaving or away).
  get currentStart(): number | null {
    const phase = this.phase
    return phase.kind === 'leaving' || phase.kind === 'away' ? phase.since : null
  }

  /// When the first exit started: the plan's start on the timeline. Before it, now — the plan slides along until the
  /// first «Вышли» (the wait before the first exit says nothing).
  get planStart(): number {
    const first = this.session.results[0]
    if (first) return first.leftAt ?? first.startedAt
    const phase = this.phase
    if (phase.kind === 'leaving') return phase.since
    if (phase.kind === 'away') return phase.leftAt
    return this.now
  }

  /// How far the session is from the plan laid out from the first exit (seconds; + = behind): when the current exit
  /// started, or — in a break — when the next one can start at the earliest.
  get drift(): number | null {
    const index = this.currentExitIndex
    if (index === null) return null
    let planned = 0
    for (let i = 0; i < index; i++) planned += this.plan.exits[i].duration + TrainingPlan.breakAfter(this.plan, i)
    const phase = this.phase
    const actual =
      phase.kind === 'leaving'
        ? phase.since
        : phase.kind === 'away'
          ? phase.leftAt
          : phase.kind === 'breakTime'
            ? Math.max(this.now, phase.since + phase.duration * 1000)
            : this.now
    return (actual - this.planStart) / 1000 - planned
  }

  results(): readonly ExitResult[] {
    return this.session.results
  }
}

function isOpenExit(session: TrainingSessionSnapshot): boolean {
  const phase = session.phase
  return phase.kind === 'away' && !!session.plan.exits[phase.exitIndex]?.isOpen
}

/// See `LiveSession.falseStartLeft`.
export function falseStartLeft(session: TrainingSessionSnapshot, now: number): number | null {
  if (session.phase.kind !== 'away') return null
  const window = TrainingPlan.falseStartWindow(session.plan)
  return window === null ? null : Math.max(0, window - TrainingSession.elapsed(session, now))
}

/// Backspace and the button: a false start outside only within the schedule's window («в первые 20 секунд»); in a
/// break it is the dog at the door before «Вышли», as always.
export function canFalseStartNow(session: TrainingSessionSnapshot, now: number): boolean {
  return SessionPhase.canFalseStart(session.phase) && falseStartLeft(session, now) !== 0
}

export function eventTitle(kind: SessionEventKind): string {
  return SessionEventKind.title(kind)
}
