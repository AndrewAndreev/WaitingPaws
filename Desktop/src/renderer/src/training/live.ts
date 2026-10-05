import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { PlannedExit, TrainingPlan } from '@core/models'
import { TrainingSession, type SessionPhase, type TrainingSessionSnapshot } from '@core/trainingSession'
import { SessionEventKind, type ExitResult } from '@core/sessionLog'

/// Everything the training page shows, derived from a session snapshot at a moment (the Mac app's
/// `LiveSessionModel`). Recomputed twice a second.
export type Tint = 'outside' | 'break' | 'over' | 'done' | 'neutral'

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

  get tint(): Tint {
    if (this.overdue) return 'over'
    if (this.isBreak) return 'break'
    if (this.isFinished) return 'done'
    return 'outside'
  }

  /// Big readout: countdown, or elapsed time on the way to the door.
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
    const phase = this.phase
    switch (phase.kind) {
      case 'ready':
        return t('план')
      case 'leaving':
        return t('к двери')
      case 'away':
        return this.overdue ? t('сверх плана') : t('до конца выхода')
      case 'breakTime':
        return phase.nextExitIndex !== null ? t('до выхода %lld', this.plan.exits[phase.nextExitIndex].number) : t('до конца')
      case 'finished':
        return t('всего')
    }
  }

  /// "За дверью", "Идём к двери"…
  get phaseName(): string {
    switch (this.phase.kind) {
      case 'ready':
        return t('Готовы')
      case 'leaving':
        return t('Идём к двери')
      case 'away':
        return t('За дверью')
      case 'breakTime':
        return t('Перерыв')
      case 'finished':
        return t('Готово')
    }
  }

  get subtitle(): string {
    const phase = this.phase
    switch (phase.kind) {
      case 'ready':
      case 'leaving':
      case 'away': {
        const parts = [this.currentExit ? PlannedExit.durationDescription(this.currentExit) : '']
        if (this.session.attempt > 1) parts.push(t('попытка %lld', this.session.attempt))
        return parts.join(' · ')
      }
      case 'breakTime':
        if (phase.nextExitIndex !== null) {
          const next = this.plan.exits[phase.nextExitIndex]
          return t('%@ · дальше выход %lld — %@', DurationText.short(phase.duration), next.number, PlannedExit.durationDescription(next))
        }
        return DurationText.short(phase.duration)
      case 'finished':
        return t('выходов %lld из %lld · фальстартов %lld', this.completedExits, this.plan.exits.length, this.falseStarts)
    }
  }

  /// The line under the big digits.
  get detail(): string {
    const plan = this.currentExit ? PlannedExit.durationDescription(this.currentExit) : ''
    switch (this.phase.kind) {
      case 'ready':
      case 'breakTime':
        return `${this.timerCaption} · ${this.subtitle}`
      case 'leaving':
        return t('идём к двери · план %@', plan)
      case 'away':
        return t('за дверью %@ · план %@', DurationText.clock(this.elapsed), plan)
      case 'finished':
        return this.subtitle
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

  /// How far the session is behind the ideal schedule (door walks and long breaks add up). Seconds; + = behind.
  get drift(): number | null {
    const index = this.currentExitIndex
    if (index === null) return null
    let planned = 0
    for (let i = 0; i < index; i++) planned += this.plan.exits[i].duration + TrainingPlan.breakAfter(this.plan, i)
    const actual = ((this.currentStart ?? this.now) - this.session.startedAt) / 1000
    return actual - planned
  }

  results(): readonly ExitResult[] {
    return this.session.results
  }
}

export function eventTitle(kind: SessionEventKind): string {
  return SessionEventKind.title(kind)
}
