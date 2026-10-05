// Port of EnglishTests.swift: the app in English (every device language other than Russian): schedules,
// durations, the trainer's log.
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  DurationText,
  PlanParser,
  PlannedExit,
  SessionLogFormatter,
  TrainingPlan,
  TrainingSession,
  setCoreLanguage,
} from '@core/index'

const sample = `🐶 Monday training - Anna/Andrew - 25.10.2026
➡️ All breaks 2 minutes
Exit 1 - 5 seconds
Exit 2 - 10 seconds
Break 5 minutes
3rd exit - 30 seconds OR until the dog stands up
Exit 4 - 0 seconds (step out and come right back)
Stay calm at the door.`

describe('English', () => {
  beforeEach(() => setCoreLanguage('en'))
  afterEach(() => setCoreLanguage('ru'))

  it('parses an English schedule', () => {
    const plan = PlanParser.parse(sample)
    expect(plan.title).toBe('Monday training')
    expect(plan.trainers).toBe('Anna/Andrew')
    expect(plan.date).not.toBeNull()
    expect(plan.defaultBreak).toBe(120)
    expect(plan.exits.map((e) => e.number)).toEqual([1, 2, 3, 4])
    expect(plan.exits.map((e) => e.duration)).toEqual([5, 10, 30, 0])
    expect(plan.exits[1].breakAfter).toBe(300)
    expect(plan.exits[2].untilStanding).toBe(true)
    expect(plan.exits[0].untilStanding).toBe(false)
    expect(plan.exits[3].note).toBe('step out and come right back')
    expect(plan.notes).toEqual(['All breaks 2 minutes', 'Stay calm at the door.'])
  })

  it('reads dotted dates day first in English too', () => {
    const plan = PlanParser.parse('Sunday training - Anna - 04.10.2026\nExit 1 - 5 seconds')
    const date = new Date(plan.date!)
    expect(date.getDate()).toBe(4)
    expect(date.getMonth() + 1).toBe(10)
  })

  it('still parses a Russian schedule in the English UI', () => {
    const plan = PlanParser.parse('Тренировка\nВсе перерывы 3 минуты\n1 выход - 5 секунд\n2 выход - 1 минута ИЛИ до вставания')
    expect(plan.exits.map((e) => e.duration)).toEqual([5, 60])
    expect(plan.exits[1].untilStanding).toBe(true)
    expect(plan.defaultBreak).toBe(180)
  })

  it('does not cut the duration at words containing "or"', () => {
    const exit = PlanParser.parseExit('Exit 1 - 30 seconds (door closed)')
    expect(exit?.duration).toBe(30)
    expect(exit?.note).toBe('door closed')
  })

  it('formats and parses durations', () => {
    expect(DurationText.short(90)).toBe('1 min 30 s')
    expect(DurationText.short(3_660)).toBe('1 h 1 min')
    expect(DurationText.compact(90)).toBe('1m30')
    expect(DurationText.parse('2 minutes')).toBe(120)
    expect(DurationText.parse('1 min 30 sec')).toBe(90)
    expect(TrainingPlan.make().title).toBe('Training')
  })

  it('writes the trainer log in English', () => {
    let now = 1_000_000_000
    const plan = TrainingPlan.make({
      exits: [PlannedExit.make({ number: 1, duration: 5 }), PlannedExit.make({ number: 2, duration: 30, untilStanding: true })],
    })
    const session = new TrainingSession(plan, { clock: () => now })
    session.startExit(); session.markBehindDoor(); now += 2000; session.resetExit()
    now += 60_000; session.startExit(); session.markBehindDoor(); now += 5000; session.endExit()
    now += 120_000; session.tick()
    session.startExit(); session.markBehindDoor(); now += 30_000; session.endExit(); session.finish()
    const text = SessionLogFormatter.text(session.makeRecord(null))
    const lines = text.split('\n').filter((line) => line.startsWith('Exit '))
    expect(lines).toEqual([
      'Exit 1 — 5 s: false start, outside 0:02 ❌ · break 1:00 (plan 2 min)',
      'Exit 1 — 5 s, attempt 2: outside 0:05 ✅ · break 2:00',
      'Exit 2 — 30 s or until the dog stands: outside 0:30 ✅',
    ])
    expect(text).toContain('exits 2 of 2 · false starts 1')
  })
})
