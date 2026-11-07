// Port of PlanParserTests.swift.
import { beforeEach, describe, expect, it } from 'vitest'
import { DurationText, EarlyEntry, PlanParser, PlannedExit, TrainingPlan, setCoreLanguage, setCoreRegion } from '@core/index'

const sampleWithDefaultBreaks = `🐹 Тренировка на понедельник - Аня/Марк - 05.10.2026

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

const sampleWithExplicitBreaks = `🐹 Тренировка на пятницу - Марк - 25.09.2026

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
    expect(plan.trainers).toBe('Аня/Марк')
    expect(plan.date === null ? null : TrainingPlan.formatDate(plan.date)).toBe('05.10.2026')
    expect(plan.defaultBreak).toBe(120)
    expect(plan.exits).toHaveLength(7)
    expect(plan.exits.map((e) => e.duration)).toEqual([5, 10, 5, 15, 30, 10, 60])
    expect(plan.exits.map(PlannedExit.endsWhenStanding)).toEqual([false, false, false, false, true, false, true])
    expect(plan.exits.every((e) => e.breakAfter === null)).toBe(true)
    expect(TrainingPlan.breakAfter(plan, 3)).toBe(120)
    expect(plan.notes).toHaveLength(5)
    expect(plan.notes.at(-1)?.startsWith('Фальстарт')).toBe(true)
  })

  it('parses the sample with explicit breaks', () => {
    const plan = PlanParser.parse(sampleWithExplicitBreaks)

    expect(plan.title).toBe('Тренировка на пятницу')
    expect(plan.trainers).toBe('Марк')
    expect(plan.exits).toHaveLength(9)
    expect(plan.exits[0].duration).toBe(0)
    expect(plan.exits[0].note).toBe('выйти и сразу вернуться')
    // "Перерыв 2 минуты" after most exits becomes the plan's break; only the 5-minute ones stay per exit.
    expect(plan.defaultBreak).toBe(120)
    expect(plan.exits.map((e) => e.breakAfter)).toEqual([null, null, 300, null, null, 300, null, null, null])
    expect(TrainingPlan.breakAfter(plan, 0)).toBe(120)
    expect(plan.exits[8].duration).toBe(20)
    expect(PlannedExit.endsWhenStanding(plan.exits[8])).toBe(true)
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

  // The screenshot of 04.11: «ключ ИЛИ до вставания» was one trigger. «ИЛИ до вставания» is the exit's condition.
  it('takes «ИЛИ до вставания» after the triggers as the exit’s condition', () => {
    const plan = PlanParser.parse(`3 выход - 15 секунд + куртка + ключ
4 выход - 45 секунд + куртка + ключ ИЛИ до вставания
5 выход - 15 секунд + ключ или телефон
6 выход - 20 секунд + ключ или телефон ИЛИ пока не встанет

🟡 Если встала и пошла - входим через 3 минуты от начала движения
🟢 Если легла - входим через 1 минуту от укладки`)
    expect(plan.exits.map((e) => e.duration)).toEqual([15, 45, 15, 20])
    expect(plan.exits.map((e) => e.triggers)).toEqual([
      ['куртка', 'ключ'],
      ['куртка', 'ключ'],
      ['ключ или телефон'],
      ['ключ или телефон'],
    ])
    expect(plan.exits.map(PlannedExit.endsWhenStanding)).toEqual([false, true, false, true])
    // A 45-second exit gets no common conditions, only its own word.
    expect(TrainingPlan.earlyEntries(plan, plan.exits[1]).map(EarlyEntry.summary)).toEqual(['встала → сразу'])
    expect(PlannedExit.durationDescription(plan.exits[1])).toBe('45 с или до вставания')

    const english = PlanParser.parseExit('Exit 4 - 45 seconds + jacket + keys OR until the dog stands up')
    expect(english?.triggers).toEqual(['jacket', 'keys'])
    expect(english?.untilStanding).toBe(true)
    expect(PlanParser.parseExit('4 выход - 45 секунд + ИЛИ до вставания')?.triggers).toEqual([])

    // A plan an older build saved with the trigger «ключ ИЛИ до вставания» comes back right.
    const saved = TrainingPlan.make({
      exits: [PlannedExit.make({ number: 4, duration: 45, triggers: ['куртка', 'ключ ИЛИ до вставания'] })],
    })
    expect(saved.exits[0].triggers).toEqual(['куртка', 'ключ'])
    expect(PlannedExit.endsWhenStanding(saved.exits[0])).toBe(true)
  })

  // «К длинным» (the default) and «ко всем» survive an added exit and a new time; «Выбрать» and the switches flipped
  // by hand stay as they are.
  it('keeps the common conditions’ scope through edits', () => {
    const plan = PlanParser.parse(`1 выход - 15 секунд
2 выход - 2 минуты
3 выход - 45 секунд

🟢 Если легла - входим через 30 секунд от укладки`)
    expect(TrainingPlan.commonEntriesScope(plan)).toBe('long')
    const uses = (value: TrainingPlan) => value.exits.map((e) => e.usesCommonEarlyEntries)

    // A short exit added, the 45-second one stretched to 2 minutes.
    const edited = TrainingPlan.keepingCommonEntriesScope(
      {
        ...plan,
        exits: [...plan.exits.map((e, i) => (i === 2 ? { ...e, duration: 120 } : e)), PlannedExit.make({ number: 4, duration: 10 })],
      },
      plan,
    )
    expect(TrainingPlan.commonEntriesScope(edited)).toBe('long')
    expect(uses(edited)).toEqual([false, true, true, false])

    // A switch flipped by hand makes it «Выбрать», and a later new time doesn't undo it.
    const flipped = { ...edited, exits: edited.exits.map((e, i) => (i === 0 ? { ...e, usesCommonEarlyEntries: true } : e)) }
    const picked = TrainingPlan.keepingCommonEntriesScope(flipped, edited)
    expect(TrainingPlan.commonEntriesScope(picked)).toBeNull()
    const retimed = TrainingPlan.keepingCommonEntriesScope(
      { ...picked, exits: picked.exits.map((e, i) => (i === 3 ? { ...e, duration: 90 } : e)) },
      picked,
    )
    expect(uses(retimed)).toEqual([true, true, true, false])

    // «Ко всем»: an added short exit gets them too.
    const all = TrainingPlan.applyCommonEarlyEntries(plan, 'all')
    expect(TrainingPlan.commonEntriesScope(all)).toBe('all')
    const added = TrainingPlan.keepingCommonEntriesScope(
      { ...all, exits: [...all.exits, PlannedExit.make({ number: 4, duration: 10, usesCommonEarlyEntries: false })] },
      all,
    )
    expect(TrainingPlan.commonEntriesScope(added)).toBe('all')

    // Only long exits: both fit and the switch says «к длинным», so a short exit added later doesn't get them.
    const long = PlanParser.parse('1 выход - 2 минуты\n2 выход - 3 минуты\n\n🟢 Если легла - входим через 30 секунд')
    expect(TrainingPlan.commonEntriesScope(long)).toBe('long')
    const longAdded = TrainingPlan.keepingCommonEntriesScope({ ...long, exits: [...long.exits, PlannedExit.make({ number: 3, duration: 20 })] }, long)
    expect(longAdded.exits[2].usesCommonEarlyEntries).toBe(false)

    // «Ещё выход» has no planned time and counts as long.
    expect(TrainingPlan.commonEntriesScope({ ...plan, exits: [...plan.exits, PlannedExit.open(4)] })).toBe('long')
  })

  it('understands alternative spellings', () => {
    const plan = PlanParser.parse(`Тренировка
Выход 1 — 1 мин 30 сек
Выход №2: 2 минуты или до вставания`)
    expect(plan.exits).toHaveLength(2)
    expect(plan.exits[0].duration).toBe(90)
    expect(plan.exits[1].duration).toBe(120)
    expect(PlannedExit.endsWhenStanding(plan.exits[1])).toBe(true)
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
    // By default the common conditions go to the exits of a minute and longer: here only the 3-minute one.
    expect(TrainingPlan.commonEntriesScope(plan)).toBe('long')
    expect(plan.exits.map((e) => TrainingPlan.usesCommonEarlyEntries(plan, e))).toEqual([false, false, false, false, false, false, true])
    expect(TrainingPlan.earlyEntries(plan, plan.exits[6]).map(EarlyEntry.summary)).toEqual(['встала и пошла → 2:00', 'легла → 0:30'])
    expect(TrainingPlan.earlyEntries(plan, plan.exits[0])).toEqual([])
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
    const plan = PlanParser.parse(`🐹 Тренировка на пятницу - Марк - 23.10.2026

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

  // "inf" typed into a duration field crashed the Mac and iPhone apps: `Int(.infinity)` traps.
  it('takes only real times for durations', () => {
    for (const text of ['inf', 'nan', '1e400', '0x1p4', '99999999999999999:00', '100 часов']) {
      expect(DurationText.parse(text), text).toBeNull()
    }
    expect(DurationText.parse('1e2')).toBe(100)
    expect(DurationText.parse('-5')).toBe(-5)
    expect(DurationText.short(Infinity)).toBe(DurationText.short(2 ** 31 - 1))
    expect(DurationText.short(NaN)).toBe('0 с')
    expect(DurationText.compact(1e300)).toBe(DurationText.compact(2 ** 31 - 1))
    expect(DurationText.clock(-Infinity)).toBe('−596523:14:07')
  })

  // «🚩 … не заходите» became the condition «Залаяла, завыла → сразу»: the app said the opposite of the trainer.
  it('keeps the rules against coming in', () => {
    const plan = PlanParser.parse('6 выход - 4 минуты\n🚩 Если залаяла, завыла - ни в коем случае не заходите, ждите тишины')
    expect(plan.exits[0].earlyEntries).toEqual([])
    expect(plan.commonEarlyEntries).toEqual([])
    expect(plan.notes).toEqual(['🚩 Если залаяла, завыла - ни в коем случае не заходите, ждите тишины'])
    expect(TrainingPlan.doNotEnterRule(plan)?.title).toBe('Залаяла, завыла')
    expect(TrainingPlan.doNotEnterRule(plan)?.detail).toBe('ни в коем случае не заходите, ждите тишины')
    expect(PlanParser.sourceLines(plan.rawText).map((line) => line.kind)).toEqual(['exit', 'doNotEnter'])

    // The flag alone says it, and it beats a note that only mentions not coming in.
    const flagged = PlanParser.parse('1 выход - 5 секунд\n\nНе заходить в комнату без нужды\n🚩 Если залаяла - ждём тишины')
    expect(TrainingPlan.doNotEnterRule(flagged)?.title).toBe('Залаяла')

    for (const line of [
      'Если залаяла - не входите',
      'Если лает - нельзя возвращаться, входим когда замолчит',
      'If she barks, do not return',
      'If she barks - don’t come in, wait for silence',
      'If she barks, never enter',
    ]) {
      expect(PlanParser.parseEarlyEntry(line), line).toBeNull()
      expect(PlanParser.isDoNotEnterRule(line), line).toBe(true)
    }
    expect(PlanParser.isDoNotEnterRule('Если лает — ждём вне входа')).toBe(false)
    expect(PlanParser.isDoNotEnterRule('Если лает — дальше не выходим')).toBe(false)
    // A plan saved before the flag was kept: its words still say it.
    expect(TrainingPlan.doNotEnterRule(TrainingPlan.make({ notes: ['Если залаяла, завыла - ни в коем случае не заходите'] }))).not.toBeNull()
  })

  // «через минуту», «через 0,5 минуты» were read as no time, and no time is «сразу».
  it('reads delays in words and with a decimal comma', () => {
    const delay = (line: string) => PlanParser.parseEarlyEntry(line)?.delay
    expect(delay('🟡 Если встала - входим через минуту')).toBe(60)
    expect(delay('Если встала - входим через 0,5 минуты')).toBe(30)
    expect(delay('Если встала - входим через 1,5 минуты, когда отойдёт')).toBe(90)
    expect(delay('Если встала - входим через полминуты')).toBe(30)
    expect(delay('Если встала - входим через пол минуты')).toBe(30)
    expect(delay('Если встала - входим через полторы минуты')).toBe(90)
    expect(delay('Если легла - входим через десять секунд')).toBe(10)
    expect(delay('If she stands up - come back in a minute')).toBe(60)
    expect(delay('If she stands up - come back in half a minute')).toBe(30)
    expect(delay('If she lies down - come back after ten seconds')).toBe(10)
    const words = PlanParser.parseEarlyEntry('Если встала - входим через две минуты от начала движения, когда сняла фокус')!
    expect(words.delay).toBe(120)
    expect(words.detail).toBe('от начала движения, когда сняла фокус')
    expect(EarlyEntry.unreadDelay(words)).toBeNull()

    // Words it can't read stay in sight instead of «сразу».
    const vague = PlanParser.parseEarlyEntry('🟡 Если встала - входим через пару минут от начала движения, когда отойдёт')!
    expect(vague.delay).toBeNull()
    expect(vague.detail).toBe('через пару минут от начала движения, когда отойдёт')
    expect(EarlyEntry.unreadDelay(vague)).toBe('через пару минут')
    expect(EarlyEntry.summary(vague)).toBe('встала → через пару минут')
    expect(EarlyEntry.delayDescription(vague)).toBe('через пару минут')
    expect(EarlyEntry.unreadDelay(PlanParser.parseEarlyEntry('If she lies down - come back in a couple of minutes')!)).toBe(
      'in a couple of minutes',
    )
    // «сразу» is still «сразу», and an "in" that names a place is no time.
    expect(EarlyEntry.summary(PlanParser.parseEarlyEntry('Если встала - входим сразу')!)).toBe('встала → сразу')
    expect(EarlyEntry.unreadDelay(PlanParser.parseEarlyEntry('If she lies down - come back in the hallway')!)).toBeNull()
  })

  // 2/3/2/3-minute breaks: Swift took whichever its Dictionary gave first, different from launch to launch. The first
  // one written wins.
  it('breaks a tie of breaks by the first one written', () => {
    const plan = PlanParser.parse(
      '1 выход - 5 секунд\nПерерыв 3 минуты\n2 выход - 5 секунд\nПерерыв 2 минуты\n' +
        '3 выход - 5 секунд\nПерерыв 3 минуты\n4 выход - 5 секунд\nПерерыв 2 минуты',
    )
    expect(plan.defaultBreak).toBe(180)
    expect(plan.exits.map((exit) => exit.breakAfter)).toEqual([null, 120, null, 120])
  })

  // «🟡︎», «🔖︎», «🚩︎» (with a variation selector) are the trainer's marks all the same, as on the Mac and iPhone.
  it('reads marks with a variation selector', () => {
    expect(PlanParser.parseEarlyEntry('🟡\uFE0F Если встала - входим через 15 секунд')?.tone).toBe('yellow')
    expect(PlanParser.parseEarlyEntry('🟢\uFE0E Если легла - входим через 15 секунд')?.tone).toBe('green')
    const text =
      '6 выход - 4 минуты\n🟡 Если встала - входим через 1 минуту\n' +
      '🔖\uFE0E На третьей попытке завершаем тренировку\n🚩\uFE0F Если залаяла - ждём тишины'
    const plan = PlanParser.parse(text)
    expect(plan.exits[0].note).toBeNull()
    expect(plan.notes).toEqual(['На третьей попытке завершаем тренировку', '🚩 Если залаяла - ждём тишины'])
    expect(TrainingPlan.doNotEnterRule(plan)?.title).toBe('Залаяла')
    expect(PlanParser.sourceLines(text).map((line) => line.kind)).toEqual(['exit', 'earlyEntry', 'falseStart', 'doNotEnter'])
  })

  // A lone «➡️» row at the top was taken for the header of the trainer's text, and the header for a note.
  it('skips lines of decorations only', () => {
    const text = '➡️\n🐹 Тренировка на понедельник - 19.10.2026\n1 выход - 5 секунд\n➡️\n🟢 Если легла - входим через 20 секунд'
    const plan = PlanParser.parse(text)
    expect(plan.title).toBe('Тренировка на понедельник')
    expect(plan.exits[0].earlyEntries.length).toBe(1)
    const lines = PlanParser.sourceLines(text)
    expect(lines.map((line) => line.kind)).toEqual(['note', 'header', 'exit', 'note', 'earlyEntry'])
    expect(lines.map((line) => line.exitNumber)).toEqual([null, null, 1, 1, 1])
  })

  // «…входим через 30 секунд, не заходя в комнату» was taken for a rule against coming in: the condition was lost and
  // the line became the plan's «Не входить».
  it('does not take how to come in for a rule against it', () => {
    const plan = PlanParser.parse('3 выход - 2 минуты\n🟢 Если легла - входим через 30 секунд, не заходя в комнату')
    expect(plan.exits[0].earlyEntries[0]?.delay).toBe(30)
    expect(plan.exits[0].earlyEntries[0]?.detail).toBe('не заходя в комнату')
    expect(TrainingPlan.doNotEnterRule(plan)).toBeNull()
    expect(PlanParser.sourceLines(plan.rawText).map((line) => line.kind)).toEqual(['exit', 'earlyEntry'])

    const quietly = PlanParser.parseEarlyEntry('Если встала - возвращаемся через минуту, не входя резко')
    expect(quietly?.delay).toBe(60)
    expect(quietly?.detail).toBe('не входя резко')
    expect(PlanParser.parseEarlyEntry('Если встала - входим через минуту, не возвращаясь к двери')?.delay).toBe(60)
    const bedroom = PlanParser.parseEarlyEntry('If she lies down - come back in 30 seconds, don’t enter the bedroom')
    expect(bedroom?.delay).toBe(30)
    expect(bedroom?.detail).toBe('don’t enter the bedroom')

    for (const line of [
      'Если залаяла - не входить',
      'Если залаяла - не заходи',
      'Если залаяла - не входим',
      'Если залаяла - не возвращайтесь',
      'Если лает - не возвращайся, жди',
      'Если лает - нельзя заходить',
      "If she barks, don't enter",
      'If she barks, do not enter the flat',
      'If she barks - never enter until she is quiet',
    ]) {
      expect(PlanParser.isDoNotEnterRule(line), line).toBe(true)
      expect(PlanParser.parseEarlyEntry(line), line).toBeNull()
    }
    expect(PlanParser.isDoNotEnterRule('Если лает — в план не входит')).toBe(false)
  })

  // «1 выход - 99999999999999999999 секунд» pasted into a plan crashed the Mac: the plan's length went to `Int(_:)`.
  it('takes huge times for no time', () => {
    expect(DurationText.sumOfUnits('99999999999999999999 секунд')).toBeNull()
    expect(DurationText.sumOfUnits('9'.repeat(400) + ' секунд')).toBeNull()
    expect(DurationText.sumOfUnits('25 часов')).toBeNull()
    expect(DurationText.sumOfUnits('24 часа')).toBe(86400)

    const plan = PlanParser.parse(
      '1 выход - 99999999999999999999 секунд\nПерерыв 99999999999999999999 минут\n2 выход - 5 секунд\n' +
        '🟡 Если встала - входим через секунд 99999999999999999999',
    )
    expect(plan.exits.map((exit) => exit.duration)).toEqual([0, 5])
    expect(plan.exits.map((exit) => exit.breakAfter)).toEqual([null, null])
    expect(plan.notes).toEqual(['Перерыв 99999999999999999999 минут'])
    expect(plan.exits[1].earlyEntries[0]?.delay).toBeNull()

    expect(DurationText.wholeSeconds(Infinity)).toBe(2 ** 31 - 1)
    expect(DurationText.wholeSeconds(-Infinity)).toBe(-(2 ** 31 - 1))
    expect(DurationText.wholeSeconds(NaN)).toBe(0)
    expect(DurationText.wholeSeconds(89.5)).toBe(90)
  })

  // «через секунд 30» was read as one second with «30» left over: «через 0:01 · 30».
  it('reads the number after its unit', () => {
    const entry = (line: string) => PlanParser.parseEarlyEntry(line)
    expect(entry('Если встала - входим через секунд 30')?.delay).toBe(30)
    expect(entry('Если встала - входим через секунд 30')?.detail).toBeNull()
    expect(entry('Если встала - входим через минут 5, когда отойдёт')?.delay).toBe(300)
    expect(entry('Если встала - входим через минут 5, когда отойдёт')?.detail).toBe('когда отойдёт')
    expect(entry('Если легла - входим через секунд тридцать от укладки')?.delay).toBe(30)
    expect(entry('Если легла - входим через секунд тридцать от укладки')?.detail).toBe('от укладки')
    expect(entry('Если встала - входим через минуты две')?.delay).toBe(120)
    // A word that is no number, or a time of its own, is not the count.
    expect(entry('Если встала - входим через минуту после укладки')?.delay).toBe(60)
    expect(entry('Если встала - входим через минуту после укладки')?.detail).toBe('после укладки')
    expect(entry('Если встала - входим через минуту 30 секунд')?.delay).not.toBe(1800)
  })

  // "come back in several minutes" said "right away": only "in a …" and a single digit were taken for a time.
  it('keeps English delays it cannot read', () => {
    const words = (line: string) => EarlyEntry.unreadDelay(PlanParser.parseEarlyEntry(line)!)
    expect(words('If she stands up - come back in several minutes')).toBe('in several minutes')
    expect(words('If she stands up - come back in a few minutes')).toBe('in a few minutes')
    expect(words('If she stands up - come back in few minutes')).toBe('in few minutes')
    expect(words('If she lies down - come back in 15 breaths')).toBe('in 15 breaths')
    expect(words('If she lies down - come back in some time')).toBe('in some time')
    expect(words('If she stands up - come back in a couple of minutes after she lies down')).toBe('in a couple of minutes')
    expect(words('If she stands up - come back after she settles')).toBe('after she settles')
    expect(words('If she lies down - come back in the kitchen')).toBeNull()
    expect(EarlyEntry.delayDescription(PlanParser.parseEarlyEntry('If she stands up - come back in several minutes')!)).toBe(
      'in several minutes',
    )
  })

  // «через пару минут» on the right and «через пару минут от начала движения, когда отойдёт» under the event: the
  // trainer's words twice.
  it('shows the detail beside an unread delay without its words', () => {
    const beside = (line: string) => EarlyEntry.detailBesideTime(PlanParser.parseEarlyEntry(line)!)
    const vague = PlanParser.parseEarlyEntry('🟡 Если встала - входим через пару минут от начала движения, когда отойдёт')!
    expect(vague.detail).toBe('через пару минут от начала движения, когда отойдёт')
    expect(EarlyEntry.detailBesideTime(vague)).toBe('от начала движения, когда отойдёт')
    expect(beside('Если встала - входим через пару минут, когда отойдёт')).toBe('когда отойдёт')
    expect(beside('Если встала - входим через пару минут')).toBeNull()
    expect(beside('If she stands up - come back in a few minutes after she lies down')).toBe('after she lies down')
    // A time it has read, or none: the detail as it is.
    expect(beside('Если встала - входим через 2 минуты от начала движения')).toBe('от начала движения')
    expect(beside('Если встала - входим сразу, тихо')).toBe('тихо')
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
    const plan = PlanParser.parse(`🐹 Тренировка на вторник - Аня - 06.10.2026

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
    expect(PlanParser.isDoNotEnterRule('Если лает — ждём вне входа')).toBe(false)
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
