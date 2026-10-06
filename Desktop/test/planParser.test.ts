// Port of PlanParserTests.swift.
import { beforeEach, describe, expect, it } from 'vitest'
import { DurationText, PlanParser, TrainingPlan, setCoreLanguage, setCoreRegion } from '@core/index'

const sampleWithDefaultBreaks = `🐹 Тренировка на понедельник - Таня/Андрей - 05.10.2026

➡️ Второго человека уводим из квартиры минимум за 30-40 минут до начала тренировки с обязательным сокрытием ухода. Вернуться можно минимум через 20-30 минут после окончания тренировки
➡️ За 30-60 минут включить музыку, отпереть дверь изнутри, закрыть окна
➡️ В перерывах сидите за столом, работаете
➡️ Все перерывы 2 минуты

1 выход - 5 секунд
2 выход - 10 секунд
3 выход - 5 секунд
4 выход - 15 секунд
5 выход - 30 секунд ИЛИ до вставания
6 выход - 10 секунд
7 выход - 1 минута ИЛИ до вставания

🔖 Фальстарт: если пошла к двери во время длинного выхода или если при выходе вы услышали звуки, на которые она будет реагировать - сразу возвращаемся, через обычный перерыв снова идём на длинный выход. Если на третьей попытке выхода снова зафальстартила - завершаем тренировку`

const sampleWithExplicitBreaks = `🐹 Тренировка на пятницу - Андрей - 25.09.2026

➡️ За 30-60 минут включить музыку, отпереть дверь изнутри, закрыть окна
➡️ В перерывах сидите за столом, работаете
➡️ Второй человек сидит за столом, работает. Дверь к нему открыта

1 выход - 0 секунд (выйти и сразу вернуться)
Перерыв 2 минуты
2 выход - 2 секунды
Перерыв 2 минуты
3 выход - 2 секунды
Перерыв 5 минут
4 выход - 2 секунды
Перерыв 2 минуты
5 выход - 5 секунд
Перерыв 2 минуты
6 выход - 5 секунд
Перерыв 5 минут
7 выход - 2 секунды
Перерыв 2 минуты
8 выход - 5 секунд
Перерыв 2 минуты
9 выход - 20 секунд ИЛИ до вставания`

describe('PlanParser (Russian)', () => {
  // These tests check the Russian texts (the default language of the app's first users).
  beforeEach(() => setCoreLanguage('ru'))

  it('parses the sample with default breaks', () => {
    const plan = PlanParser.parse(sampleWithDefaultBreaks)

    expect(plan.title).toBe('Тренировка на понедельник')
    expect(plan.trainers).toBe('Таня/Андрей')
    expect(plan.date === null ? null : TrainingPlan.formatDate(plan.date)).toBe('05.10.2026')
    expect(plan.defaultBreak).toBe(120)
    expect(plan.exits).toHaveLength(7)
    expect(plan.exits.map((e) => e.duration)).toEqual([5, 10, 5, 15, 30, 10, 60])
    expect(plan.exits.map((e) => e.untilStanding)).toEqual([false, false, false, false, true, false, true])
    expect(plan.exits.every((e) => e.breakAfter === null)).toBe(true)
    expect(TrainingPlan.breakAfter(plan, 3)).toBe(120)
    expect(plan.notes).toHaveLength(5)
    expect(plan.notes.at(-1)?.startsWith('Фальстарт')).toBe(true)
  })

  it('parses the sample with explicit breaks', () => {
    const plan = PlanParser.parse(sampleWithExplicitBreaks)

    expect(plan.title).toBe('Тренировка на пятницу')
    expect(plan.trainers).toBe('Андрей')
    expect(plan.exits).toHaveLength(9)
    expect(plan.exits[0].duration).toBe(0)
    expect(plan.exits[0].note).toBe('выйти и сразу вернуться')
    // "Перерыв 2 минуты" after most exits becomes the plan's break; only the 5-minute ones stay per exit.
    expect(plan.defaultBreak).toBe(120)
    expect(plan.exits.map((e) => e.breakAfter)).toEqual([null, null, 300, null, null, 300, null, null, null])
    expect(TrainingPlan.breakAfter(plan, 0)).toBe(120)
    expect(plan.exits[8].duration).toBe(20)
    expect(plan.exits[8].untilStanding).toBe(true)
    expect(plan.exits[8].breakAfter).toBeNull()
    expect(plan.notes).toHaveLength(3)
  })

  it('keeps the default when a single explicit break is given', () => {
    const plan = PlanParser.parse(`1 выход - 5 секунд
2 выход - 10 секунд
Перерыв 5 минут
3 выход - 5 секунд
4 выход - 5 секунд`)
    expect(plan.defaultBreak).toBe(TrainingPlan.defaultBreakDuration)
    expect(plan.exits.map((e) => e.breakAfter)).toEqual([null, 300, null, null])
  })

  it('makes a break equal to the stated default follow the default', () => {
    const plan = PlanParser.parse(`➡️ Все перерывы 3 минуты
1 выход - 5 секунд
Перерыв 3 минуты
2 выход - 10 секунд
Перерыв 5 минут
3 выход - 5 секунд`)
    expect(plan.defaultBreak).toBe(180)
    expect(plan.exits.map((e) => e.breakAfter)).toEqual([null, 300, null])
  })

  it('understands alternative spellings', () => {
    const plan = PlanParser.parse(`Тренировка
Выход 1 — 1 мин 30 сек
Выход №2: 2 минуты или до вставания`)
    expect(plan.exits).toHaveLength(2)
    expect(plan.exits[0].duration).toBe(90)
    expect(plan.exits[1].duration).toBe(120)
    expect(plan.exits[1].untilStanding).toBe(true)
  })

  it('formats and parses durations', () => {
    expect(DurationText.parse('15 с')).toBe(15)
    expect(DurationText.parse('2 минуты')).toBe(120)
    expect(DurationText.parse('1:30')).toBe(90)
    expect(DurationText.parse('90')).toBe(90)
    expect(DurationText.parse('1,5 минуты')).toBe(90)
    expect(DurationText.parse('до вставания')).toBeNull()
    expect(DurationText.short(90)).toBe('1 мин 30 с')
    expect(DurationText.short(0)).toBe('0 с')
    expect(DurationText.clock(-12)).toBe('−0:12')
    expect(DurationText.clock(3725)).toBe('1:02:05')
  })
})

// Not in the Swift suite: details of the port that the cases above do not reach.
describe('PlanParser details', () => {
  beforeEach(() => {
    setCoreLanguage('ru')
    setCoreRegion('RU')
  })

  it('puts the schedule date at noon local time', () => {
    const plan = PlanParser.parse('Тренировка - Аня - 05.10.26\n1 выход - 5 секунд')
    const date = new Date(plan.date!)
    expect([date.getFullYear(), date.getMonth() + 1, date.getDate(), date.getHours()]).toEqual([2026, 10, 5, 12])
    expect(plan.trainers).toBe('Аня')
    expect(TrainingPlan.displayTitle(plan)).toBe('05.10.2026 · Тренировка')
  })

  it('a month above 12 settles the order', () => {
    const date = PlanParser.extractDate('10/25/2026')!
    expect(new Date(date.date).getMonth() + 1).toBe(10)
    expect(new Date(date.date).getDate()).toBe(25)
  })

  it('treats a bare number with ordinal and dash forms as exits', () => {
    expect(PlanParser.parseExit('Departure #3 - 1 hour')?.duration).toBe(3600)
    expect(PlanParser.parseExit('3. выход: 1:30')?.number).toBe(3)
    expect(PlanParser.parseExit('Перерыв 5 минут')).toBeNull()
  })

  it('recognises break lines like ICU word boundaries', () => {
    expect(PlanParser.commonBreak('all breaks 2 minutes')).toBe(120)
    expect(PlanParser.commonBreak('breakfast 2 minutes')).toBeNull()
    expect(PlanParser.commonBreak('ébreak 2 minutes')).toBeNull()
    expect(PlanParser.isExitBreak('rest 2 minutes')).toBe(true)
    expect(PlanParser.isExitBreak('breaks 2 minutes')).toBe(false)
  })

  // The schedule of 06.10.2026: the false-start rule names a time («первые 20 секунд») and mentions «обычный
  // перерыв», and every break of the training became 20 s instead of «Все перерывы 2 минуты».
  it('does not take other times in the notes for the break', () => {
    const plan = PlanParser.parse(`🐹 Тренировка на вторник - Таня - 06.10.2026

➡️ Второго человека уводим из квартиры минимум за 30-40 минут до начала тренировки с обязательным сокрытием ухода. Вернуться можно минимум через 20-30 минут после окончания тренировки
➡️ За 30-60 минут включить музыку, отпереть дверь изнутри, закрыть окна
➡️ В перерывах сидите за столом, работаете
➡️ Все перерывы 2 минуты

1 выход - 5 секунд
2 выход - 10 секунд
3 выход - 5 секунд
4 выход - 15 секунд
5 выход - 30 секунд ИЛИ до вставания
6 выход - 10 секунд
7 выход - 3 минуты

🟡 Если встала - входим через 15 секунд от вставания

🔖 Фальстарт: если пошла к двери в первые 20 секунд длинного выхода или если при выходе вы услышали звуки, на которые она будет реагировать - сразу возвращаемся, через обычный перерыв снова идём на длинный выход. Если на третьей попытке выхода снова зафальстартила - завершаем тренировку`)
    expect(plan.defaultBreak).toBe(120)
    expect(plan.exits.every((exit) => exit.breakAfter === null)).toBe(true)
    expect(plan.exits.map((exit) => exit.duration)).toEqual([5, 10, 5, 15, 30, 10, 180])
  })

  it('reads the common break only where the time belongs to it', () => {
    expect(PlanParser.commonBreak('Все перерывы 2 минуты')).toBe(120)
    expect(PlanParser.commonBreak('Перерывы между выходами — 1 мин. 30 сек.')).toBe(90)
    expect(PlanParser.commonBreak('Все перерывы по 1,5 минуты')).toBe(90)
    expect(PlanParser.commonBreak('Все перерывы 2 минуты, после пятого выхода 5 минут')).toBe(120)
    expect(PlanParser.commonBreak('Between exits: 2 minute breaks')).toBe(120)
    expect(PlanParser.commonBreak('All breaks are 3 minutes')).toBe(180)
    // A time in the same sentence that is not the break's.
    expect(PlanParser.commonBreak('Если лает дольше 10 секунд, в перерыве не подходим')).toBeNull()
    expect(PlanParser.commonBreak('Через обычный перерыв снова идём на длинный выход, он длится 30 секунд')).toBeNull()
    expect(PlanParser.commonBreak('Фальстарт: возвращаемся, перерыв 5 минут и снова на длинный выход')).toBeNull()
    expect(PlanParser.commonBreak('В перерывах сидите за столом, работаете')).toBeNull()
    expect(PlanParser.commonBreak('Breakfast 30 minutes before the training')).toBeNull()
  })

  it('rounds half away from zero like Swift', () => {
    expect(DurationText.short(2.5)).toBe('3 с')
    expect(DurationText.short(-2.5)).toBe('−3 с')
    expect(DurationText.compact(90)).toBe('1м30')
    expect(DurationText.compact(300)).toBe('5м')
    expect(DurationText.clock(-0.5)).toBe('−0:01')
  })

  it('renumbers and estimates plans', () => {
    const plan = PlanParser.parse('3 выход - 10 секунд\n7 выход - 20 секунд\nПерерыв 5 минут\n9 выход - 30 секунд')
    expect(TrainingPlan.renumbered(plan).exits.map((e) => e.number)).toEqual([1, 2, 3])
    expect(TrainingPlan.estimatedDuration(plan)).toBe(10 + 120 + 20 + 300 + 30)
    expect(plan.rawText).toContain('3 выход')
  })
})
