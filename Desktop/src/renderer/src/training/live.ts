import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { PlannedExit, TrainingPlan } from '@core/models'
import { TrainingSession, type SessionPhase, type TrainingSessionSnapshot } from '@core/trainingSession'
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

  /// An exit past its plan is a warning; a break past its plan is time lost, in red.
  get tint(): Tint {
    if (this.overdue) return this.isBreak ? 'break-over' : 'over'
    if (this.isBreak) return 'break'
    if (this.isFinished) return 'done'
    return 'outside'
  }

  /// Big readout: countdown (counting up past the plan with a "+"), or elapsed time on the way to the door.
  get timerText(): string {
    switch (this.phase.kind) {
      case 'ready':
        return DurationText.clock(this.currentExit?.duration ?? 0)
      case 'leaving':
        return DurationText.clock(this.elapsed)
      case 'away':
      case 'breakTime': {
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
        return t('план')
      case 'leaving':
        return t('к двери')
      case 'away':
      case 'breakTime':
        return this.overdue ? t('сверх плана') : t('осталось')
      case 'finished':
        return t('всего')
    }
  }

  get title(): string {
    const phase = this.phase
    switch (phase.kind) {
      case 'ready':
      case 'leaving':
      case 'away':
        return t('Выход %lld', this.currentExit?.number ?? 0)
      case 'breakTime':
        return phase.nextExitIndex === null ? t('Последний перерыв') : t('Перерыв')
      case 'finished':
        return t('Тренировка завершена')
    }
  }

  /// "за дверью", "сверх плана"…: what the timer is doing, next to the title.
  get phaseName(): string {
    if (this.overdue) return t('сверх плана')
    switch (this.phase.kind) {
      case 'ready':
        return t('перед выходом')
      case 'leaving':
        return t('к двери')
      case 'away':
        return t('за дверью')
      case 'breakTime':
        return t('осталось')
      case 'finished':
        return t('готово')
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
        const parts = [t('План %@', this.exitDescription)]
        if (attempt > 1) parts.push(t('попытка %lld', attempt))
        return parts.join(' · ')
      }
      case 'breakTime':
        if (phase.nextExitIndex !== null) {
          const next = this.plan.exits[phase.nextExitIndex]
          const description = PlannedExit.durationDescription(next)
          return attempt > 1
            ? t('Следующий выход %lld — %@ · попытка %lld', next.number, description, attempt)
            : t('Следующий выход %lld — %@', next.number, description)
        }
        return t('Выходы закончились: после перерыва тренировка завершится')
      case 'finished':
        return t('выходов %lld из %lld · фальстартов %lld', this.completedExits, this.plan.exits.length, this.falseStarts)
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

export function eventTitle(kind: SessionEventKind): string {
  return SessionEventKind.title(kind)
}
