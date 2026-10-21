// The schedule review dialog's pure logic: the trainer's text line by line, highlighting, the exit ↔ line link,
// the plan wording and the table edits (port of MacPlanSupport / MacPlanReviewSheet behaviour).
import { beforeEach, describe, expect, it } from 'vitest'
import { PlanParser, PlannedExit, TrainingPlan, setCoreLanguage } from '@core/index'
import { setLanguage } from '@shared/i18n'
import {
  PlanFormat,
  addExit,
  canDelete,
  canShift,
  dateFromInput,
  dateInputValue,
  deleteExits,
  duplicateExits,
  moveExits,
  moveOffsets,
  ownBreaks,
  resetOwnBreaks,
  setBreakAfter,
  setDefaultBreak,
  shiftExits,
  stepDuration,
  withMinutes,
  withSeconds,
} from '../src/renderer/src/plan/planEdit'
import { classifyLines, exitForLine, exitLines, highlightLine, linkedLines } from '../src/renderer/src/plan/planText'
import { DraftSync } from '../src/renderer/src/plan/draftSync'

const demo = `🐹 Тренировка на воскресенье - Таня/Андрей - 04.10.2026

➡️ Второго человека уводим из квартиры минимум за 30-40 минут до начала тренировки
➡️ За 30-60 минут включить музыку, отпереть дверь изнутри, закрыть окна
➡️ В перерывах сидите за столом, работаете
➡️ Все перерывы 2 минуты

1 выход - 10 секунд
2 выход - 30 секунд
3 выход - 15 секунд
4 выход - 1 минута
5 выход - 45 секунд
6 выход - 2 минуты ИЛИ до вставания
Перерыв 5 минут
7 выход - 30 секунд
8 выход - 3 минуты ИЛИ до вставания
9 выход - 1 минута

🔖 Фальстарт: если пошла к двери во время длинного выхода - сразу возвращаемся

`

function plan(durations: number[], extra: Partial<TrainingPlan> = {}): TrainingPlan {
  return TrainingPlan.make({ exits: durations.map((duration, index) => PlannedExit.make({ number: index + 1, duration })), ...extra })
}

beforeEach(() => {
  setCoreLanguage('ru')
  setLanguage('ru')
})

describe('the trainer’s text', () => {
  it('classifies every line as the parser read it', () => {
    const lines = classifyLines(demo)
    expect(lines).toHaveLength(19)
    const kinds = lines.map((line) => line.kind.kind)
    expect(kinds).toEqual([
      'header', 'blank', 'note', 'note', 'note', 'defaultBreak', 'blank',
      'exit', 'exit', 'exit', 'exit', 'exit', 'exit', 'ownBreak', 'exit', 'exit', 'exit', 'blank', 'rule',
    ])
    expect(lines[7].kind).toEqual({ kind: 'exit', number: 1, ordinal: 0 })
    expect(lines[13].kind).toEqual({ kind: 'ownBreak', afterLine: 13 })
    expect(lines[16].kind).toEqual({ kind: 'exit', number: 9, ordinal: 8 })
  })

  it('counts a Windows line break (CRLF) as one', () => {
    const lines = classifyLines(demo.replace(/\n/g, '\r\n'))
    expect(lines).toHaveLength(19)
    expect(lines[13]).toMatchObject({ id: 14, kind: { kind: 'ownBreak', afterLine: 13 } })
  })

  it('highlights labels, durations and «до вставания» on exit lines', () => {
    const lines = classifyLines(demo)
    const runs = highlightLine(lines[12])
    expect(runs.map((run) => run.text).join('')).toBe('6 выход - 2 минуты ИЛИ до вставания')
    expect(runs.find((run) => run.role === 'label')?.text).toBe('6 выход')
    expect(runs.find((run) => run.role === 'duration')?.text).toBe('2 минуты')
    expect(runs.find((run) => run.role === 'flag')?.text).toBe('ИЛИ до вставания')
    expect(highlightLine(lines[13]).every((run) => run.role === 'pause')).toBe(true)
    expect(highlightLine(lines[0])[0]).toEqual({ text: '🐹 Тренировка на воскресенье', role: 'title' })
    expect(highlightLine(lines[18])[0]).toEqual({ text: '🔖 Фальстарт:', role: 'rule' })
    expect(highlightLine(lines[1])).toEqual([])
  })

  it('highlights English schedules too', () => {
    const [line] = classifyLines('Training\nExit 6 - 2 minutes OR until the dog stands up').slice(1)
    const runs = highlightLine(line)
    expect(runs.find((run) => run.role === 'label')?.text).toBe('Exit 6')
    expect(runs.find((run) => run.role === 'duration')?.text).toBe('2 minutes')
    expect(runs.find((run) => run.role === 'flag')?.text).toBe('OR until the dog stands up')
  })

  it('links exits to their lines and keeps the link after edits', () => {
    const parsed = PlanParser.parse(demo)
    const lines = classifyLines(parsed.rawText)
    const map = exitLines(parsed, lines)
    expect(parsed.exits.map((exit) => map.get(exit.id))).toEqual([8, 9, 10, 11, 12, 13, 15, 16, 17])
    // Reordered and one added by hand: the cached link follows the ids.
    const edited = addExit(moveExits(parsed, [parsed.exits[8].id], 0), []).plan
    const again = exitLines(edited, lines)
    expect(edited.exits.map((exit) => again.get(exit.id) ?? null)).toEqual([17, 8, 9, 10, 11, 12, 13, 15, 16, null])
    // The own break line follows the selected exit; clicking it selects that exit.
    const sixth = parsed.exits[5].id
    expect([...linkedLines(lines, map, [sixth])].sort()).toEqual([13, 14])
    expect(exitForLine(lines[13], parsed, map)).toBe(sixth)
    expect(exitForLine(lines[2], parsed, map)).toBeNull()
  })

  it('marks conditions under exits, common ones and the «не входить» rule', () => {
    const text = `1 выход - 5 секунд
2 выход - 4 минуты + обувь
🟡 Если встала - входим через 1 минуту

🟢 Если легла - входим через 20 секунд
🚩 Если залаяла - ни в коем случае не входить`
    const lines = classifyLines(text)
    expect(lines[2].kind).toEqual({ kind: 'earlyEntry', tone: 'yellow', afterLine: 2 })
    expect(lines[4].kind).toEqual({ kind: 'earlyEntry', tone: 'green', afterLine: null })
    expect(lines[5].kind).toEqual({ kind: 'doNotEnter' })
    const parsed = PlanParser.parse(text)
    const map = exitLines(parsed, lines)
    expect([...linkedLines(lines, map, [parsed.exits[1].id])].sort()).toEqual([2, 3])
    expect(exitForLine(lines[2], parsed, map)).toBe(parsed.exits[1].id)
    expect(exitForLine(lines[4], parsed, map)).toBeNull()
    expect(highlightLine(lines[1]).find((run) => run.role === 'trigger')?.text).toBe('обувь')
    expect(highlightLine(lines[2]).find((run) => run.role === 'delay')?.text).toBe('1 минуту')
  })

  it('follows the parser’s lines through blank rows at the top, CRLF and a bullet in the middle of a row', () => {
    const text = '\r\nТренировка\r\nДелаем вечером➡️ За 30 минут включить музыку\r\n3 выход - 5 секунд\r\n🟢 Если легла - входим через 20 секунд'
    const lines = classifyLines(text)
    expect(lines.map((line) => line.kind.kind)).toEqual(['blank', 'header', 'note', 'exit', 'earlyEntry'])
    expect(lines[4].kind).toEqual({ kind: 'earlyEntry', tone: 'green', afterLine: 4 })
  })

  it('matches by the written number when the plan was edited before the first look', () => {
    const parsed = PlanParser.parse('Тренировка\n1 выход - 5 секунд\n2 выход - 10 секунд\n3 выход - 15 секунд')
    const edited = { ...parsed, id: 'EDITED', exits: parsed.exits.slice(1) }
    const map = exitLines(edited, classifyLines(parsed.rawText))
    expect(edited.exits.map((exit) => map.get(exit.id))).toEqual([3, 4])
  })
})

describe('plan wording', () => {
  it('formats cells, summaries and deltas', () => {
    expect(PlanFormat.cell(90)).toBe('1:30')
    expect(PlanFormat.cell(120)).toBe('2 мин')
    expect(PlanFormat.cell(45)).toBe('45 с')
    expect(PlanFormat.approx(1690)).toBe('≈ 28 мин')
    expect(PlanFormat.approx(130)).toBe('≈ 2 мин 10 с')
    expect(PlanFormat.signed(30)).toBe('+0:30')
    expect(PlanFormat.signed(-60)).toBe('−1:00')
    expect(PlanFormat.exits(5)).toBe('5 выходов')
    expect(PlanFormat.breaks(2)).toBe('2 перерыва')
    expect(PlanFormat.notes(1)).toBe('1 заметка')
    expect(PlanFormat.capitalizedFirst(PlanFormat.list(['9 выходов', '2 перерыва', 'правило фальстарта']))).toBe('9 выходов, 2 перерыва и правило фальстарта')
    expect(PlanFormat.ruleBody('Фальстарт: если пошла к двери')).toBe('Если пошла к двери')
    expect(PlanFormat.ruleBody('Фальстарт — без двоеточия')).toBe('Фальстарт — без двоеточия')
  })

  it('computes start times and totals', () => {
    const parsed = PlanParser.parse(demo)
    expect(PlanFormat.start(0, parsed)).toBe(0)
    expect(PlanFormat.start(1, parsed)).toBe(130)
    expect(PlanFormat.start(6, parsed)).toBe(19 * 60 + 40)
    expect(PlanFormat.exitsTotal(parsed)).toBe(550)
    expect(PlanFormat.breaksTotal(parsed)).toBe(19 * 60)
  })
})

describe('table edits', () => {
  it('adds an exit after the selection with the duration of the exit above', () => {
    const base = plan([10, 30, 60])
    const edit = addExit(base, [base.exits[1].id])
    expect(edit.plan.exits.map((exit) => exit.duration)).toEqual([10, 30, 30, 60])
    expect(edit.plan.exits.map((exit) => exit.number)).toEqual([1, 2, 3, 4])
    expect(edit.selection).toEqual([edit.plan.exits[2].id])
    expect(addExit(base, []).plan.exits.map((exit) => exit.duration)).toEqual([10, 30, 60, 60])
    expect(addExit(plan([]), []).plan.exits.map((exit) => exit.duration)).toEqual([30])
  })

  it('duplicates the selection with new ids right after it', () => {
    const base = plan([10, 30, 60])
    const edit = duplicateExits(base, [base.exits[0].id, base.exits[1].id])!
    expect(edit.plan.exits.map((exit) => exit.duration)).toEqual([10, 30, 10, 30, 60])
    expect(new Set(edit.plan.exits.map((exit) => exit.id)).size).toBe(5)
    expect(edit.selection).toEqual([edit.plan.exits[2].id, edit.plan.exits[3].id])
    expect(edit.selection.every((id) => /^[0-9A-F-]{36}$/.test(id))).toBe(true)
    expect(duplicateExits(base, [])).toBeNull()
  })

  it('deletes but keeps at least one exit, selecting the next row', () => {
    const base = plan([10, 30, 60])
    const edit = deleteExits(base, [base.exits[1].id])!
    expect(edit.plan.exits.map((exit) => exit.duration)).toEqual([10, 60])
    expect(edit.plan.exits.map((exit) => exit.number)).toEqual([1, 2])
    expect(edit.selection).toEqual([base.exits[2].id])
    expect(deleteExits(base, [base.exits[2].id])!.selection).toEqual([base.exits[1].id])
    expect(deleteExits(base, base.exits.map((exit) => exit.id))).toBeNull()
    expect(canDelete(base, base.exits.map((exit) => exit.id))).toBe(false)
    expect(canDelete(base, ['unknown'])).toBe(false)
  })

  it('moves like Swift’s move(fromOffsets:toOffset:)', () => {
    expect(moveOffsets(['a', 'b', 'c', 'd'], [0], 2)).toEqual(['b', 'a', 'c', 'd'])
    expect(moveOffsets(['a', 'b', 'c', 'd'], [3], 0)).toEqual(['d', 'a', 'b', 'c'])
    expect(moveOffsets(['a', 'b', 'c', 'd'], [0, 1], 4)).toEqual(['c', 'd', 'a', 'b'])
    expect(moveOffsets(['a', 'b', 'c', 'd'], [1, 3], 1)).toEqual(['a', 'b', 'd', 'c'])
    const base = plan([10, 20, 30])
    expect(moveExits(base, [base.exits[0].id], 3).exits.map((exit) => [exit.number, exit.duration])).toEqual([
      [1, 20],
      [2, 30],
      [3, 10],
    ])
    expect(moveExits(base, [base.exits[0].id], 1)).toBe(base)
  })

  it('shifts the selection up and down', () => {
    const base = plan([10, 20, 30])
    expect(shiftExits(base, [base.exits[1].id], -1)!.exits.map((exit) => exit.duration)).toEqual([20, 10, 30])
    expect(shiftExits(base, [base.exits[1].id], 1)!.exits.map((exit) => exit.duration)).toEqual([10, 30, 20])
    expect(shiftExits(base, [base.exits[0].id, base.exits[1].id], 1)!.exits.map((exit) => exit.duration)).toEqual([30, 10, 20])
    expect(canShift(base, [base.exits[0].id], -1)).toBe(false)
    expect(canShift(base, [base.exits[2].id], 1)).toBe(false)
    expect(shiftExits(base, [base.exits[2].id], 1)).toBeNull()
  })

  it('keeps own breaks only where they differ from the common break', () => {
    const base = plan([10, 20, 30, 40])
    const own = { ...base, exits: base.exits.map((exit, index) => (index === 0 ? { ...exit, breakAfter: 300 } : index === 1 ? { ...exit, breakAfter: 60 } : exit)) }
    expect(ownBreaks(own).map((exit) => exit.number)).toEqual([1, 2])
    const common = setDefaultBreak(own, 300)
    expect(common.defaultBreak).toBe(300)
    expect(common.exits.map((exit) => exit.breakAfter)).toEqual([null, 60, null, null])
    expect(resetOwnBreaks(own).exits.every((exit) => exit.breakAfter === null)).toBe(true)
    expect(setBreakAfter(own, own.exits[1].id, 120).exits[1].breakAfter).toBeNull()
    expect(setBreakAfter(own, own.exits[2].id, 90).exits[2].breakAfter).toBe(90)
    // The last exit's break never plays: not an own break.
    const last = { ...base, exits: base.exits.map((exit, index) => (index === 3 ? { ...exit, breakAfter: 300 } : exit)) }
    expect(ownBreaks(last)).toEqual([])
  })

  it('converts the schedule date for the date picker (noon, local time)', () => {
    const noon = new Date(2026, 9, 4, 12).getTime()
    expect(dateInputValue(noon)).toBe('2026-10-04')
    expect(dateFromInput('2026-10-04')).toBe(noon)
    expect(dateFromInput('')).toBeNull()
  })

  it('steps durations like the Mac editor', () => {
    expect(stepDuration(55, 1)).toBe(60)
    expect(stepDuration(60, 1)).toBe(90)
    expect(stepDuration(90, -1)).toBe(60)
    expect(stepDuration(60, -1)).toBe(55)
    expect(stepDuration(3, -1)).toBe(0)
    expect(withMinutes(95, 3)).toBe(215)
    expect(withMinutes(95, 500)).toBe(120 * 60 + 35)
    expect(withSeconds(95, 10)).toBe(70)
    expect(withSeconds(95, 75)).toBe(119)
  })
})

describe('draft sync', () => {
  it('skips echoes and stale states, takes changes from elsewhere', () => {
    const sync = new DraftSync('P0')
    sync.send('A')
    sync.send('B')
    expect(sync.receive('P0')).toBe('keep') // pushed for another reason before our edits arrived
    expect(sync.receive('A')).toBe('keep')
    expect(sync.receive('P0')).toBe('replace') // the backend's value really changed back
    sync.send('C')
    sync.send('D')
    expect(sync.receive('D')).toBe('keep') // coalesced echo
    expect(sync.pending).toBe(0)
    expect(sync.receive('D')).toBe('keep')
    expect(sync.receive('E')).toBe('replace')
  })
})
