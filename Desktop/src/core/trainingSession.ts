// Port of Engine/TrainingSession.swift: the state machine of one training session.
//
// Usage
// -----
// All state lives in one immutable `TrainingSessionSnapshot` (the same data Swift's `Snapshot` carries, so it
// is also what the iPhone ↔ Mac link sends). Every change replaces it with a new object and notifies
// subscribers, which makes the session a ready-made external store for React / zustand:
//
//     const session = new TrainingSession(plan)                  // clock defaults to Date.now
//     const unsubscribe = session.subscribe((snapshot) => store.setState({ session: snapshot }))
//     // or: useSyncExternalStore(session.subscribe, () => session.snapshot)
//     session.markBehindDoor(); session.endExit()                // «Вышли», «Вернулись»
//     setInterval(() => session.tick(), 250)                     // finishes after the last break
//     TrainingSession.remaining(session.snapshot, Date.now())    // countdowns are computed, not stored
//
// Time is injectable: pass `{ clock: () => ms }` to the constructor (tests advance a fake clock), and
// `tick(now)` / `remaining(now)` / `elapsed(now)` / `progress(now)` take epoch milliseconds. Durations are
// seconds, like Swift's `TimeInterval`. The derived values are also static functions over a snapshot, so a
// renderer that only receives snapshots (over IPC) can compute them without a `TrainingSession`.
//
// Snapshots are never mutated: treat them (and the plan, events and results inside) as read-only.

import {
  type DateEncoding,
  type JSONObject,
  DecodingError,
  ObjectReader,
  compact,
  deepEqual,
  encodeDate,
  expectString,
  readEnumCase,
  sameUUID,
} from './codable'
import { DurationText } from './durationText'
import { tr } from './localization'
import { PlannedExit, TrainingPlan } from './models'
import { ExitResult, SessionEvent, type SessionEventKind, TrainingRecord } from './sessionLog'

/** Epoch milliseconds. */
export type Clock = () => number

export type SessionPhase =
  /** Before the first exit: waiting for "Вышли". */
  | { kind: 'ready'; exitIndex: number }
  /**
   * Walking to the door; the dog is still watching. Only the "Начать выход" of an older linked iPhone leads here:
   * the buttons now go from the break straight to `away`.
   */
  | { kind: 'leaving'; exitIndex: number; since: number }
  /** Behind the door; countdown to the planned duration. */
  | { kind: 'away'; exitIndex: number; since: number; leftAt: number }
  /**
   * Break after an exit. It lasts until "Вышли" (past its plan, too); `nextExitIndex === null` means the plan is
   * finished and this is the cool-down, which ends the session when it runs out.
   */
  | { kind: 'breakTime'; afterExitIndex: number; since: number; duration: number; nextExitIndex: number | null }
  | { kind: 'finished' }

export const SessionPhase = {
  isFinished(phase: SessionPhase): boolean {
    return phase.kind === 'finished'
  },

  isOutside(phase: SessionPhase): boolean {
    return phase.kind === 'leaving' || phase.kind === 'away'
  },

  /** "Вышли" is the next step: before the first exit, or in a break with an exit after it. */
  canGoOutside(phase: SessionPhase): boolean {
    return phase.kind === 'ready' || phase.kind === 'leaving' || (phase.kind === 'breakTime' && phase.nextExitIndex !== null)
  },

  /** "Фальстарт" means something now: on the way out or outside. */
  canFalseStart(phase: SessionPhase): boolean {
    return SessionPhase.canGoOutside(phase) || SessionPhase.isOutside(phase)
  },

  /** Swift's synthesized enum coding: `{"ready":{"exitIndex":0}}`, `{"finished":{}}`. */
  encode(phase: SessionPhase, dates: DateEncoding): JSONObject {
    switch (phase.kind) {
      case 'ready':
        return { ready: { exitIndex: phase.exitIndex } }
      case 'leaving':
        return { leaving: { exitIndex: phase.exitIndex, since: encodeDate(phase.since, dates) } }
      case 'away':
        return {
          away: {
            exitIndex: phase.exitIndex,
            since: encodeDate(phase.since, dates),
            leftAt: encodeDate(phase.leftAt, dates),
          },
        }
      case 'breakTime':
        return {
          breakTime: compact({
            afterExitIndex: phase.afterExitIndex,
            since: encodeDate(phase.since, dates),
            duration: phase.duration,
            nextExitIndex: phase.nextExitIndex,
          }),
        }
      case 'finished':
        return { finished: {} }
    }
  },

  decode(value: unknown, dates: DateEncoding, path = ''): SessionPhase {
    const [name, json] = readEnumCase(value, path)
    switch (name) {
      case 'ready':
        return { kind: 'ready', exitIndex: json.int('exitIndex') }
      case 'leaving':
        return { kind: 'leaving', exitIndex: json.int('exitIndex'), since: json.date('since', dates) }
      case 'away':
        return {
          kind: 'away',
          exitIndex: json.int('exitIndex'),
          since: json.date('since', dates),
          leftAt: json.date('leftAt', dates),
        }
      case 'breakTime':
        return {
          kind: 'breakTime',
          afterExitIndex: json.int('afterExitIndex'),
          since: json.date('since', dates),
          duration: json.number('duration'),
          nextExitIndex: json.optionalInt('nextExitIndex'),
        }
      case 'finished':
        return { kind: 'finished' }
      default:
        throw new DecodingError(path, `unknown phase ${name}`)
    }
  },
}

/** The whole state of a session: enough to rebuild an identical copy on another device. */
export interface TrainingSessionSnapshot {
  plan: TrainingPlan
  startedAt: number
  phase: SessionPhase
  events: SessionEvent[]
  results: ExitResult[]
  /** Attempt number of the current exit (increments after a false start). */
  attempt: number
  finishedAt: number | null
  /** Finish the session automatically when the break after the last exit runs out. */
  autoFinishAfterLastBreak: boolean
  currentBreakStart: number | null
}

/** A button press on a session, sent to the device that owns it. */
export type SessionCommand = 'startExit' | 'markBehindDoor' | 'endExit' | 'resetExit' | 'finish'

export const SessionCommand = {
  allCases: ['startExit', 'markBehindDoor', 'endExit', 'resetExit', 'finish'] as readonly SessionCommand[],

  /** Applies the command to a session owned by this device. */
  apply(command: SessionCommand, session: TrainingSession): void {
    switch (command) {
      case 'startExit':
        return session.startExit()
      case 'markBehindDoor':
        return session.markBehindDoor()
      case 'endExit':
        return session.endExit()
      case 'resetExit':
        return session.resetExit()
      case 'finish':
        return session.finish()
    }
  },

  decode(value: unknown, path = ''): SessionCommand {
    const raw = expectString(value, path)
    if (!(SessionCommand.allCases as readonly string[]).includes(raw)) {
      throw new DecodingError(path, `unknown session command ${raw}`)
    }
    return raw as SessionCommand
  },
}

export type SessionListener = (snapshot: TrainingSessionSnapshot) => void

/**
 * State machine of one training session. All transitions are driven by two buttons — "Вышли" / "Вернулись" and
 * "Фальстарт" — plus `tick(now)`, called by a timer, that finishes the session when the last break runs out.
 */
export class TrainingSession {
  /**
   * Set on a mirror of a session that runs on another device (iPhone connected to a Mac): the buttons
   * call the usual actions, but they are forwarded here instead of changing this copy, and `tick` does
   * nothing. The owner applies the command and sends back a new snapshot (`restore`).
   */
  commandHandler: ((command: SessionCommand) => void) | null = null
  /** The same for `updatePlan` on a mirror: the edited schedule goes to the owner. */
  planHandler: ((plan: TrainingPlan) => void) | null = null

  private state: TrainingSessionSnapshot
  private readonly clock: Clock
  private readonly listeners = new Set<SessionListener>()

  /** Set only while `fromSnapshot` constructs a copy. */
  private static restoring: TrainingSessionSnapshot | null = null

  constructor(plan: TrainingPlan, options: { clock?: Clock } = {}) {
    this.clock = options.clock ?? Date.now
    const restored = TrainingSession.restoring
    if (restored) {
      this.state = { ...restored }
      return
    }
    const now = this.clock()
    this.state = {
      plan,
      startedAt: now,
      phase: plan.exits.length === 0 ? { kind: 'finished' } : { kind: 'ready', exitIndex: 0 },
      events: [],
      results: [],
      attempt: 1,
      finishedAt: null,
      autoFinishAfterLastBreak: true,
      currentBreakStart: null,
    }
    this.log('sessionStarted', now)
  }

  /** A copy of a session that runs elsewhere (no `sessionStarted` event is added). */
  static fromSnapshot(snapshot: TrainingSessionSnapshot, options: { clock?: Clock } = {}): TrainingSession {
    TrainingSession.restoring = snapshot
    try {
      return new TrainingSession(snapshot.plan, options)
    } finally {
      TrainingSession.restoring = null
    }
  }

  // MARK: - Store

  /** The current state. A new object after every change; never mutate it. */
  get snapshot(): TrainingSessionSnapshot {
    return this.state
  }

  /** Calls `listener` with the new snapshot after every change. Returns the unsubscribe function. */
  subscribe = (listener: SessionListener): (() => void) => {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  private batchDepth = 0
  private changed = false

  private update(changes: Partial<TrainingSessionSnapshot>): void {
    this.state = { ...this.state, ...changes }
    this.changed = true
    if (this.batchDepth === 0) this.emit()
  }

  /** Runs `body` and notifies subscribers once, with the final state (an action makes several changes). */
  private batch(body: () => void): void {
    this.batchDepth += 1
    try {
      body()
    } finally {
      this.batchDepth -= 1
      if (this.batchDepth === 0) this.emit()
    }
  }

  private emit(): void {
    if (!this.changed) return
    this.changed = false
    const snapshot = this.state
    for (const listener of [...this.listeners]) listener(snapshot)
  }

  // MARK: - Snapshot (sync between devices)

  /** Whether `snapshot` describes this very session (same plan and start), so `restore` can be used. */
  isSameSession(snapshot: TrainingSessionSnapshot): boolean {
    return sameUUID(snapshot.plan.id, this.state.plan.id) && snapshot.startedAt === this.state.startedAt
  }

  /** Updates the state in place from a newer snapshot of the same session. */
  restore(snapshot: TrainingSessionSnapshot): void {
    if (!this.isSameSession(snapshot)) return
    const next: TrainingSessionSnapshot = {
      ...this.state,
      plan: snapshot.plan,
      phase: snapshot.phase,
      events: snapshot.events,
      results: snapshot.results,
      attempt: snapshot.attempt,
      finishedAt: snapshot.finishedAt,
      autoFinishAfterLastBreak: snapshot.autoFinishAfterLastBreak,
      currentBreakStart: snapshot.currentBreakStart,
    }
    if (!deepEqual(next, this.state)) this.update(next)
  }

  // MARK: - State

  get plan(): TrainingPlan {
    return this.state.plan
  }
  get startedAt(): number {
    return this.state.startedAt
  }
  get phase(): SessionPhase {
    return this.state.phase
  }
  get events(): SessionEvent[] {
    return this.state.events
  }
  get results(): ExitResult[] {
    return this.state.results
  }
  get attempt(): number {
    return this.state.attempt
  }
  get finishedAt(): number | null {
    return this.state.finishedAt
  }
  get autoFinishAfterLastBreak(): boolean {
    return this.state.autoFinishAfterLastBreak
  }
  set autoFinishAfterLastBreak(value: boolean) {
    if (value !== this.state.autoFinishAfterLastBreak) this.update({ autoFinishAfterLastBreak: value })
  }

  // MARK: - Derived state

  get currentExitIndex(): number | null {
    return TrainingSession.currentExitIndex(this.state)
  }
  get currentExit(): PlannedExit | null {
    return TrainingSession.currentExit(this.state)
  }
  /** The exit that comes after the current one (for the "next up" hint). */
  get upcomingExit(): PlannedExit | null {
    return TrainingSession.upcomingExit(this.state)
  }
  /** Break that will follow the current exit, in seconds. */
  get breakAfterCurrentExit(): number | null {
    return TrainingSession.breakAfterCurrentExit(this.state)
  }
  get completedExitsCount(): number {
    return TrainingSession.completedExitsCount(this.state)
  }
  get falseStartsCount(): number {
    return TrainingSession.falseStartsCount(this.state)
  }
  get isFinished(): boolean {
    return this.state.phase.kind === 'finished'
  }
  /** Seconds left in the current countdown (`away` / `breakTime`); negative when overdue. */
  remaining(now: number): number | null {
    return TrainingSession.remaining(this.state, now)
  }
  /** Seconds since the current phase began. */
  elapsed(now: number): number {
    return TrainingSession.elapsed(this.state, now)
  }
  /** 0…1 progress of the current countdown, if any. */
  progress(now: number): number | null {
    return TrainingSession.progress(this.state, now)
  }

  static currentExitIndex(s: TrainingSessionSnapshot): number | null {
    switch (s.phase.kind) {
      case 'ready':
      case 'leaving':
      case 'away':
        return s.phase.exitIndex
      case 'breakTime':
        return s.phase.nextExitIndex
      case 'finished':
        return null
    }
  }

  static currentExit(s: TrainingSessionSnapshot): PlannedExit | null {
    const index = TrainingSession.currentExitIndex(s)
    if (index === null || index < 0 || index >= s.plan.exits.length) return null
    return s.plan.exits[index]
  }

  static upcomingExit(s: TrainingSessionSnapshot): PlannedExit | null {
    const index = TrainingSession.currentExitIndex(s)
    if (index === null) return null
    const next = index + 1
    return next >= 0 && next < s.plan.exits.length ? s.plan.exits[next] : null
  }

  static breakAfterCurrentExit(s: TrainingSessionSnapshot): number | null {
    const index = TrainingSession.currentExitIndex(s)
    return index === null ? null : TrainingPlan.breakAfter(s.plan, index)
  }

  static completedExitsCount(s: TrainingSessionSnapshot): number {
    return s.results.filter((result) => !result.falseStart).length
  }

  static falseStartsCount(s: TrainingSessionSnapshot): number {
    return s.results.filter((result) => result.falseStart).length
  }

  /** Seconds left in the current countdown (`away` / `breakTime`); negative when overdue. `null` when there is no countdown. */
  static remaining(s: TrainingSessionSnapshot, now: number): number | null {
    const phase = s.phase
    switch (phase.kind) {
      case 'away':
        return s.plan.exits[phase.exitIndex].duration - (now - phase.leftAt) / 1000
      case 'breakTime':
        return phase.duration - (now - phase.since) / 1000
      default:
        return null
    }
  }

  /** Seconds since the current phase began. */
  static elapsed(s: TrainingSessionSnapshot, now: number): number {
    const phase = s.phase
    switch (phase.kind) {
      case 'ready':
        return (now - (s.currentBreakStart ?? s.startedAt)) / 1000
      case 'leaving':
        return (now - phase.since) / 1000
      case 'away':
        return (now - phase.leftAt) / 1000
      case 'breakTime':
        return (now - phase.since) / 1000
      case 'finished':
        return ((s.finishedAt ?? now) - s.startedAt) / 1000
    }
  }

  /** 0…1 progress of the current countdown, if any. */
  static progress(s: TrainingSessionSnapshot, now: number): number | null {
    const phase = s.phase
    switch (phase.kind) {
      case 'away': {
        const planned = s.plan.exits[phase.exitIndex].duration
        if (!(planned > 0)) return null
        return Math.min(1, Math.max(0, (now - phase.leftAt) / 1000 / planned))
      }
      case 'breakTime':
        if (!(phase.duration > 0)) return null
        return Math.min(1, Math.max(0, (now - phase.since) / 1000 / phase.duration))
      default:
        return null
    }
  }

  // MARK: - Actions

  /** "Начать выход" of an older linked iPhone: the person heads for the door (`leaving`, then `markBehindDoor`). */
  startExit(): void {
    if (this.commandHandler) return this.commandHandler('startExit')
    this.batch(() => this.startExitNow(this.clock()))
  }

  private startExitNow(now: number): void {
    const phase = this.state.phase
    let index: number
    switch (phase.kind) {
      case 'ready':
        index = phase.exitIndex
        break
      case 'breakTime':
        if (phase.nextExitIndex === null) return
        index = phase.nextExitIndex
        this.logBreakEnd(phase.since, phase.duration, now)
        break
      default:
        return
    }
    this.closeBreak(now)
    this.update({ phase: { kind: 'leaving', exitIndex: index, since: now } })
    const exit = this.state.plan.exits[index]
    const description = PlannedExit.durationDescription(exit)
    this.log('exitStarted', now, {
      exitNumber: exit.number,
      attempt: this.state.attempt,
      detail: tr(`план ${description}`, `plan ${description}`),
    })
  }

  /**
   * "Вышли": the door is closed behind you, the exit's countdown starts. Ends the break (or the wait before the
   * first exit) right away.
   */
  markBehindDoor(): void {
    if (this.commandHandler) return this.commandHandler('markBehindDoor')
    const phase = this.state.phase
    const now = this.clock()
    switch (phase.kind) {
      case 'leaving':
        return this.batch(() => {
          this.update({ phase: { kind: 'away', exitIndex: phase.exitIndex, since: phase.since, leftAt: now } })
          this.log('behindDoor', now, {
            exitNumber: this.state.plan.exits[phase.exitIndex].number,
            attempt: this.state.attempt,
          })
        })
      case 'ready':
        return this.batch(() => {
          this.closeBreak(now)
          this.goOutside(phase.exitIndex, now)
        })
      case 'breakTime': {
        const next = phase.nextExitIndex
        if (next === null) return
        return this.batch(() => {
          this.logBreakEnd(phase.since, phase.duration, now)
          this.closeBreak(now)
          this.goOutside(next, now)
        })
      }
      default:
        return
    }
  }

  /** "Вернулись": back inside, the break begins. */
  endExit(): void {
    if (this.commandHandler) return this.commandHandler('endExit')
    this.batch(() => this.finishCurrentExit(false, this.clock()))
  }

  /**
   * "Фальстарт": the exit failed — take a break and repeat the same exit. Outside: back inside early. In the break
   * (or before the first exit): the dog went to the door, or there were sounds on the way out, before "Вышли" —
   * the attempt counts as a false start and the break starts over.
   */
  resetExit(): void {
    if (this.commandHandler) return this.commandHandler('resetExit')
    const phase = this.state.phase
    const now = this.clock()
    switch (phase.kind) {
      case 'leaving':
      case 'away':
        return this.batch(() => this.finishCurrentExit(true, now))
      case 'ready':
        return this.batch(() => this.falseStartBeforeDoor(phase.exitIndex, now))
      case 'breakTime': {
        const next = phase.nextExitIndex
        if (next === null) return
        return this.batch(() => {
          this.logBreakEnd(phase.since, phase.duration, now)
          this.falseStartBeforeDoor(next, now)
        })
      }
      default:
        return
    }
  }

  // MARK: - Editing the schedule

  /**
   * How many exits from the start of the plan are fixed while the session runs: the ones done and the current one.
   * An edit may change their values, but not remove or reorder them.
   */
  get fixedExitCount(): number {
    return TrainingSession.fixedExitCount(this.state)
  }

  static fixedExitCount(snapshot: TrainingSessionSnapshot): number {
    const phase = snapshot.phase
    switch (phase.kind) {
      case 'ready':
        return phase.exitIndex
      case 'leaving':
      case 'away':
        return phase.exitIndex + 1
      case 'breakTime':
        return phase.afterExitIndex + 1
      case 'finished':
        return snapshot.plan.exits.length
    }
  }

  /**
   * Whether `plan` can replace the running schedule: the same plan (id), with the fixed exits still first and in
   * their order, and an exit for the session to be at.
   */
  static canUpdatePlan(snapshot: TrainingSessionSnapshot, plan: TrainingPlan): boolean {
    const phase = snapshot.phase
    if (phase.kind === 'finished' || !sameUUID(plan.id, snapshot.plan.id) || !TrainingPlan.isValid(plan)) return false
    const fixed = TrainingSession.fixedExitCount(snapshot)
    if (plan.exits.length < fixed) return false
    if (phase.kind === 'ready' && phase.exitIndex >= plan.exits.length) return false
    return plan.exits.slice(0, fixed).every((exit, index) => sameUUID(exit.id, snapshot.plan.exits[index].id))
  }

  /**
   * Replaces the schedule while the session runs — e.g. every break longer when the trainer's text was read wrong
   * and nobody noticed before the start. The current exit counts down to its new length, the running break takes
   * its new length too, and exits added after the last one carry the training on. The log gets a note with what
   * changed. Returns false and changes nothing when the edit drops or reorders exits already done (or the current).
   */
  updatePlan(edited: TrainingPlan): boolean {
    if (!TrainingSession.canUpdatePlan(this.state, edited)) return false
    if (this.planHandler) {
      this.planHandler(edited)
      return true
    }
    const plan = TrainingPlan.renumbered(edited)
    const changes = TrainingPlan.changes(plan, this.state.plan)
    this.batch(() => {
      const phase = this.state.phase
      if (phase.kind === 'breakTime') {
        // A false start's break leads to the same exit again; otherwise to whatever follows now.
        const after = phase.afterExitIndex
        const next = phase.nextExitIndex === after ? after : after + 1 < plan.exits.length ? after + 1 : null
        const duration = TrainingPlan.breakAfter(plan, after)
        const results = this.state.results
        this.update({
          phase: { ...phase, duration, nextExitIndex: next },
          results: results.length ? [...results.slice(0, -1), { ...results[results.length - 1], plannedBreak: duration }] : results,
        })
      }
      this.update({ plan })
      if (changes.length) {
        this.log('note', this.clock(), {
          exitNumber: this.currentExit?.number ?? null,
          detail: tr('Расписание изменено: ', 'Schedule changed: ') + changes.join('; '),
        })
      }
    })
    return true
  }

  /** Ends the session right now (also used by the auto-finish after the last break). */
  finish(): void {
    if (this.commandHandler) return this.commandHandler('finish')
    if (this.state.phase.kind === 'finished') return
    const now = this.clock()
    this.batch(() => {
      if (SessionPhase.isOutside(this.state.phase)) {
        this.finishCurrentExit(false, now)
      }
      this.closeBreak(now)
      this.update({ phase: { kind: 'finished' }, finishedAt: now })
      const completed = TrainingSession.completedExitsCount(this.state)
      const planned = this.state.plan.exits.length
      this.log('sessionFinished', now, {
        detail: tr(`выходов ${completed} из ${planned}`, `exits ${completed} of ${planned}`),
      })
    })
  }

  /**
   * Called periodically. Finishes the session when the break after the last exit runs out; other breaks go on past
   * their plan until "Вышли" (the views count the extra time up). `now` defaults to the clock.
   */
  tick(now: number = this.clock()): void {
    if (this.commandHandler || !this.state.autoFinishAfterLastBreak) return
    const phase = this.state.phase
    if (phase.kind !== 'breakTime' || phase.nextExitIndex !== null) return
    if ((now - phase.since) / 1000 < phase.duration) return
    this.finish()
  }

  addNote(text: string): void {
    this.log('note', this.clock(), { exitNumber: this.currentExit?.number ?? null, detail: text })
  }

  noteRecording(started: boolean, fileName: string | null = null): void {
    this.log(started ? 'recordingStarted' : 'recordingStopped', this.clock(), { detail: fileName })
  }

  makeRecord(recordingFileName: string | null): TrainingRecord {
    return TrainingRecord.make({
      plan: this.state.plan,
      startedAt: this.state.startedAt,
      finishedAt: this.state.finishedAt ?? this.clock(),
      events: this.state.events,
      results: this.state.results,
      recordingFileName,
    })
  }

  // MARK: - Internals

  private finishCurrentExit(falseStart: boolean, now: number): void {
    const phase = this.state.phase
    if (phase.kind !== 'leaving' && phase.kind !== 'away') return
    this.endAttempt(phase.exitIndex, phase.since, phase.kind === 'away' ? phase.leftAt : null, falseStart, now)
  }

  /** A false start before "Вышли": an attempt that never got outside. */
  private falseStartBeforeDoor(index: number, now: number): void {
    this.closeBreak(now)
    this.endAttempt(index, now, null, true, now)
  }

  private goOutside(index: number, now: number): void {
    this.update({ phase: { kind: 'away', exitIndex: index, since: now, leftAt: now } })
    const exit = this.state.plan.exits[index]
    const description = PlannedExit.durationDescription(exit)
    this.log('behindDoor', now, {
      exitNumber: exit.number,
      attempt: this.state.attempt,
      detail: tr(`план ${description}`, `plan ${description}`),
    })
  }

  /** "Перерыв окончен" when it ends by a button: early, or how far past its plan. */
  private logBreakEnd(since: number, duration: number, now: number): void {
    const actual = (now - since) / 1000
    const clock = DurationText.clock(actual)
    const planned = DurationText.short(duration)
    let detail: string | null = null
    if (actual < duration) {
      detail = tr(`досрочно, ${clock} из ${planned}`, `early, ${clock} of ${planned}`)
    } else if (actual - duration >= 1) {
      detail = tr(`дольше плана, ${clock} из ${planned}`, `longer than planned, ${clock} of ${planned}`)
    }
    this.log('breakEnded', now, { detail })
  }

  private endAttempt(index: number, since: number, leftAt: number | null, falseStart: boolean, now: number): void {
    const { plan, attempt } = this.state
    const exit = plan.exits[index]
    const plannedBreak = TrainingPlan.breakAfter(plan, index)
    const result = ExitResult.make({
      number: exit.number,
      attempt,
      plannedDuration: exit.duration,
      untilStanding: exit.untilStanding,
      startedAt: since,
      leftAt,
      endedAt: now,
      falseStart,
      plannedBreak,
    })
    this.update({ results: [...this.state.results, result] })

    const away = DurationText.clock(ExitResult.awayDuration(result))
    const total = DurationText.clock(ExitResult.totalDuration(result))
    this.log(falseStart ? 'falseStart' : 'exitEnded', now, {
      exitNumber: exit.number,
      attempt,
      detail:
        leftAt === null && since === now
          ? tr('до двери', 'before the door')
          : tr(`за дверью ${away}, всего ${total}`, `outside ${away}, total ${total}`),
    })

    let nextIndex: number | null
    let nextAttempt: number
    if (falseStart) {
      nextIndex = index
      nextAttempt = attempt + 1
    } else {
      nextIndex = index + 1 < plan.exits.length ? index + 1 : null
      nextAttempt = 1
    }

    this.update({
      attempt: nextAttempt,
      currentBreakStart: now,
      phase: { kind: 'breakTime', afterExitIndex: index, since: now, duration: plannedBreak, nextExitIndex: nextIndex },
    })
    const planText = DurationText.short(plannedBreak)
    this.log('breakStarted', now, {
      detail: tr(`план ${planText}`, `plan ${planText}`) + (nextIndex === null ? tr(', последний', ', last') : ''),
    })
  }

  private closeBreak(now: number): void {
    const start = this.state.currentBreakStart
    const results = this.state.results
    if (start === null || results.length === 0) return
    const last = { ...results[results.length - 1], actualBreak: (now - start) / 1000 }
    this.update({ results: [...results.slice(0, -1), last], currentBreakStart: null })
  }

  private log(
    kind: SessionEventKind,
    time: number,
    fields: { exitNumber?: number | null; attempt?: number | null; detail?: string | null } = {},
  ): void {
    this.update({ events: [...this.state.events, SessionEvent.make({ time, kind, ...fields })] })
  }

  // MARK: - JSON

  static encodeSnapshot(snapshot: TrainingSessionSnapshot, dates: DateEncoding): JSONObject {
    return compact({
      plan: TrainingPlan.encode(snapshot.plan, dates),
      startedAt: encodeDate(snapshot.startedAt, dates),
      phase: SessionPhase.encode(snapshot.phase, dates),
      events: snapshot.events.map((event) => SessionEvent.encode(event, dates)),
      results: snapshot.results.map((result) => ExitResult.encode(result, dates)),
      attempt: snapshot.attempt,
      finishedAt: snapshot.finishedAt === null ? null : encodeDate(snapshot.finishedAt, dates),
      autoFinishAfterLastBreak: snapshot.autoFinishAfterLastBreak,
      currentBreakStart: snapshot.currentBreakStart === null ? null : encodeDate(snapshot.currentBreakStart, dates),
    })
  }

  static decodeSnapshot(value: unknown, dates: DateEncoding, path = ''): TrainingSessionSnapshot {
    const json = new ObjectReader(value, path)
    return {
      plan: json.required('plan', (item, itemPath) => TrainingPlan.decode(item, dates, itemPath)),
      startedAt: json.date('startedAt', dates),
      phase: json.required('phase', (item, itemPath) => SessionPhase.decode(item, dates, itemPath)),
      events: json.array('events', (item, itemPath) => SessionEvent.decode(item, dates, itemPath)),
      results: json.array('results', (item, itemPath) => ExitResult.decode(item, dates, itemPath)),
      attempt: json.int('attempt'),
      finishedAt: json.optionalDate('finishedAt', dates),
      autoFinishAfterLastBreak: json.bool('autoFinishAfterLastBreak'),
      currentBreakStart: json.optionalDate('currentBreakStart', dates),
    }
  }
}
