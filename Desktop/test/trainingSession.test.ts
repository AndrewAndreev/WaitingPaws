// Port of TrainingSessionTests.swift.
import { beforeEach, describe, expect, it } from 'vitest'
import {
  DISK_DATES,
  EarlyEntry,
  ExitResult,
  PlannedExit,
  SessionPhase,
  SessionLogFormatter,
  TrainingPlan,
  TrainingRecord,
  TrainingSession,
  type TrainingSessionSnapshot,
  newUUID,
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
    expect(SessionPhase.canGoOutside(session.phase)).toBe(true)

    // "Вышли" goes straight outside: no walk to the door in between.
    session.markBehindDoor()
    expect(session.phase).toEqual({ kind: 'away', exitIndex: 0, since: now, leftAt: now })
    expect(session.events.at(-1)).toMatchObject({ kind: 'behindDoor', detail: 'план 5 с' })
    advance(2)
    expect(session.remaining(now)).toBe(3)
    advance(5)
    expect(session.remaining(now)).toBe(-2)
    session.endExit()

    expect(session.results).toHaveLength(1)
    expect(ExitResult.awayDuration(session.results[0])).toBe(7)
    expect(ExitResult.totalDuration(session.results[0])).toBe(7)
    expect(session.results[0].falseStart).toBe(false)
    const phase = session.phase
    if (phase.kind !== 'breakTime') throw new Error('expected break')
    expect(phase.afterExitIndex).toBe(0)
    expect(phase.duration).toBe(120)
    expect(phase.nextExitIndex).toBe(1)

    // The break runs past its plan until "Вышли": the time left goes negative.
    advance(131)
    session.tick(now)
    expect(session.phase.kind).toBe('breakTime')
    expect(session.remaining(now)).toBe(-11)

    session.markBehindDoor()
    expect(session.results[0].actualBreak).toBe(131)
    expect(session.events.find((e) => e.kind === 'breakEnded')?.detail).toBe('дольше плана, 2:11 из 2 мин')
    expect(session.phase).toEqual({ kind: 'away', exitIndex: 1, since: now, leftAt: now })
    advance(20)
    session.endExit()

    const last = session.phase
    if (last.kind !== 'breakTime') throw new Error('expected last break')
    expect(last.duration).toBe(300)
    expect(last.nextExitIndex).toBeNull()
    expect(SessionPhase.canGoOutside(last)).toBe(false)
    expect(SessionPhase.canFalseStart(last)).toBe(false)

    // The last break runs over too: only «Завершить» ends the training (and its recording).
    advance(400)
    session.tick(now)
    expect(session.isFinished).toBe(false)
    expect(session.remaining(now)).toBe(-100)
    session.finish()
    expect(session.isFinished).toBe(true)
    expect(session.completedExitsCount).toBe(2)
    expect(session.events.at(-1)?.kind).toBe('sessionFinished')
  })

  it('logs an early break end', () => {
    const session = makeSession()
    session.markBehindDoor(); advance(5); session.endExit()
    advance(90)
    session.markBehindDoor()
    expect(session.events.find((e) => e.kind === 'breakEnded')?.detail).toBe('досрочно, 1:30 из 2 мин')
    expect(session.results[0].actualBreak).toBe(90)
  })

  // "Фальстарт" in a break: the dog went to the door (or there were sounds on the way out) before "Вышли".
  it('starts the break over after a false start in it', () => {
    const session = makeSession()
    session.markBehindDoor(); advance(5); session.endExit()
    advance(100)
    expect(SessionPhase.canFalseStart(session.phase)).toBe(true)
    session.resetExit()

    expect(session.results).toHaveLength(2)
    expect(session.results[0].actualBreak).toBe(100)
    const failed = session.results[1]
    expect(failed).toMatchObject({ number: 2, falseStart: true, leftAt: null, startedAt: now })
    expect(session.attempt).toBe(2)
    expect(session.events.find((e) => e.kind === 'falseStart')?.detail).toBe('до двери')
    // A new break (the one after exit 2), then exit 2 again.
    expect(session.phase).toEqual({ kind: 'breakTime', afterExitIndex: 1, since: now, duration: 300, nextExitIndex: 1 })

    advance(300)
    session.markBehindDoor(); advance(30); session.endExit(); session.finish()
    const lines = SessionLogFormatter.text(session.makeRecord(null))
      .split('\n')
      .filter((line) => line.includes(' выход — '))
    expect(lines).toEqual([
      '1 выход — 5 с: за дверью 0:05 ✅ · перерыв 1:40 (план 2 мин)',
      '2 выход — 30 с или до вставания: фальстарт до двери ❌ · перерыв 5:00',
      '2 выход — 30 с или до вставания, попытка 2: за дверью 0:30 ✅',
    ])
  })

  it('takes a false start before the first exit', () => {
    const session = makeSession()
    advance(20)
    session.resetExit()
    expect(session.results).toHaveLength(1)
    expect(session.results[0].falseStart).toBe(true)
    expect(session.attempt).toBe(2)
    expect(session.phase).toEqual({ kind: 'breakTime', afterExitIndex: 0, since: now, duration: 120, nextExitIndex: 0 })
  })

  // An older linked iPhone still sends "Начать выход" and then "За дверью".
  it('still walks to the door for an older iPhone', () => {
    const session = makeSession()
    session.startExit()
    expect(session.phase).toEqual({ kind: 'leaving', exitIndex: 0, since: now })
    advance(3)
    session.markBehindDoor()
    advance(5)
    session.endExit()
    expect(ExitResult.awayDuration(session.results[0])).toBe(5)
    expect(ExitResult.totalDuration(session.results[0])).toBe(8)
  })

  // The common break was read wrong and is noticed in the first break: every break gets longer, this one too.
  it('takes an edited schedule during a break', () => {
    const session = makeSession()
    session.markBehindDoor(); advance(5); session.endExit()
    advance(60)
    const plan = session.plan
    const edited = { ...plan, defaultBreak: 180, exits: plan.exits.map((exit, i) => (i === 1 ? { ...exit, duration: 45 } : exit)) }
    expect(session.updatePlan(edited)).toBe(true)
    expect(session.phase).toEqual({ kind: 'breakTime', afterExitIndex: 0, since: now - 60_000, duration: 180, nextExitIndex: 1 })
    expect(session.remaining(now)).toBe(120)
    expect(session.results[0].plannedBreak).toBe(180)
    expect(session.events.at(-1)).toMatchObject({
      kind: 'note',
      detail: 'Расписание изменено: перерывы 2 мин → 3 мин; выход 2: 30 с или до вставания → 45 с или до вставания',
    })
    session.markBehindDoor()
    advance(10)
    expect(session.remaining(now)).toBe(35)
  })

  // A drag applies every step at once (the timer follows it) and logs the whole edit once, when it is let go.
  it('logs an edit made in steps once', () => {
    const session = makeSession()
    session.markBehindDoor()
    advance(3)
    const before = session.plan
    const notes = () => session.events.filter((event) => event.kind === 'note').length
    for (const duration of [6, 8, 10]) {
      const step = { ...session.plan, exits: session.plan.exits.map((exit, i) => (i === 0 ? { ...exit, duration } : exit)) }
      expect(session.updatePlan(step, { quiet: true })).toBe(true)
      expect(session.remaining(now)).toBe(duration - 3)
    }
    expect(notes()).toBe(0)
    const last = { ...session.plan, exits: session.plan.exits.map((exit, i) => (i === 0 ? { ...exit, duration: 12 } : exit)) }
    session.updatePlan(last, { changesSince: before })
    expect(notes()).toBe(1)
    expect(session.events.at(-1)?.detail).toBe('Расписание изменено: выход 1: 5 с → 12 с')
  })

  it('keeps the exits already done when the schedule is edited', () => {
    const session = makeSession()
    session.markBehindDoor(); advance(5); session.endExit()
    advance(120); session.markBehindDoor()
    expect(session.fixedExitCount).toBe(2)
    const plan = session.plan
    expect(session.updatePlan({ ...plan, exits: plan.exits.slice(1) }), 'exit 1 is done').toBe(false)
    expect(session.updatePlan({ ...plan, exits: [plan.exits[1], plan.exits[0]] })).toBe(false)
    expect(session.plan.exits).toHaveLength(2)

    // One more exit after the last: the cool-down becomes a break before it.
    expect(session.updatePlan({ ...plan, exits: [...plan.exits, PlannedExit.make({ number: 3, duration: 10 })] })).toBe(true)
    advance(30); session.endExit()
    expect(session.phase).toMatchObject({ kind: 'breakTime', duration: 300, nextExitIndex: 2 })
    expect(session.events.find((e) => e.kind === 'note')?.detail).toBe('Расписание изменено: добавлен выход 3 — 10 с')
  })

  it('ends with the break when the next exit is removed', () => {
    const session = makeSession()
    session.markBehindDoor(); advance(5); session.endExit()
    const plan = session.plan
    expect(session.updatePlan({ ...plan, exits: plan.exits.slice(0, 1) })).toBe(true)
    expect(session.phase).toMatchObject({ kind: 'breakTime', nextExitIndex: null })
  })

  it('a mirror sends the edited schedule to the owner', () => {
    const owner = makeSession()
    const mirror = TrainingSession.fromSnapshot(owner.snapshot, { clock: () => now })
    let sent: TrainingPlan | null = null
    mirror.planHandler = (plan) => {
      sent = plan
    }
    // A step of an edit applies without a note; the last one logs the whole edit.
    expect(mirror.updatePlan({ ...mirror.plan, defaultBreak: 90 })).toBe(true)
    expect(mirror.plan.defaultBreak, 'the owner applies it').toBe(120)
    owner.updatePlan(sent!)
    mirror.restore(owner.snapshot)
    expect(mirror.plan.defaultBreak).toBe(90)
  })

  // «Ещё выход» after the schedule's last exit: an exit without a planned time, counting up, in the log as such.
  it('adds an open exit after the last one', () => {
    const session = makeSession()
    session.markBehindDoor(); advance(5); session.endExit()
    advance(120); session.markBehindDoor(); advance(30); session.endExit()
    expect(session.phase).toMatchObject({ kind: 'breakTime', nextExitIndex: null })

    advance(60)
    session.startOpenExit()
    expect(session.plan.exits).toHaveLength(3)
    expect(session.plan.exits[2].isOpen).toBe(true)
    const phase = session.phase
    if (phase.kind !== 'away') throw new Error('expected outside')
    expect(phase.exitIndex).toBe(2)
    advance(42)
    expect(session.remaining(now)).toBeNull()
    expect(session.elapsed(now)).toBe(42)
    session.endExit()
    expect(session.phase).toMatchObject({ kind: 'breakTime', nextExitIndex: null })
    session.finish()

    const log = SessionLogFormatter.text(session.makeRecord(null))
    expect(log).toContain('3 выход — без времени: за дверью 0:42 ✅')
    const again = TrainingPlan.decode(JSON.parse(JSON.stringify(TrainingPlan.encode(session.plan, DISK_DATES))), DISK_DATES)
    expect(again.exits[2].isOpen).toBe(true)

    // Not in the Swift test: the schedule note, the result's JSON and an older build's result.
    expect(session.events.map((event) => event.detail)).toContain('Расписание изменено: добавлен выход 3 — без времени')
    const result = session.results[2]
    expect(result.isOpen).toBe(true)
    const json = ExitResult.encode(result, DISK_DATES)
    expect(json.isOpen).toBe(true)
    expect(ExitResult.decode(JSON.parse(JSON.stringify(json)), DISK_DATES)).toEqual(result)
    delete json.isOpen
    expect(ExitResult.decode(json, DISK_DATES).isOpen).toBe(false)
  })

  it('takes «Ещё выход» only in the break after the last exit, on a mirror plan first', () => {
    const session = makeSession()
    session.startOpenExit()
    expect(session.phase.kind, 'before the first exit').toBe('ready')
    session.markBehindDoor(); advance(5); session.endExit()
    session.startOpenExit()
    expect(session.plan.exits, 'an exit still to come').toHaveLength(2)

    advance(120); session.markBehindDoor(); advance(30); session.endExit()
    const mirror = TrainingSession.fromSnapshot(session.snapshot, { clock: () => now })
    const sent: string[] = []
    mirror.planHandler = (plan) => sent.push(`plan ${plan.exits.length}`)
    mirror.commandHandler = (command) => sent.push(command)
    mirror.startOpenExit()
    expect(sent).toEqual(['plan 3', 'markBehindDoor'])
    expect(mirror.plan.exits, 'the owner applies it').toHaveLength(2)
  })

  // A press on the iPhone whose command reaches the computer seconds later is still logged when it was pressed.
  it('keeps the moment of a late press, within the phase', () => {
    const session = makeSession()
    session.markBehindDoor()
    const leftAt = now
    advance(4)
    const pressed = now
    advance(6)
    session.endExit(pressed)
    expect(session.results[0].endedAt).toBe(pressed)
    expect(session.phase).toMatchObject({ kind: 'breakTime', since: pressed })
    expect(session.remaining(now)).toBe(114)

    // A clock that is off: never before the phase, never in the future.
    session.markBehindDoor(now + 90_000)
    expect(session.phase).toMatchObject({ kind: 'away', leftAt: now })
    session.endExit(leftAt - 30_000)
    expect(session.results[1].endedAt).toBe(now)
    const times = session.events.map((event) => event.time)
    expect(times).toEqual([...times].sort((a, b) => a - b))
  })

  it('gives every exit its conditions for coming back early', () => {
    let plan = TrainingPlan.make({
      exits: [PlannedExit.make({ number: 1, duration: 30, untilStanding: true }), PlannedExit.make({ number: 2, duration: 120 })],
    })
    // «ИЛИ до вставания» alone: come back as soon as she stands.
    expect(TrainingPlan.earlyEntries(plan, plan.exits[0]).map(EarlyEntry.summary)).toEqual(['встала → сразу'])
    expect(TrainingPlan.earlyEntries(plan, plan.exits[1])).toEqual([])

    plan = {
      ...plan,
      commonEarlyEntries: [
        EarlyEntry.make({ event: 'Встала и пошла', delay: 15, tone: 'yellow' }),
        EarlyEntry.make({ event: 'Легла', delay: 30, tone: 'green' }),
      ],
    }
    expect(TrainingPlan.commonEntriesScope(plan)).toBe('all')
    // A condition about standing up takes the place of «до вставания».
    expect(TrainingPlan.earlyEntries(plan, plan.exits[0]).map(EarlyEntry.summary)).toEqual(['встала и пошла → 0:15', 'легла → 0:30'])
    expect(TrainingPlan.usesCommonEarlyEntries(plan, plan.exits[1])).toBe(true)

    plan = TrainingPlan.applyCommonEarlyEntries(plan, 'long')
    expect(TrainingPlan.commonEntriesScope(plan)).toBe('long')
    expect(TrainingPlan.earlyEntries(plan, plan.exits[0]).map(EarlyEntry.summary)).toEqual(['встала → сразу'])
    expect(TrainingPlan.earlyEntries(plan, plan.exits[1])).toHaveLength(2)

    // Changed for one exit: its own copy, the common ones stay.
    plan = TrainingPlan.detachEarlyEntries(plan, 1)
    const own = plan.exits[1].earlyEntries
    plan = { ...plan, exits: [plan.exits[0], { ...plan.exits[1], earlyEntries: [own[0], { ...own[1], delay: 40 }] }] }
    expect(TrainingPlan.usesCommonEarlyEntries(plan, plan.exits[1])).toBe(false)
    expect(TrainingPlan.earlyEntries(plan, plan.exits[1]).map(EarlyEntry.summary)).toEqual(['встала и пошла → 0:15', 'легла → 0:40'])
    expect(plan.commonEarlyEntries[1].delay).toBe(30)
    expect(TrainingPlan.changes(plan, plan)).toHaveLength(0)

    const second = plan.exits[1]
    const edited = {
      ...plan,
      exits: [
        plan.exits[0],
        { ...second, triggers: ['куртка'], note: 'Ключами звякнуть за дверью', earlyEntries: second.earlyEntries.slice(0, -1) },
      ],
    }
    expect(TrainingPlan.changes(edited, plan)).toEqual(['выход 2: триггеры', 'выход 2: ранний вход', 'выход 2: заметка'])
  })

  it('reads the false start window from the rule', () => {
    const plan = TrainingPlan.make({ exits: [PlannedExit.make({ number: 1, duration: 300 })] })
    expect(TrainingPlan.falseStartWindow(plan)).toBeNull()
    const window = (note: string) => TrainingPlan.falseStartWindow({ ...plan, notes: [note] })
    expect(window('Фальстарт: если пошла к двери в первые 20 секунд длинного выхода - сразу возвращаемся')).toBe(20)
    expect(window('Фальстарт: если в течение первых 1,5 минут пошла к двери — возвращаемся')).toBe(90)
    expect(window('False start: if she goes to the door in the first 30 seconds, come back')).toBe(30)
    expect(window('Фальстарт: если пошла к двери — сразу возвращаемся')).toBeNull()
    // Not in the Swift test: the trainer's 🔖 in front, and «первые» in a note that isn't the rule.
    expect(window('🔖 Фальстарт: если пошла к двери в первые 20 секунд длинного выхода')).toBe(20)
    expect(window('Первые 20 секунд не смотреть на собаку')).toBeNull()
  })

  it('reads a plan from an older build', () => {
    // A plan saved before conditions: «🟡 Если встала…» among the notes, no triggers or conditions in the exits.
    const json = `{"id":"${newUUID()}","title":"Тренировка","trainers":"","notes":["Все перерывы 2 минуты",
      "Если встала - входим через 15 секунд от вставания"],"defaultBreak":120,"rawText":"",
      "exits":[{"id":"${newUUID()}","number":1,"duration":30,"untilStanding":true}]}`
    const plan = TrainingPlan.decode(JSON.parse(json), DISK_DATES)
    expect(plan.notes).toEqual(['Все перерывы 2 минуты'])
    expect(plan.commonEarlyEntries.map(EarlyEntry.summary)).toEqual(['встала → 0:15'])
    expect(TrainingPlan.earlyEntries(plan, plan.exits[0]).map((entry) => entry.detail)).toEqual(['от вставания'])
    expect(plan.exits[0].triggers).toEqual([])
    expect(plan.exits[0].usesCommonEarlyEntries).toBe(true)

    const again = TrainingPlan.decode(JSON.parse(JSON.stringify(TrainingPlan.encode(plan, DISK_DATES))), DISK_DATES)
    expect(again).toEqual(plan)
  })

  it('repeats the exit after a false start', () => {
    const session = makeSession()
    session.markBehindDoor()
    advance(1)
    session.resetExit()

    expect(session.results).toHaveLength(1)
    expect(session.results[0].falseStart).toBe(true)
    expect(session.attempt).toBe(2)
    const phase = session.phase
    if (phase.kind !== 'breakTime') throw new Error('expected break')
    expect(phase.nextExitIndex).toBe(0)

    session.markBehindDoor() // early, before the break ends
    expect(session.phase).toEqual({ kind: 'away', exitIndex: 0, since: now, leftAt: now })
    expect(session.events.filter((e) => e.kind === 'breakEnded')).toHaveLength(1)
    session.endExit()
    expect(session.results[1].attempt).toBe(2)
    expect(session.attempt).toBe(1)
    expect(session.currentExitIndex).toBe(1)
  })

  it('closes the exit when finished while outside', () => {
    const session = makeSession()
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
    session.markBehindDoor(); advance(5); session.endExit(); session.finish()
    const record = session.makeRecord('video.mp4')
    const text = SessionLogFormatter.text(record)
    expect(text, 'the file name is no use to the trainer').not.toContain('video.mp4')
    expect(text).toContain('1 выход — 5 с: за дверью 0:05 ✅')
    expect(text, 'the break after the last exit only ends the session').not.toContain('перерыв')
  })

  it('log formatter writes one line per attempt', () => {
    const session = makeSession()
    session.markBehindDoor(); advance(2); session.resetExit()
    advance(60); session.markBehindDoor(); advance(5); session.endExit()
    advance(120); session.tick()
    session.markBehindDoor(); advance(30); session.endExit(); session.finish()
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

    session.markBehindDoor() // phase + log: one notification
    expect(seen).toHaveLength(1)
    expect(seen[0]).toBe(session.snapshot)
    expect(before.phase).toEqual({ kind: 'ready', exitIndex: 0 })
    expect(before.events).toHaveLength(1)

    now += 6000
    session.endExit() // results + log + break: one notification
    expect(seen).toHaveLength(2)
    session.endExit() // not outside: nothing changes
    expect(seen).toHaveLength(2)

    unsubscribe()
    session.finish()
    expect(seen).toHaveLength(2)
    expect(session.isFinished).toBe(true)
  })

  it('computes countdowns from a snapshot alone', () => {
    let now = 0
    const plan = TrainingPlan.make({ exits: [PlannedExit.make({ number: 1, duration: 10 })] })
    const session = new TrainingSession(plan, { clock: () => now })
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
    session.markBehindDoor(); now += 5000; session.endExit()
    now += 30_000
    session.addNote('Лаяла')
    session.markBehindDoor()
    const kinds = session.events.map((e) => e.kind)
    expect(kinds).toEqual([
      'sessionStarted', 'recordingStarted', 'behindDoor', 'exitEnded', 'breakStarted', 'note', 'breakEnded',
      'behindDoor',
    ])
    expect(session.events[1].detail).toBe('a.mp4')
    expect(session.events[2].detail).toBe('план 5 с')
    expect(session.events[3].detail).toBe('за дверью 0:05, всего 0:05')
    expect(session.events[4].detail).toBe('план 2 мин')
    expect(session.events[5]).toMatchObject({ exitNumber: 2, detail: 'Лаяла' })
    expect(session.events[6].detail).toBe('досрочно, 0:30 из 2 мин')
    expect(session.events[7]).toMatchObject({ exitNumber: 2, attempt: 1 })
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
