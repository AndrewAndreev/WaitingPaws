// Port of Parser/DurationText.swift.
//
// Formatting of durations in the app's language ("2 мин", "15 с" / "2 min", "15 s", "1:30") and parsing in
// Russian and English. Durations are seconds (Swift `TimeInterval`).

import { tr } from './localization'
import { pad2, parseSwiftDouble, roundHalfAwayFromZero, trimWhitespacesAndNewlines } from './text'

const clockRegex = /^(\d+):(\d{1,2})(?::(\d{1,2}))?$/u

// Order matters: longer unit spellings must be tried before the single-letter ones.
const unitRegex =
  /(\d+(?:[.,]\d+)?)\s*(час\p{L}*|hour\p{L}*|hr\p{L}*|мин\p{L}*|min\p{L}*|сек\p{L}*|sec\p{L}*|ч|h|м|m|с|s)(?!\p{L})/giu

function multiplier(unit: string): number {
  const first = unit.toLowerCase()[0]
  switch (first) {
    case 'ч':
    case 'h':
      return 3600
    case 'м':
    case 'm':
      return 60
    default:
      return 1
  }
}

/**
 * Whole seconds for the formatters: NaN is 0 and anything past ±(2³¹ − 1) s (68 years) is cut there, as on the Mac and
 * iPhone, where `Int(_:)` traps on such times.
 */
function whole(seconds: number, round: (value: number) => number): number {
  if (Number.isNaN(seconds)) return 0
  const limit = 2 ** 31 - 1
  return round(Math.min(Math.max(seconds, -limit), limit))
}

function parseClock(text: string): number | null {
  const match = clockRegex.exec(text)
  if (!match) return null
  const parts = match.slice(1).filter((part): part is string => part !== undefined).map(Number)
  switch (parts.length) {
    case 2:
      return parts[0] * 60 + parts[1]
    case 3:
      return parts[0] * 3600 + parts[1] * 60 + parts[2]
    default:
      return null
  }
}

export const DurationText = {
  /** "15 с", "2 мин", "1 мин 30 с", "1 ч 5 мин". */
  short(seconds: number): string {
    const total = whole(seconds, roundHalfAwayFromZero)
    if (total < 0) return '−' + DurationText.short(-total)
    const hours = Math.floor(total / 3600)
    const minutes = Math.floor((total % 3600) / 60)
    const secs = total % 60
    const parts: string[] = []
    if (hours > 0) parts.push(tr(`${hours} h`, `${hours} ч`))
    if (minutes > 0) parts.push(tr(`${minutes} min`, `${minutes} мин`))
    if (secs > 0 || parts.length === 0) parts.push(tr(`${secs} s`, `${secs} с`))
    return parts.join(' ')
  },

  /** Very short form for chips: "5с", "30с", "1м", "1м30", "5м" / "5s", "1m", "1m30". */
  compact(seconds: number): string {
    const total = whole(seconds, roundHalfAwayFromZero)
    const s = tr('s', 'с')
    const m = tr('m', 'м')
    if (total < 60) return `${total}${s}`
    const minutes = Math.trunc(total / 60)
    const secs = total % 60
    return secs === 0 ? `${minutes}${m}` : `${minutes}${m}${secs}`
  },

  /** "0:15", "12:03", "1:02:03". Negative values are prefixed with a minus sign. */
  clock(seconds: number): string {
    const total = whole(seconds, Math.floor)
    const negative = total < 0
    const value = Math.abs(total)
    const hours = Math.floor(value / 3600)
    const minutes = Math.floor((value % 3600) / 60)
    const secs = value % 60
    const body = hours > 0 ? `${hours}:${pad2(minutes)}:${pad2(secs)}` : `${minutes}:${pad2(secs)}`
    return negative ? '−' + body : body
  },

  /**
   * Parses "15 с", "2 минуты", "1 мин 30 сек", "2 minutes", "1:30", "90". Returns `null` when nothing
   * recognisable is found, and for more than `longestTyped`.
   */
  parse(text: string): number | null {
    const trimmed = trimWhitespacesAndNewlines(text)
    if (trimmed === '') return null

    const value = parseClock(trimmed) ?? DurationText.sumOfUnits(trimmed) ?? parseSwiftDouble(trimmed.replace(/,/g, '.'))
    return value !== null && Math.abs(value) <= DurationText.longestTyped ? value : null
  },

  /**
   * The longest time `parse` takes: a day. An exit or a break is minutes; "inf" or "1e400" typed into a duration
   * field is no time at all.
   */
  longestTyped: 24 * 3600,

  /**
   * Sums every "<number> <unit>" pair found in `text`. Returns `null` if no unit is present, and for more than
   * `longestTyped`: «1 выход - 99999999999999999999 секунд» pasted into a plan is no time either.
   */
  sumOfUnits(text: string): number | null {
    const matches = [...text.matchAll(unitRegex)]
    if (matches.length === 0) return null
    let total = 0
    for (const match of matches) {
      const value = parseSwiftDouble(match[1].replace(/,/g, '.'))
      if (value === null) continue
      total += value * multiplier(match[2])
    }
    // Too many digits make an infinite number: it is past the limit too.
    return total <= DurationText.longestTyped ? total : null
  },

  /**
   * Whole seconds as the formatters count them, for any number (a plan from elsewhere may carry one), as on the Mac,
   * where `Int(_:)` traps on NaN, infinity and past `Int.max`.
   */
  wholeSeconds(seconds: number): number {
    return whole(seconds, roundHalfAwayFromZero)
  },
}
