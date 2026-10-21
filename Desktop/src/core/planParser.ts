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
// - a condition for coming back early: `🟡 Если встала и пошла - входим через 2 минуты от начала движения`,
//   `If she lies down - come back in 30 seconds`. Right under an exit (no blank line between) it is that exit's,
//   anywhere else it is common to the training.
// - anything else becomes a note.
//
// NSRegularExpression's `\b` knows Unicode letters; JS's `\b` is ASCII-only even with the `u` flag, so the word
// boundaries below are spelled out as lookarounds (`wordStart` / `wordEnd`).

import { DurationText } from './durationText'
import { coreLanguage, coreLocale } from './localization'
import { EarlyEntry, type EarlyEntryTone, PlannedExit, TrainingPlan } from './models'
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
const breakWordRegex = new RegExp(`перерыв\\p{L}*|(?<!${word})(?:break|breaks|pause|pauses)(?!${word})`, 'iu')
/** ICU's `\b` in front of a word that starts with a letter, and after one that ends with a letter. */
const wordStart = `(?<!${word})`
const wordEnd = `(?!${word})`

/** «выйти», «выходим», «выйти из квартиры», "go out", "leave": the exit itself, not a trigger. */
const goingOutRegex = /^(?:выйти|выходим|выйдите|выход)(?:\s+(?:из|за)\s+\p{L}+)?$|^(?:go out|leave|step out)(?:\s+\p{L}+)?$/iu

/** A bullet in the middle of a line: «…поздно вечером➡️ За 30 минут…». */
const inlineBulletRegex = /(?<=\S)\s*(➡️|➡|🔖|🚩|🟡|🟢)/gu

/** «входим», «заходим», «возвращаемся», "come back", "come in", "go back", "return". */
const comeBackRegex = new RegExp(
  `${wordStart}(?:входим|заходим|возвращаемся|возвращайтесь|входите|заходите|come back|come in|go back|go in|return)${wordEnd}`,
  'iu',
)

/** «через», "in", "after" in front of the delay. */
const afterRegex = new RegExp(`${wordStart}(?:через|спустя|in|after)\\s+`, 'iu')

const rightAwayRegex = new RegExp(`${wordStart}(?:сразу|немедленно|right away|immediately|at once)${wordEnd}`, 'iu')

/** «не входить», «не входим», «не заходить», "do not come in", "don't go in". */
const doNotEnterRegex = new RegExp(
  `${wordStart}не\\s+(?:входить|входим|заходить|заходим|возвращаться|возвращаемся)${wordEnd}|` +
    `${wordStart}(?:do not|don't|never)\\s+(?:come|go)\\s+(?:in|back)${wordEnd}`,
  'iu',
)

/** "<number> <unit>" (`DurationText`'s units). */
const durationRegex =
  /\d+(?:[.,]\d+)?\s*(?:час\p{L}*|hour\p{L}*|hr\p{L}*|мин\p{L}*|min\p{L}*|сек\p{L}*|sec\p{L}*|ч|h|м|m|с|s)(?![\p{L}])/giu

/** "2 minute " / "2-minute " / «2 минуты » right before the break word. */
const durationBeforeWordRegex = /\d+(?:[.,]\d+)?[\s-]*\p{L}+[\s-]*$/u

const clauseBreakRegex = /[.!?…](?=\s+[^\s\d]|\s*$)|[,;](?=\s)/u

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
    const common: EarlyEntry[] = []
    let defaultFromText = false
    /** The exit the next condition belongs to: the last one, while no blank line has come after it. */
    let attachedExit: number | null = null
    let contentIndex = 0

    for (const rawLine of PlanParser.lines(text)) {
      if (rawLine === '') {
        attachedExit = null
        continue
      }
      const line = PlanParser.stripDecorations(rawLine)
      if (line === '') continue
      const index = contentIndex++

      const exit = PlanParser.parseExit(line)
      if (exit) {
        exits.push(exit)
        attachedExit = exits.length - 1
        continue
      }

      const lower = line.toLowerCase()

      if (PlanParser.isExitBreak(lower) && exits.length > 0) {
        const duration = DurationText.sumOfUnits(line)
        if (duration !== null) {
          exits[exits.length - 1] = { ...exits[exits.length - 1], breakAfter: duration }
          continue
        }
      }

      const entry = PlanParser.parseEarlyEntry(rawLine)
      if (entry) {
        if (attachedExit !== null) {
          const owner = exits[attachedExit]
          exits[attachedExit] = { ...owner, earlyEntries: [...owner.earlyEntries, entry], usesCommonEarlyEntries: false }
        } else {
          common.push(entry)
        }
        continue
      }
      attachedExit = null

      const commonBreak = PlanParser.commonBreak(line)
      if (commonBreak !== null) {
        plan.defaultBreak = commonBreak
        defaultFromText = true
        notes.push(line)
        continue
      }

      if (index === 0) {
        plan = PlanParser.parseHeader(line, plan)
        continue
      }

      notes.push(line)
    }

    plan.exits = exits
    plan.notes = notes
    plan.commonEarlyEntries = common
    return PlanParser.normalizeBreaks(plan, defaultFromText)
  },

  /**
   * Trimmed lines, with blank ones kept (they end an exit's block). A Windows line break (CRLF) is one break, not a
   * blank line after every line. A line that runs into the next point without a line break («…поздно вечером➡️ За 30
   * минут…») is split there.
   */
  lines(text: string): string[] {
    return splitLines(text.replace(/\r\n/g, '\n'))
      .flatMap((line) => line.replace(inlineBulletRegex, '\n$1').split('\n'))
      .map(trimWhitespaces)
  },

  // MARK: - Conditions

  /**
   * «🟡 Если встала и пошла - входим через 2 минуты от начала движения, когда сняла фокус внимания с двери»,
   * «🟢 Если легла - входим через 30 секунд от укладки», "If she lies down — come back in 30 seconds". A rule about
   * not coming in («🚩 Если залаяла - ни в коем случае не входить…») is not one.
   */
  parseEarlyEntry(rawLine: string): EarlyEntry | null {
    const line = PlanParser.stripDecorations(rawLine)
    const lower = line.toLowerCase()
    if (!(lower.startsWith('если ') || lower.startsWith('if ')) || PlanParser.isDoNotEnterRule(line)) return null
    const verb = comeBackRegex.exec(line)
    if (!verb) return null

    const { title: event } = PlanParser.splitCondition(line.slice(0, verb.index))
    if (!event) return null

    let tail = line.slice(verb.index + verb[0].length)
    let delay: number | null = null
    const after = afterRegex.exec(tail)
    if (after) {
      // The time right after «через» / "in", up to the end of its part of the sentence.
      const rest = tail.slice(after.index + after[0].length)
      const found = rest.search(/[,;:]/u)
      const clauseEnd = found < 0 ? rest.length : found
      const clause = rest.slice(0, clauseEnd)
      const last = [...clause.matchAll(durationRegex)].at(-1)
      if (last) {
        const end = last.index + last[0].length
        delay = DurationText.sumOfUnits(clause.slice(0, end))
        tail = clause.slice(end) + rest.slice(clauseEnd)
      }
    } else {
      const now = rightAwayRegex.exec(tail)
      if (now) tail = tail.slice(now.index + now[0].length)
    }
    const detail = trimWhitespacesAnd(tail, ',;:.-–—')

    const tone: EarlyEntryTone =
      rawLine.startsWith('🟡') || rawLine.startsWith('🟠') ? 'yellow' : rawLine.startsWith('🟢') ? 'green' : 'plain'
    return EarlyEntry.make({ event, delay, detail: detail === '' ? null : detail, tone })
  },

  /** «🚩 Если залаяла, завыла - ни в коем случае не входить, ждём…», "If she barks — do not come in". */
  isDoNotEnterRule(line: string): boolean {
    return line.startsWith('🚩') || doNotEnterRegex.test(line)
  },

  /**
   * «Если залаяла, завыла - ни в коем случае не входить» → («Залаяла, завыла», «ни в коем случае не входить»):
   * what the dog does (after «если», up to the dash) and the rest. No «если» at the start: no title.
   */
  splitCondition(line: string): { title: string | null; detail: string } {
    const text = PlanParser.stripDecorations(line)
    const lower = text.toLowerCase()
    const prefix = lower.startsWith('если ') ? 'если '.length : lower.startsWith('if ') ? 'if '.length : 0
    if (prefix === 0) return { title: null, detail: text }
    const body = text.slice(prefix)
    let separator: { start: number; end: number } | null = null
    for (const dash of [' - ', ' – ', ' — ', '- ', '— ']) {
      const start = body.indexOf(dash)
      if (start >= 0 && (separator === null || start < separator.start)) separator = { start, end: start + dash.length }
    }
    if (separator === null) {
      const comma = body.indexOf(', ')
      if (comma >= 0) separator = { start: comma, end: comma + 2 }
    }
    const head = separator ? body.slice(0, separator.start) : body
    const rest = separator ? body.slice(separator.end) : ''
    const title = trimWhitespacesAnd(head, ',;:-–—')
    const [first = '', ...others] = Array.from(title)
    return { title: first.toUpperCase() + others.join(''), detail: trimWhitespaces(rest) }
  },

  // MARK: - The trainer's text, line by line

  sourceLines(text: string): SourceLine[] {
    const result: SourceLine[] = []
    let attachedExit: number | null = null
    let contentIndex = 0
    const rows = PlanParser.lines(text)
    while (rows.length && rows[rows.length - 1] === '') rows.pop()
    while (rows.length && rows[0] === '') rows.shift()
    rows.forEach((rawLine, id) => {
      if (rawLine === '') {
        attachedExit = null
        result.push({ id, text: '', kind: 'blank', exitNumber: null })
        return
      }
      const index = contentIndex++
      const line = PlanParser.stripDecorations(rawLine)
      const lower = line.toLowerCase()
      let kind: SourceLineKind = 'note'
      let exitNumber: number | null = null
      const exit = PlanParser.parseExit(line)
      if (exit) {
        kind = 'exit'
        exitNumber = exit.number
        attachedExit = exit.number
      } else if (PlanParser.isExitBreak(lower) && attachedExit !== null && DurationText.sumOfUnits(line) !== null) {
        kind = 'breakTime'
        exitNumber = attachedExit
      } else if (PlanParser.parseEarlyEntry(rawLine) !== null) {
        kind = 'earlyEntry'
        exitNumber = attachedExit
      } else {
        attachedExit = null
        if (index === 0) {
          kind = 'header'
        } else if (PlanParser.isDoNotEnterRule(rawLine)) {
          kind = 'doNotEnter'
        } else if (rawLine.startsWith('🔖') || PlanParser.isFalseStartRule(lower)) {
          kind = 'falseStart'
        }
      }
      result.push({ id, text: rawLine, kind, exitNumber })
    })
    return result
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

  /**
   * "Все перерывы 2 минуты", "Перерывы между выходами — 2 минуты", "All breaks 2 minutes", "2 minute breaks":
   * the break of every exit. The time has to belong to the word: a few words after it or right before it,
   * in the same part of the sentence. A note that mentions breaks next to some other time says nothing about
   * them, and neither does the false-start rule: «Фальстарт: если пошла к двери в первые 20 секунд …, через
   * обычный перерыв …» once made every break 20 s.
   */
  commonBreak(line: string): number | null {
    if (PlanParser.isFalseStartRule(PlanParser.stripDecorations(line).toLowerCase())) return null
    for (const clause of PlanParser.clauses(line)) {
      const match = breakWordRegex.exec(clause)
      if (!match) continue
      const after = clause.slice(match.index + match[0].length)
      const digit = after.search(/\p{Nd}/u)
      if (digit >= 0 && (after.slice(0, digit).match(/\p{L}+/gu) ?? []).length <= 4) {
        const duration = DurationText.sumOfUnits(after)
        if (duration !== null) return duration
      }
      const adjacent = durationBeforeWordRegex.exec(clause.slice(0, match.index))
      if (adjacent) {
        const duration = DurationText.sumOfUnits(adjacent[0].replace(/-/g, ' '))
        if (duration !== null) return duration
      }
    }
    return null
  },

  /** «Фальстарт: …», "False start: …" (lowercased, decorations stripped). */
  isFalseStartRule(lower: string): boolean {
    return lower.startsWith('фальстарт') || lower.startsWith('false start')
  },

  /**
   * Parts of a sentence: split at commas and semicolons, and at the end of a sentence («выход. Если»), but not
   * inside «1,5 минуты» or «1 мин. 30 сек».
   */
  clauses(line: string): string[] {
    return line.split(clauseBreakRegex)
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

    // «10 секунд + куртка + взять ключи, звякнуть ими»: what follows a plus sign is a trigger.
    const parts = rest.split('+').map(trimWhitespaces)
    rest = parts[0]
    const triggers = parts.slice(1).filter((part) => part !== '')

    const lower = rest.toLowerCase()
    const untilStanding =
      lower.includes('до вставания') ||
      lower.includes('пока не встанет') ||
      (lower.includes('until') && lower.includes('stand'))

    const or = orRegex.exec(lower)
    const durationPart = or ? rest.slice(0, or.index) : rest
    const duration = DurationText.sumOfUnits(durationPart) ?? 0

    // «выйти, закрыть дверь на один оборот, подождать 10 секунд и вернуться»: a sentence instead of a time. What
    // is done before the waiting is a trigger, the sentence itself stays as the exit's note.
    if (rest !== '' && !/^\p{N}/u.test(rest) && rest.includes(',')) {
      const clauses = rest.split(',').map(trimWhitespaces)
      const timed = clauses.findIndex((clause) => DurationText.sumOfUnits(clause) !== null)
      if (timed >= 0) {
        const actions = clauses.slice(0, timed).filter((clause) => clause !== '' && !goingOutRegex.test(clause))
        triggers.unshift(...actions)
        note = [rest, note].filter((part): part is string => part !== null).join(' · ')
      }
    }

    return PlannedExit.make({ number, duration, untilStanding, note, triggers })
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

/** What a line of the trainer's text is (`PlanParser.SourceLine.Kind`). */
export type SourceLineKind = 'blank' | 'header' | 'note' | 'exit' | 'earlyEntry' | 'breakTime' | 'doNotEnter' | 'falseStart'

/** One line of the trainer's text, for showing it during the training with the current exit marked. */
export interface SourceLine {
  /** 0-based line index. */
  id: number
  text: string
  kind: SourceLineKind
  /** The exit the line is about: the exit's own line, its conditions and break right under it. */
  exitNumber: number | null
}
