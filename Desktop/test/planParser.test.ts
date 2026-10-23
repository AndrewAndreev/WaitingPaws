// Port of PlanParserTests.swift.
import { beforeEach, describe, expect, it } from 'vitest'
import { DurationText, EarlyEntry, PlanParser, TrainingPlan, setCoreLanguage, setCoreRegion } from '@core/index'

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

  // The triggering session of 19.10.2026: triggers after «+», an exit written as a sentence, the conditions once
  // after all exits, two notes in one line.
  it('parses the triggering schedule', () => {
    const plan = PlanParser.parse(`🐹 ТРИГГЕРОВКА на понедельник - 19.10.2026
Делаем через 1-1,5 часа и позже после основной тренировки, но не не поздно вечером➡️ За 30 минут включить музыку, открыть дверь изнутри, положить лежанку в коридор, положить/повесить куртку на виду у Мии
➡️ В перерывах сидите за столом, работаете
➡️ Все перерывы 2 минуты

1 выход - 5 секунд
2 выход - 10 секунд + куртка
3 выход - 20 секунд + куртка
4 выход - выйти, закрыть дверь на один оборот, подождать 10 секунд и вернуться
5 выход - 5 секунд
6 выход - выйти, закрыть дверь на один оборот, подождать 20 секунд и вернуться
7 выход - 3 минуты + куртка + взять ключи, звякнуть ими

🟡 Если встала и пошла - входим через 2 минуты от начала движения, когда сняла фокус внимания с двери: села (пусть даже у двери), исследует квартиру
🟢 Если легла - входим через 30 секунд от укладки`)
    expect(plan.title).toBe('ТРИГГЕРОВКА на понедельник')
    expect(plan.defaultBreak).toBe(120)
    expect(plan.exits.map((e) => e.duration)).toEqual([5, 10, 20, 10, 5, 20, 180])
    expect(plan.exits.map((e) => e.triggers)).toEqual([
      [],
      ['куртка'],
      ['куртка'],
      ['закрыть дверь на один оборот'],
      [],
      ['закрыть дверь на один оборот'],
      ['куртка', 'взять ключи, звякнуть ими'],
    ])
    expect(plan.exits[3].note).toBe('выйти, закрыть дверь на один оборот, подождать 10 секунд и вернуться')
    expect(plan.exits[0].note).toBeNull()
    expect(plan.notes).toHaveLength(4)
    expect(plan.notes[0].endsWith('поздно вечером')).toBe(true)
    expect(plan.notes[1].startsWith('За 30 минут включить музыку')).toBe(true)

    expect(plan.commonEarlyEntries.map((e) => e.event)).toEqual(['Встала и пошла', 'Легла'])
    expect(plan.commonEarlyEntries.map((e) => e.delay)).toEqual([120, 30])
    expect(plan.commonEarlyEntries.map((e) => e.tone)).toEqual(['yellow', 'green'])
    expect(plan.commonEarlyEntries[0].detail).toBe(
      'от начала движения, когда сняла фокус внимания с двери: села (пусть даже у двери), исследует квартиру',
    )
    expect(plan.commonEarlyEntries[1].detail).toBe('от укладки')
    expect(plan.exits.every((e) => e.earlyEntries.length === 0)).toBe(true)
    expect(TrainingPlan.commonEntriesScope(plan)).toBe('all')
    expect(TrainingPlan.earlyEntries(plan, plan.exits[6]).map(EarlyEntry.summary)).toEqual(['встала и пошла → 2:00', 'легла → 0:30'])
  })

  // The training of 19.10.2026: conditions under exits 6 and 8 with their own times, rules for the whole training.
  it('attaches conditions to the exits right above them', () => {
    const plan = PlanParser.parse(`🐹 Тренировка на понедельник - 19.10.2026

➡️ Второго человека уводим из квартиры минимум за 30-40 минут до начала тренировки с обязательным сокрытием ухода. Вернуться можно минимум через 20-30 минут после окончания тренировки
➡️ За 30-60 минут включить музыку, отпереть дверь изнутри, закрыть окна
➡️ В перерывах сидите за столом, работаете
➡️ Все перерывы 2 минуты
➡️ Если лежит в лежанке, особо не шевелится, засыпает - перед выходом сначала шуршим на кухне/перемещаемся по квартире пока Мия не поднимет голову, затем сразу идём на выход
1 выход - 5 секунд

2 выход - 10 секунд + обувь

3 выход - 20 секунд + обувь

4 выход - 1 минута ИЛИ до вставания

5 выход - 20 секунд + обувь

6 выход - 4 минуты
🟡 Если встала и пошла - входим через 1 минуту от начала движения, когда сняла фокус внимания с двери: села (пусть даже у двери), исследует квартиру
🟢 Если легла - входим через 20 секунд от укладки

7 выход - 20 секунд + обувь

8 выход - 7 минут
🟡 Если встала и пошла - входим через 2 минуты от начала движения, когда сняла фокус внимания с двери: села (пусть даже у двери), исследует квартиру
🟢 Если легла - входим через 40 секунд от укладки


🚩 Если залаяла, завыла - ни в коем случае не входить, ждём когда станет чуть спокойнее или отойдёт от двери и входим когда молчала 30 секунд. Если скребёт дверь - ждём отхода от двери и возвращаемся на хорошем отвлечении от двери

🔖 Фальстарт: если пошла к двери в первые 20 секунд длинного выхода или если при выходе вы услышали звуки, на которые она будет реагировать - сразу возвращаемся, через обычный перерыв снова идём на длинный выход. Если на третьей попытке выхода снова зафальстартила - завершаем тренировку`)
    expect(plan.exits).toHaveLength(8)
    expect(plan.exits.map((e) => e.duration)).toEqual([5, 10, 20, 60, 20, 240, 20, 420])
    expect(plan.exits.map((e) => e.triggers.length)).toEqual([0, 1, 1, 0, 1, 0, 1, 0])
    expect(plan.exits[1].triggers).toEqual(['обувь'])
    expect(plan.commonEarlyEntries).toEqual([])
    expect(plan.exits[5].earlyEntries.map(EarlyEntry.summary)).toEqual(['встала и пошла → 1:00', 'легла → 0:20'])
    expect(plan.exits[7].earlyEntries.map(EarlyEntry.summary)).toEqual(['встала и пошла → 2:00', 'легла → 0:40'])
    expect(TrainingPlan.earlyEntries(plan, plan.exits[3]).map(EarlyEntry.summary)).toEqual(['встала → сразу'])
    expect(TrainingPlan.earlyEntries(plan, plan.exits[6])).toEqual([])
    expect(plan.notes).toHaveLength(7)
    expect(TrainingPlan.doNotEnterRule(plan)?.title).toBe('Залаяла, завыла')
    expect(TrainingPlan.doNotEnterRule(plan)?.detail.startsWith('ни в коем случае не входить')).toBe(true)

    const lines = PlanParser.sourceLines(plan.rawText)
    expect(lines[0]?.kind).toBe('header')
    const exit8 = lines.filter((line) => line.exitNumber === 8)
    expect(exit8.map((line) => line.kind)).toEqual(['exit', 'earlyEntry', 'earlyEntry'])
    expect(exit8[1].text.startsWith('🟡')).toBe(true)
    expect(lines.filter((line) => line.kind === 'doNotEnter')).toHaveLength(1)
    expect(lines.filter((line) => line.kind === 'falseStart')).toHaveLength(1)
  })

  // The training of 23.10.2026: «- далее после перерыва делаем выход на 15 секунд» made every break 15 s; the
  // conditions nested under exit 6 («🟡 Если встала за это время: …») landed among the training's rules.
  it('keeps an exit\'s time out of the common break and notes under an exit with it', () => {
    const plan = PlanParser.parse(`🐹 Тренировка на пятницу - Андрей - 23.10.2026

➡️ Гостей уводим из квартиры минимум за 1 час, без скрытия ухода➡️ Второго человека уводим из квартиры минимум за 30-40 минут до начала тренировки с обязательным сокрытием ухода. Вернуться можно минимум через 20-30 минут после окончания тренировки
➡️ За 30-60 минут включить музыку, отпереть дверь изнутри, закрыть окна
➡️ В перерывах сидите за столом, работаете
➡️ Все перерывы 2 минуты
➡️ Если лежит в лежанке, особо не шевелится, засыпает - перед выходом сначала шуршим на кухне/перемещаемся по квартире пока Мия не поднимет голову, затем сразу идём на выход
1 выход - 5 секунд

2 выход - 10 секунд

3 выход - 20 секунд

4 выход - 2 минуты ИЛИ до вставания

5 выход - 10 секунд

6 выход - 8 минут
🟡 Если встала и пошла - входим через 4 минуты от начала движения, когда сняла фокус внимания с двери: села (пусть даже у двери), исследует квартиру
🟢 Если легла - входим через 2 минуты от укладки
🟡 Если встала за это время:
     ➡️ если бродит - вход через 2 минуты
     ➡️ если легла - вход через 30 секунд

Если при возвращении с 6 выхода понимаешь, что она проспала его, то:
- далее после перерыва делаем выход на 15 секунд
- и далее после перерыва повторяем 6 выход
🚩 Если залаяла, завыла - ни в коем случае не входить, ждём когда станет чуть спокойнее или отойдёт от двери и входим когда молчала 30 секунд. Если скребёт дверь - ждём отхода от двери и возвращаемся на хорошем отвлечении от двери

🔖 Фальстарт: если пошла к двери в первые 20 секунд длинного выхода или если при выходе вы услышали звуки, на которые она будет реагировать - сразу возвращаемся, через обычный перерыв снова идём на длинный выход. Если на третьей попытке выхода снова зафальстартила - завершаем тренировку`)
    expect(plan.defaultBreak).toBe(120)
    expect(plan.exits.every((exit) => exit.breakAfter === null)).toBe(true)
    expect(plan.exits.map((exit) => exit.duration)).toEqual([5, 10, 20, 120, 10, 480])
    expect(plan.exits[5].earlyEntries.map(EarlyEntry.summary)).toEqual(['встала и пошла → 4:00', 'легла → 2:00'])
    expect(plan.exits[5].note).toBe('Если встала за это время:\nесли бродит - вход через 2 минуты\nесли легла - вход через 30 секунд')
    expect(plan.notes).toHaveLength(11)
    expect(plan.notes).toContain('далее после перерыва делаем выход на 15 секунд')
    expect(plan.notes.at(-1)?.startsWith('Фальстарт')).toBe(true)
    const exit6 = PlanParser.sourceLines(plan.rawText).filter((line) => line.exitNumber === 6)
    expect(exit6.map((line) => line.kind)).toEqual(['exit', 'earlyEntry', 'earlyEntry', 'note', 'note', 'note'])
  })

  it('does not take an exit\'s time or «после перерыва» for the break', () => {
    expect(PlanParser.commonBreak('далее после перерыва делаем выход на 15 секунд')).toBeNull()
    expect(PlanParser.commonBreak('Перерыв, затем выход 30 секунд')).toBeNull()
    expect(PlanParser.commonBreak('After the break do an exit of 15 seconds')).toBeNull()
    expect(PlanParser.commonBreak('Перерывы между выходами — 2 минуты')).toBe(120)
    // The first line that names the common break wins.
    const plan = PlanParser.parse('➡️ Все перерывы 2 минуты\n1 выход - 5 секунд\n\nПерерывы можно увеличить до 3 минут')
    expect(plan.defaultBreak).toBe(120)
  })

  it('reads early entry lines', () => {
    const english = PlanParser.parseEarlyEntry('If she lies down - come back in 30 seconds')
    expect(english?.event).toBe('She lies down')
    expect(english?.delay).toBe(30)
    const rightAway = PlanParser.parseEarlyEntry('Если встала, сразу входим')
    expect(rightAway?.event).toBe('Встала')
    expect(rightAway?.delay).toBeNull()
    expect(PlanParser.parseEarlyEntry('🚩 Если залаяла - ни в коем случае не входить, входим когда молчала 30 секунд')).toBeNull()
    expect(PlanParser.parseEarlyEntry('Если лежит в лежанке - перед выходом сначала шуршим на кухне')).toBeNull()
    expect(PlanParser.parseEarlyEntry('Вернуться можно минимум через 20-30 минут после окончания тренировки')).toBeNull()
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

  it('finds Russian words like ICU word boundaries', () => {
    // JS's `\\b` does not see Cyrillic letters: «входим» inside «подвходим» is not the verb.
    expect(PlanParser.parseEarlyEntry('Если легла - подвходим через 5 секунд')).toBeNull()
    expect(PlanParser.parseEarlyEntry('Если легла – входим через 5 секунд')?.delay).toBe(5)
    expect(PlanParser.isDoNotEnterRule('Если лает — не входим, ждём')).toBe(true)
    expect(PlanParser.isDoNotEnterRule('Если лает — не входимость')).toBe(false)
    expect(PlanParser.parseEarlyEntry('Если встала, входим сразу')?.delay).toBeNull()
  })

  it('reads a Windows line break (CRLF) as one', () => {
    const text = '6 выход - 4 минуты\r\n🟡 Если встала - входим через 1 минуту\r\n\r\n🟢 Если легла - входим через 20 секунд'
    const plan = PlanParser.parse(text)
    expect(plan.exits[0].earlyEntries.map((entry) => entry.event)).toEqual(['Встала'])
    expect(plan.commonEarlyEntries.map((entry) => entry.event)).toEqual(['Легла'])
    expect(PlanParser.sourceLines(text).map((line) => line.kind)).toEqual(['exit', 'earlyEntry', 'blank', 'earlyEntry'])
  })

  it('writes triggers and conditions with the Swift keys', () => {
    const plan = PlanParser.parse('2 выход - 10 секунд + куртка\n🟢 Если легла - входим через 30 секунд от укладки\n\n🟡 Если встала - сразу входим')
    const json = TrainingPlan.encode(plan, 'iso8601')
    expect(Object.keys(json)).toContain('commonEarlyEntries')
    const exit = (json.exits as Record<string, unknown>[])[0]
    expect(exit.triggers).toEqual(['куртка'])
    expect(exit.usesCommonEarlyEntries).toBe(false)
    const entry = (exit.earlyEntries as Record<string, unknown>[])[0]
    expect(Object.keys(entry).sort()).toEqual(['delay', 'detail', 'event', 'id', 'tone'])
    expect(entry.tone).toBe('green')
    // «сразу»: no delay key, as Swift's encodeIfPresent leaves it out.
    expect(Object.keys((json.commonEarlyEntries as Record<string, unknown>[])[0]).sort()).toEqual(['event', 'id', 'tone'])
    expect(TrainingPlan.decode(JSON.parse(JSON.stringify(json)), 'iso8601')).toEqual(plan)
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
