// Port of TrainingSessionTests.swift.
import { beforeEach, describe, expect, it } from 'vitest'
import {
  ExitResult,
  PlannedExit,
  SessionLogFormatter,
  TrainingPlan,
  TrainingRecord,
  TrainingSession,
  type TrainingSessionSnapshot,
  setCoreLanguage,
  setCoreRegion,
} from '@core/index'

describe('TrainingSession', () => {
  // These tests check the Russian texts (the default language of the app's first users).
  let now: number
  beforeEach(() => {
    setCoreLanguage('ru')
    now = 1_000_000_000
  })

  const makeSession = () => {
    const plan = TrainingPlan.make({
      exits: [
        PlannedExit.make({ number: 1, duration: 5 }),
        PlannedExit.make({ number: 2, duration: 30, untilStanding: true, breakAfter: 300 }),
      ],
    })
    return new TrainingSession(plan, { clock: () => now })
  }
  const advance = (seconds: number) => {
    now += seconds * 1000
  }

  it('walks the happy path', () => {
    const session = makeSession()
    expect(session.phase).toEqual({ kind: 'ready', exitIndex: 0 })

    session.startExit()
    advance(3)
    session.markBehindDoor()
    advance(2)
    expect(session.remaining(now)).toBe(3)
    advance(5)
    expect(session.remaining(now)).toBe(-2)
    session.endExit()

    expect(session.results).toHaveLength(1)
    expect(ExitResult.awayDuration(session.results[0])).toBe(7)
    expect(ExitResult.totalDuration(session.results[0])).toBe(10)
    expect(session.results[0].falseStart).toBe(false)
    const phase = session.phase
    if (phase.kind !== 'breakTime') throw new Error('expected break')
    expect(phase.afterExitIndex).toBe(0)
    expect(phase.duration).toBe(120)
    expect(phase.nextExitIndex).toBe(1)

    // Break runs out → ready for exit 2.
    advance(121)
    session.tick(now)
    expect(session.phase).toEqual({ kind: 'ready', exitIndex: 1 })

    advance(10)
    session.startExit()
    expect(session.results[0].actualBreak).toBe(131)
    session.markBehindDoor()
    advance(20)
    session.endExit()

    const last = session.phase
    if (last.kind !== 'breakTime') throw new Error('expected last break')
    expect(last.duration).toBe(300)
    expect(last.nextExitIndex).toBeNull()

    advance(300)
    session.tick(now)
    expect(session.isFinished).toBe(true)
    expect(session.completedExitsCount).toBe(2)
    expect(session.events.at(-1)?.kind).toBe('sessionFinished')
  })

  it('repeats the exit after a false start', () => {
    const session = makeSession()
    session.startExit()
    session.markBehindDoor()
    advance(1)
    session.resetExit()

    expect(session.results).toHaveLength(1)
    expect(session.results[0].falseStart).toBe(true)
    expect(session.attempt).toBe(2)
    const phase = session.phase
    if (phase.kind !== 'breakTime') throw new Error('expected break')
    expect(phase.nextExitIndex).toBe(0)

    session.startExit() // early, before the break ends
    expect(session.phase).toEqual({ kind: 'leaving', exitIndex: 0, since: now })
    expect(session.events.filter((e) => e.kind === 'breakEnded')).toHaveLength(1)
    session.endExit()
    expect(session.results[1].attempt).toBe(2)
    expect(session.attempt).toBe(1)
    expect(session.currentExitIndex).toBe(1)
  })

  it('closes the exit when finished while outside', () => {
    const session = makeSession()
    session.startExit()
    session.markBehindDoor()
    advance(4)
    session.finish()
    expect(session.isFinished).toBe(true)
    expect(session.results).toHaveLength(1)
    expect(ExitResult.awayDuration(session.results[0])).toBe(4)
    expect(session.finishedAt).toBe(now)
  })

  it('log formatter includes everything', () => {
    const session = makeSession()
    session.startExit(); session.markBehindDoor(); advance(5); session.endExit(); session.finish()
    const record = session.makeRecord('video.mp4')
    const text = SessionLogFormatter.text(record)
    expect(text, 'the file name is no use to the trainer').not.toContain('video.mp4')
    expect(text).toContain('1 выход — 5 с: за дверью 0:05 ✅')
    expect(text, 'the break after the last exit only ends the session').not.toContain('перерыв')
  })

  it('log formatter writes one line per attempt', () => {
    const session = makeSession()
    session.startExit(); session.markBehindDoor(); advance(2); session.resetExit()
    advance(60); session.startExit(); session.markBehindDoor(); advance(5); session.endExit()
    advance(120); session.tick()
    session.startExit(); session.markBehindDoor(); advance(30); session.endExit(); session.finish()
    const lines = SessionLogFormatter.text(session.makeRecord(null))
      .split('\n')
      .filter((line) => line.includes(' выход — '))
    expect(lines).toEqual([
      '1 выход — 5 с: фальстарт, за дверью 0:02 ❌ · перерыв 1:00 (план 2 мин)',
      '1 выход — 5 с, попытка 2: за дверью 0:05 ✅ · перерыв 2:00',
      '2 выход — 30 с или до вставания: за дверью 0:30 ✅',
    ])
  })
})

// Not in the Swift suite: the store behaviour of the TS session and the log example in ARCHITECTURE.md.
describe('TrainingSession store', () => {
  beforeEach(() => setCoreLanguage('ru'))

  it('notifies subscribers once per action with a new immutable snapshot', () => {
    let now = 5_000_000
    const plan = TrainingPlan.make({ exits: [PlannedExit.make({ number: 1, duration: 5 })] })
    const session = new TrainingSession(plan, { clock: () => now })
    const seen: TrainingSessionSnapshot[] = []
    const unsubscribe = session.subscribe((snapshot) => seen.push(snapshot))
    const before = session.snapshot

    session.startExit()
    expect(seen).toHaveLength(1)
    expect(seen[0]).toBe(session.snapshot)
    expect(before.phase).toEqual({ kind: 'ready', exitIndex: 0 })
    expect(before.events).toHaveLength(1)

    session.markBehindDoor() // one notification
    now += 6000
    session.endExit() // results + log + break: one notification
    expect(seen).toHaveLength(3)
    session.markBehindDoor() // not leaving: nothing changes
    expect(seen).toHaveLength(3)

    unsubscribe()
    session.finish()
    expect(seen).toHaveLength(3)
    expect(session.isFinished).toBe(true)
  })

  it('computes countdowns from a snapshot alone', () => {
    let now = 0
    const plan = TrainingPlan.make({ exits: [PlannedExit.make({ number: 1, duration: 10 })] })
    const session = new TrainingSession(plan, { clock: () => now })
    session.startExit()
    now += 1000
    session.markBehindDoor()
    const snapshot = session.snapshot
    expect(TrainingSession.remaining(snapshot, now + 4000)).toBe(6)
    expect(TrainingSession.progress(snapshot, now + 5000)).toBe(0.5)
    expect(TrainingSession.elapsed(snapshot, now + 2500)).toBe(2.5)
    expect(TrainingSession.currentExit(snapshot)?.number).toBe(1)
    expect(TrainingSession.upcomingExit(snapshot)).toBeNull()
    expect(TrainingSession.breakAfterCurrentExit(snapshot)).toBe(120)
  })

  it('logs early breaks, notes and recordings', () => {
    let now = 0
    const plan = TrainingPlan.make({
      exits: [PlannedExit.make({ number: 1, duration: 5 }), PlannedExit.make({ number: 2, duration: 5 })],
    })
    const session = new TrainingSession(plan, { clock: () => now })
    session.noteRecording(true, 'a.mp4')
    session.startExit(); session.markBehindDoor(); now += 5000; session.endExit()
    now += 30_000
    session.addNote('Лаяла')
    session.startExit()
    const kinds = session.events.map((e) => e.kind)
    expect(kinds).toEqual([
      'sessionStarted', 'recordingStarted', 'exitStarted', 'behindDoor', 'exitEnded', 'breakStarted', 'note',
      'breakEnded', 'exitStarted',
    ])
    expect(session.events[1].detail).toBe('a.mp4')
    expect(session.events[2].detail).toBe('план 5 с')
    expect(session.events[4].detail).toBe('за дверью 0:05, всего 0:05')
    expect(session.events[5].detail).toBe('план 2 мин')
    expect(session.events[6]).toMatchObject({ exitNumber: 2, detail: 'Лаяла' })
    expect(session.events[7].detail).toBe('досрочно, 0:30 из 2 мин')
    expect(session.events[8]).toMatchObject({ exitNumber: 2, attempt: 1 })
  })

  it('writes the ARCHITECTURE.md log example header and lines', () => {
    setCoreRegion('RU')
    const start = new Date(2026, 8, 25, 18, 0, 0).getTime()
    let now = start
    const plan = TrainingPlan.make({
      title: 'Тренировка на пятницу',
      trainers: 'Андрей',
      exits: [
        PlannedExit.make({ number: 1, duration: 2 }),
        PlannedExit.make({ number: 2, duration: 5, breakAfter: 300 }),
      ],
    })
    const session = new TrainingSession(plan, { clock: () => now })
    session.startExit(); now += 1000; session.markBehindDoor(); now += 3000; session.endExit()
    now += 128_000; session.tick()
    session.startExit(); session.markBehindDoor(); now += 1000; session.resetExit()
    now += 60_000; session.startExit(); session.markBehindDoor(); now += 6000; session.endExit()
    now = start + 13 * 60_000
    session.finish()
    const text = SessionLogFormatter.text(session.makeRecord(null))
    expect(text.split('\n')).toEqual([
      'Тренировка на пятницу · Андрей',
      '25.09.2026, 18:00–18:13 (13 мин) · выходов 2 из 2 · фальстартов 1',
      '',
      '1 выход — 2 с: за дверью 0:03 ✅ · перерыв 2:08',
      '2 выход — 5 с: фальстарт, за дверью 0:01 ❌ · перерыв 1:00 (план 5 мин)',
      '2 выход — 5 с, попытка 2: за дверью 0:06 ✅',
    ])
    const record = session.makeRecord(null)
    expect(TrainingRecord.completedExits(record)).toBe(2)
    expect(TrainingRecord.falseStarts(record)).toBe(1)
  })

  it('a plan without exits is finished from the start', () => {
    const session = new TrainingSession(TrainingPlan.make(), { clock: () => 0 })
    expect(session.isFinished).toBe(true)
    expect(session.events.map((e) => e.kind)).toEqual(['sessionStarted'])
  })
})
