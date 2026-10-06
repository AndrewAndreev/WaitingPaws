import { coreLanguage } from '@core/localization'
import { PlannedExit, TrainingPlan } from '@core/models'
import { PlanParser } from '@core/planParser'
import { TrainingSession } from '@core/trainingSession'
import type { TrainingRecord } from '@core/sessionLog'

/// Sample data for UI checks and screenshots without a camera or a real history (launch arguments only, the same
/// samples as the Mac app's DEBUG `DemoData`).

const planTextEN = `🐶 Sunday training - Anna/Mark - 04.10.2026

➡️ The second person leaves the apartment at least 30-40 minutes before the training, without the dog noticing
➡️ 30-60 minutes before: turn on music, unlock the door from inside, close the windows
➡️ During breaks sit at the table and work
➡️ All breaks 2 minutes

Exit 1 - 10 seconds
Exit 2 - 30 seconds
Exit 3 - 15 seconds
Exit 4 - 1 minute
Exit 5 - 45 seconds
Exit 6 - 2 minutes OR until the dog stands up
Break 5 minutes
Exit 7 - 30 seconds
Exit 8 - 3 minutes OR until the dog stands up
Exit 9 - 1 minute

🔖 False start: if she walks to the door during a long exit, or you heard sounds she will react to, come back right away and after a normal break go for the long exit again`

const planTextRU = `🐹 Тренировка на воскресенье - Таня/Андрей - 04.10.2026

➡️ Второго человека уводим из квартиры минимум за 30-40 минут до начала тренировки с обязательным сокрытием ухода
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

🔖 Фальстарт: если пошла к двери во время длинного выхода или если при выходе вы услышали звуки, на которые она будет реагировать - сразу возвращаемся, через обычный перерыв снова идём на длинный выход`

export function demoPlanText(): string {
  return coreLanguage() === 'ru' ? planTextRU : planTextEN
}

export function demoPlan(): TrainingPlan {
  return PlanParser.parse(demoPlanText())
}

const days: [string, string, number[], number | null][] = [
  ['2026-09-06 18:04', 'Таня / Андрей', [0, 2, 2, 2, 5], 3],
  ['2026-09-09 19:20', 'Андрей', [2, 5, 2, 5, 10], null],
  ['2026-09-12 18:41', 'Таня / Андрей', [5, 10, 5, 10, 15], null],
  ['2026-09-14 11:02', 'Таня', [5, 10, 15, 10, 20], 4],
  ['2026-09-17 19:05', 'Андрей', [10, 15, 10, 20, 30], null],
  ['2026-09-20 12:30', 'Таня / Андрей', [10, 20, 30, 15, 30, 45], null],
  ['2026-09-23 18:55', 'Андрей', [15, 30, 20, 45, 30, 60], null],
  ['2026-09-26 18:10', 'Таня / Андрей', [20, 30, 45, 30, 60, 45], 4],
  ['2026-09-28 10:47', 'Таня', [30, 45, 30, 60, 90, 60], null],
  ['2026-09-30 19:12', 'Андрей', [30, 60, 45, 90, 60, 120], null],
  ['2026-10-02 18:36', 'Таня / Андрей', [30, 60, 45, 90, 120, 60, 150], 6],
]
const weekdays = ['на воскресенье', 'на понедельник', 'на вторник', 'на среду', 'на четверг', 'на пятницу', 'на субботу']
const weekdaysEN = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

/// Eleven finished trainings over four weeks, newest first; time behind the door grows from 0:05 to 2:30.
export function demoHistory(): TrainingRecord[] {
  const english = coreLanguage() === 'en'
  return [...days].reverse().map(([start, trainers, exits, falseStartAt]) => {
    const [day, time] = start.split(' ')
    const [y, m, d] = day.split('-').map(Number)
    const [hh, mm] = time.split(':').map(Number)
    const date = new Date(y, m - 1, d, hh, mm).getTime()
    const weekday = new Date(date).getDay()
    const plan = TrainingPlan.make({
      title: english ? `${weekdaysEN[weekday]} training` : `Тренировка ${weekdays[weekday]}`,
      trainers: english ? trainers.replace('Таня', 'Anna').replace('Андрей', 'Mark') : trainers,
      date,
      exits: exits.map((duration, index) => PlannedExit.make({ number: index + 1, duration })),
    })
    let now = date
    const session = new TrainingSession(plan, { clock: () => now })
    exits.forEach((planned, index) => {
      const jitter = (index * 7 + planned) % 5
      if (falseStartAt === index) {
        session.markBehindDoor()
        now += Math.max(1, planned * 0.4) * 1000
        session.resetExit()
        now += (120 + jitter) * 1000
      }
      session.markBehindDoor()
      now += (planned + 1 + jitter / 2) * 1000
      session.endExit()
      now += (index === exits.length - 1 ? 30 : 120 + jitter) * 1000
    })
    session.finish()
    return session.makeRecord(null)
  })
}

/// A session of `plan` whose first `done` exits happened in the past at a realistic pace; it is now in the break
/// after the last of them, `breakLeft` seconds before it ends.
export function demoReplay(plan: TrainingPlan, done: number, breakLeft = 40): TrainingSession {
  const exits = Math.min(done, plan.exits.length)
  const linger = 3
  let total = 0
  for (let i = 0; i < exits; i++) total += plan.exits[i].duration + linger + TrainingPlan.breakAfter(plan, i)
  let offset = -(total - breakLeft) * 1000
  const session = new TrainingSession(plan, { clock: () => Date.now() + offset })
  for (let i = 0; i < exits; i++) {
    session.markBehindDoor()
    offset += (plan.exits[i].duration + linger) * 1000
    session.endExit()
    offset += TrainingPlan.breakAfter(plan, i) * 1000
  }
  offset = 0
  return session
}
