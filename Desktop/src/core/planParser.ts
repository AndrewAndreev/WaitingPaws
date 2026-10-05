// Port of Parser/PlanParser.swift.
//
// Parses the free-form training schedule text sent by the trainer, in Russian or English.
//
// Recognised lines:
// - header: `🐹 Тренировка на понедельник - Таня/Андрей - 05.10.2026`, `Monday training - Anna - 10/05/2026`
// - exit:   `3 выход - 5 секунд`, `5 выход - 30 секунд ИЛИ до вставания`, `1 выход - 0 секунд (выйти и сразу вернуться)`,
//           `Exit 3 - 5 seconds`, `Exit 5 - 30 seconds OR until the dog stands up`
// - break:  `Перерыв 5 минут`, `Break 5 minutes` (applies to the preceding exit)
// - default break inside the notes: `➡️ Все перерывы 2 минуты`, `All breaks 2 minutes`
// - anything else becomes a note.

import { DurationText } from './durationText'
import { coreLanguage, coreLocale } from './localization'
import { PlannedExit, TrainingPlan } from './models'
import { parseSwiftInt, splitLines, trimWhitespaces, trimWhitespacesAnd } from './text'

const decorationRegex = /^[^\p{L}\p{N}(]+/u

/** "3 выход", "выход 3", "выход №3", "Exit 3", "3rd exit", "Departure #3", followed by the duration. */
const exitRegex =
  /^(?:(\d+)(?:st|nd|rd|th)?\s*[-–—.)]?\s*(?:выход|exit|departure)\p{L}*|(?:выход|exit|departure)\p{L}*\s*(?:№|#|no\.?)?\s*(\d+))\s*[-–—:]*\s*(.*)$/iu

const parenthesesRegex = /\(([^)]*)\)/u
const allParenthesesRegex = /\(([^)]*)\)/gu
const orRegex = /(^|\s)(или|or)(\s|$)/u
const dateRegex = /(\d{1,2})[./-](\d{1,2})[./-](\d{4}|\d{2})/u

/** ICU's `\b` around "break": word characters are letters, marks, digits and connectors (not only ASCII). */
const word = '[\\p{Alphabetic}\\p{M}\\p{Nd}\\p{Pc}\\u200C\\u200D]'
const breakWordRegex = new RegExp(`(?<!${word})(?:break|breaks|pause|pauses)(?!${word})`, 'u')

/** Whether English dates with slashes are month-first in the device's region (`dMy` → "M/d/y"). */
function localeWritesMonthFirst(): boolean {
  const parts = new Intl.DateTimeFormat(coreLocale('en'), { day: 'numeric', month: 'numeric', year: 'numeric' })
    .formatToParts(Date.UTC(2026, 9, 5, 12))
    .map((part) => part.type)
  const month = parts.indexOf('month')
  const day = parts.indexOf('day')
  return month >= 0 && day >= 0 && month < day
}

export const PlanParser = {
  parse(text: string): TrainingPlan {
    let plan = TrainingPlan.make({ rawText: text })
    const exits: PlannedExit[] = []
    const notes: string[] = []
    let defaultFromText = false

    const lines = splitLines(text)
      .map(trimWhitespaces)
      .filter((line) => line !== '')

    lines.forEach((rawLine, index) => {
      const line = PlanParser.stripDecorations(rawLine)
      if (line === '') return

      const exit = PlanParser.parseExit(line)
      if (exit) {
        exits.push(exit)
        return
      }

      const lower = line.toLowerCase()

      if (PlanParser.isExitBreak(lower) && exits.length > 0) {
        const duration = DurationText.sumOfUnits(line)
        if (duration !== null) {
          exits[exits.length - 1] = { ...exits[exits.length - 1], breakAfter: duration }
          return
        }
      }

      if (PlanParser.mentionsBreak(lower)) {
        const duration = DurationText.sumOfUnits(line)
        if (duration !== null) {
          plan.defaultBreak = duration
          defaultFromText = true
          notes.push(line)
          return
        }
      }

      if (index === 0) {
        plan = PlanParser.parseHeader(line, plan)
        return
      }

      notes.push(line)
    })

    plan.exits = exits
    plan.notes = notes
    return PlanParser.normalizeBreaks(plan, defaultFromText)
  },

  /** "Перерыв 5 минут" / "Break 5 minutes" right after an exit: that exit's own break. */
  isExitBreak(lower: string): boolean {
    return (
      (lower.startsWith('перерыв') && !lower.startsWith('перерывы')) ||
      ((lower.startsWith('break') || lower.startsWith('pause') || lower.startsWith('rest')) &&
        !lower.startsWith('breaks') &&
        !lower.startsWith('pauses'))
    )
  },

  /** "Все перерывы 2 минуты", "All breaks 2 minutes": a line about breaks in general. */
  mentionsBreak(lower: string): boolean {
    return lower.includes('перерыв') || breakWordRegex.test(lower)
  },

  /**
   * Keeps per-exit breaks only where they differ from the plan's break, so changing that one
   * setting in the editor changes every ordinary break. Trainers often write "Перерыв 2 минуты"
   * after every exit instead of "Все перерывы 2 минуты": without such a line, a break used after
   * most exits becomes the plan's break.
   */
  normalizeBreaks(plan: TrainingPlan, defaultFromText: boolean): TrainingPlan {
    let defaultBreak = plan.defaultBreak
    if (!defaultFromText) {
      const counts = new Map<number, number>()
      for (const exit of plan.exits) {
        if (exit.breakAfter !== null) counts.set(exit.breakAfter, (counts.get(exit.breakAfter) ?? 0) + 1)
      }
      // On a tie Swift picks whichever comes first in its (unordered) dictionary; here the first one written wins.
      let common: [number, number] | null = null
      for (const entry of counts) if (common === null || common[1] < entry[1]) common = entry
      if (common !== null && common[1] * 2 > Math.max(1, plan.exits.length - 1)) defaultBreak = common[0]
    }
    return {
      ...plan,
      defaultBreak,
      exits: plan.exits.map((exit) => (exit.breakAfter === defaultBreak ? { ...exit, breakAfter: null } : exit)),
    }
  },

  // MARK: - Lines

  /** Removes leading emoji, bullets and arrows: "➡️ За 30 минут" → "За 30 минут". */
  stripDecorations(line: string): string {
    return trimWhitespaces(line.replace(decorationRegex, ''))
  },

  parseExit(line: string): PlannedExit | null {
    const match = exitRegex.exec(line)
    if (!match) return null

    let number: number | null = null
    for (const group of [match[1], match[2]]) {
      if (group !== undefined) {
        const value = parseSwiftInt(group)
        if (value !== null) number = value
      }
    }
    if (number === null) return null

    let rest = match[3] ?? ''

    let note: string | null = null
    const noteMatch = parenthesesRegex.exec(rest)
    if (noteMatch) {
      const candidate = trimWhitespaces(noteMatch[1])
      if (candidate !== '') note = candidate
      rest = rest.replace(allParenthesesRegex, '')
    }

    const lower = rest.toLowerCase()
    const untilStanding =
      lower.includes('до вставания') ||
      lower.includes('пока не встанет') ||
      (lower.includes('until') && lower.includes('stand'))

    const or = orRegex.exec(lower)
    const durationPart = or ? rest.slice(0, or.index) : rest
    const duration = DurationText.sumOfUnits(durationPart) ?? 0

    return PlannedExit.make({ number, duration, untilStanding, note })
  },

  parseHeader(line: string, plan: TrainingPlan): TrainingPlan {
    let text = line
    let date = plan.date
    const extracted = PlanParser.extractDate(text)
    if (extracted) {
      date = extracted.date
      text = text.slice(0, extracted.start) + text.slice(extracted.end)
    }

    const parts = text
      .replace(/–/g, '-')
      .replace(/—/g, '-')
      .split(' - ')
      .map((part) => trimWhitespacesAnd(part, '-'))
      .filter((part) => part !== '')

    return {
      ...plan,
      date,
      title: parts[0] ?? TrainingPlan.defaultTitle(),
      trainers: parts.slice(1).join(' · '),
    }
  },

  /** The first date in `text` (epoch ms at noon local time) and where it was. */
  extractDate(text: string): { date: number; start: number; end: number } | null {
    const match = dateRegex.exec(text)
    if (!match) return null
    const first = parseSwiftInt(match[1])
    const second = parseSwiftInt(match[2])
    let year = parseSwiftInt(match[3])
    if (first === null || second === null || year === null) return null
    if (year < 100) year += 2000
    // 05.10.2026 (dots) is always day.month; with slashes an English schedule from the US means month/day.
    // A number above 12 settles it, otherwise the app language's region decides.
    const slashes = match[0].includes('/')
    const monthFirst =
      first <= 12 && (second > 12 || (slashes && coreLanguage() === 'en' && localeWritesMonthFirst()))
    const day = monthFirst ? second : first
    const month = monthFirst ? first : second

    // Out-of-range days and months roll over, as with Calendar.date(from:).
    const date = new Date(year, month - 1, day, 12, 0, 0, 0)
    date.setFullYear(year, month - 1, day)
    const ms = date.getTime()
    if (!Number.isFinite(ms)) return null
    return { date: ms, start: match.index, end: match.index + match[0].length }
  },
}
